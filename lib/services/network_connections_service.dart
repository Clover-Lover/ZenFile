import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/network_connection_model.dart';
import 'remote/remote_client.dart';
import 'remote/ftp_client.dart';
import 'remote/sftp_client.dart';
import 'remote/webdav_client.dart';
import 'remote/lan_client.dart';
import 'remote/saf_client.dart';
// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线（2026-09-30）：连接仍有问题，留待重做。
// 恢复步骤：① 取消下面两行 import 的注释；② 恢复 detectRemoteProtocolKind 里的
// netdisk 分支；③ 恢复 buildRemoteClient 里的 netdisk 分支；④ 恢复各 UI 入口
// （network_connection_wizard_screen 的添加区、network_category_screen 的连接过滤）。
// import 'remote/netdisk/quark_client.dart';
// import 'remote/netdisk/alipan_client.dart';

/// 远程连接协议类型（由 `NetworkConnectionModel.type` 解析而来）。
///
/// ⚠️ `netdisk` 目前**不参与解析**（聚合网盘暂时下线），保留枚举值便于恢复。
enum RemoteProtocolKind { sftp, ftp, webdav, smb, saf, netdisk }

/// 从 `NetworkConnectionModel.type` 解析协议类型。
///
/// ⚠️ `type` 字段**取值不统一**：
///  - FTP / SFTP / WebDav / saf 存的是固定英文常量（向导里 `_selectedType` = 协议名）；
///  - **SMB 存的是本地化标签**（`L10n.smb`：中文「局域网/SMB」、英文「LAN/SMB」、
///    繁体「區域網/SMB」），历史版本还存过 `SMB` / `Samba` / `CIFS`。
/// 因此一律用小写**包含**匹配，绝不写字符串等值比较（换语言后必失配，曾致
/// 「编辑老连接时 SMB 专属 UI 整块消失」）。
///
/// 顺序要求：`sftp` 必须先于 `ftp`（`sftp` 本身就含子串 `ftp`）。
RemoteProtocolKind? detectRemoteProtocolKind(String? type) {
  if (type == null) return null;
  final t = type.toLowerCase();
  // ⛔ 聚合网盘暂时下线：不再把 NETDISK_* 识别为网盘协议，残留连接会走
  // 「不支持的类型」分支，而不是停在半可用状态。
  // if (t.contains('netdisk')) return RemoteProtocolKind.netdisk;
  if (t.contains('sftp')) return RemoteProtocolKind.sftp;
  if (t.contains('saf')) return RemoteProtocolKind.saf;
  if (t.contains('smb') || t.contains('samba') || t.contains('cifs')) {
    return RemoteProtocolKind.smb;
  }
  if (t.contains('dav') || t.contains('web')) return RemoteProtocolKind.webdav;
  if (t.contains('ftp')) return RemoteProtocolKind.ftp;
  return null;
}

class NetworkConnectionsService {
  static const String _keyConnections = 'network_connections';
  static SharedPreferences? _prefs;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
  }

  static List<NetworkConnectionModel> getConnections() {
    if (_prefs == null) return [];
    final str = _prefs!.getString(_keyConnections);
    if (str == null || str.isEmpty) return [];
    try {
      final list = json.decode(str) as List<dynamic>;
      return list
          .map((e) => NetworkConnectionModel.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveConnection(NetworkConnectionModel conn) async {
    await init();
    final current = getConnections();
    final index = current.indexWhere((c) => c.id == conn.id);
    if (index >= 0) {
      current[index] = conn;
    } else {
      current.add(conn);
    }
    final str = json.encode(current.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyConnections, str);
  }

  static Future<void> deleteConnection(String id) async {
    await init();
    final current = getConnections();
    current.removeWhere((c) => c.id == id);
    final str = json.encode(current.map((e) => e.toJson()).toList());
    await _prefs?.setString(_keyConnections, str);
  }

  /// 判断连接类型是否为 SMB（局域网）。标签本地化（中文「局域网/SMB」、英文
  /// 「LAN/SMB」），历史版本还存过 `Samba` / `CIFS`，故统一交给
  /// [detectRemoteProtocolKind] 做包含匹配，与 [FileManagerProvider.isSmbType] 一致。
  static bool isSmbType(String type) =>
      detectRemoteProtocolKind(type) == RemoteProtocolKind.smb;

  /// 中立的远程客户端工厂：按连接模型构造正确的 [RemoteClient] 子类。
  ///
  /// ⚠️ 放在此处（而非 `FileManagerProvider`）是为了避免循环依赖：
  /// `file_manager_provider` 已依赖 `crypt_stream_server`，若 crypt 流式解密
  /// 服务再反向调用 `FileManagerProvider.createRemoteClient` 就会形成环。
  /// 本方法无 UI / 无 crypt 依赖，可被两侧安全复用，逻辑与
  /// [FileManagerProvider.createRemoteClient] 保持一致。
  /// 测试注入点：非 null 时由用例提供伪造的 [RemoteClient]。
  ///
  /// 供「远程密文解密到本地 / 远程原地加解密」这类上层链路写集成测试用
  /// （本项目的约定：不要靠加日志让用户反复复现，给关键类留注入点本机验证）。
  /// 生产环境恒为 null，走下方真实协议分支。
  static RemoteClient Function(NetworkConnectionModel conn)? builderForTest;

  static RemoteClient buildRemoteClient(NetworkConnectionModel conn) {
    final fake = builderForTest;
    if (fake != null) return fake(conn);
    // 一律走 detectRemoteProtocolKind（包含匹配）而非 `conn.type == 'XXX'`：
    // type 可能是本地化标签，精确比较在换语言 / 编辑老连接时会失配并抛
    // ArgumentError('Unsupported connection type')，表现为整条连接打不开。
    final kind = detectRemoteProtocolKind(conn.type);
    if (kind == RemoteProtocolKind.ftp) {
      return FtpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    }
    if (kind == RemoteProtocolKind.sftp) {
      return SftpRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        sshKeyPath: conn.sshKeyPath,
        sshKeyPassword: conn.sshKeyPassword,
        authMethod: conn.authMethod,
      );
    }
    if (kind == RemoteProtocolKind.webdav) {
      return WebDavRemoteClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
        protocol: conn.protocol,
        rootPath: conn.rootPath,
      );
    }
    if (kind == RemoteProtocolKind.smb) {
      return LanClient(
        host: conn.host,
        port: conn.port,
        username: conn.username,
        password: conn.password,
      );
    }
    if (kind == RemoteProtocolKind.saf) {
      return SafRemoteClient(rootUri: conn.rootPath);
    }
    // ⛔ 聚合网盘暂时下线（见文件头说明）：不再构造网盘客户端。
    // if (kind == RemoteProtocolKind.netdisk) {
    //   if (conn.type.toLowerCase().contains('quark')) {
    //     return QuarkRemoteClient(connection: conn);
    //   }
    //   return AlipanRemoteClient(connection: conn);
    // }
    throw ArgumentError('Unsupported connection type: ${conn.type}');
  }
}
