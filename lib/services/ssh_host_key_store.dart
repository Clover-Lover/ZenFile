import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// SSH 主机密钥 TOFU（Trust On First Use）存储。
///
/// 此前 ZenFile 的两条 SFTP 通道均不校验主机密钥：
///  - 原生 JSch 通道：`StrictHostKeyChecking=no`；
///  - dartssh2 回退通道：`onVerifyHostKey` 未设置（自动接受）。
/// 两者都等于对中间人攻击（MITM）完全敞开。
///
/// 本仓库实现 accept-new 语义：首次连接记录指纹并信任；此后指纹一致则
/// 放行，不一致（服务器重装/被劫持）一律拒绝。指纹存于
/// FlutterSecureStorage，键为 `sftp_hostkey_<host>_<port>`。
abstract class SshHostKeyStore {
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// 测试注入点：非 null 时替代 secure storage（生产环境恒为 null）。
  @visibleForTesting
  static Map<String, String>? overrideStore;

  static String _key(String host, int port) => 'sftp_hostkey_${host}_$port';

  static Future<String?> _read(String key) async {
    final store = overrideStore;
    if (store != null) return store[key];
    try {
      return await _secure.read(key: key);
    } catch (_) {
      // secure storage 不可用时不能把用户完全锁在外面，按「无记录」处理
      return null;
    }
  }

  static Future<void> _write(String key, String value) async {
    final store = overrideStore;
    if (store != null) {
      store[key] = value;
      return;
    }
    try {
      await _secure.write(key: key, value: value);
    } catch (_) {}
  }

  /// TOFU 校验：返回 true 表示接受该主机密钥。
  ///
  /// [fingerprint] 为 `SHA256:<base64(no padding)>` 格式指纹（与 OpenSSH
  /// 一致），可由 dartssh2 的回调直接给出，也可用 [sha256Fingerprint]
  /// 从公钥 blob 计算。
  static Future<bool> verifyTofu({
    required String host,
    required int port,
    required String keyType,
    required String fingerprint,
  }) async {
    final key = _key(host, port);
    final stored = await _read(key);
    if (stored == null || stored.isEmpty) {
      await _write(key, '$keyType $fingerprint');
      return true;
    }
    return stored == '$keyType $fingerprint';
  }

  /// 计算与 OpenSSH `ssh-keygen -lf` 一致的 `SHA256:<base64>` 指纹
  /// （base64 无 padding）。
  static String sha256Fingerprint(List<int> blob) {
    final digest = crypto.sha256.convert(blob).bytes;
    return 'SHA256:${base64.encode(digest).replaceAll('=', '')}';
  }
}
