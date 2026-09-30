// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 聚合网盘登录态存储。
///
/// 网盘登录产生的敏感凭据（Cookie / refresh_token / access_token 等）经系统
/// 加密存储（flutter_secure_storage）落盘，以连接 id 为 key，与
/// [NetworkConnectionsService] 中保存的连接元信息一一对应：
/// 连接元信息（名称、类型）走 SharedPreferences，登录态走加密存储，两者解耦。
class NetdiskAuthStore {
  static const _storage = FlutterSecureStorage();

  static String _keyFor(String connId) => 'netdisk_auth_$connId';

  /// 保存网盘登录态。auth 为各网盘客户端自定义的 JSON 结构
  /// （夸克：cookie；阿里云盘：refresh_token / access_token / drive_id）。
  static Future<void> saveAuth(String connId, Map<String, dynamic> auth) async {
    await _storage.write(key: _keyFor(connId), value: json.encode(auth));
  }

  static Future<Map<String, dynamic>?> readAuth(String connId) async {
    final raw = await _storage.read(key: _keyFor(connId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearAuth(String connId) async {
    await _storage.delete(key: _keyFor(connId));
  }
}
