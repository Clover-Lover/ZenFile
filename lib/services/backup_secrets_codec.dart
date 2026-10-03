import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:pinenacl/api.dart';
import 'package:pinenacl/src/authenticated_encryption/secret.dart';

import 'crypt/scrypt.dart';

/// 全局备份「敏感信息加密块」编解码器
///
/// 设计（2026-10-03 方案 A，用户拍板）：备份 JSON 中所有敏感凭据（远程连接
/// 密码、加密挂载点/档案密码、保险箱/远程守卫门禁哈希、ftp/web_share 口令、
/// OAuth token 等）集中进一个 `secrets` 加密块，用**用户输入的备份口令**
/// 加密；JSON 明文里只有盐值 / nonce / 密文，不泄露任何凭据明文。
///
/// - KDF：scrypt(N=16384, r=8, p=1, keyLen=32)——与加密模块同一实现
///   （`crypt/scrypt.dart`），内存困难，弱口令离线爆破成本高。
/// - AEAD：XSalsa20-Poly1305（NACL SecretBox，与 rclone crypt 同源基建）。
/// - 口令不落盘、不进任何存储：丢了只能重配敏感项（非敏感设置不受影响）。
class BackupSecretsCodec {
  BackupSecretsCodec._();

  /// 加密块格式标识（恢复侧据此识别 v2 备份）
  static const String scheme = 'zf-backup-secrets-v1';

  static const int _saltLen = 16;
  static const int _nonceLen = 24;
  static const int _keyLen = 32;

  /// 生成随机字节（备份/恢复各用一次，量小，Random.secure 足够）
  static Uint8List _randomBytes(int len) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(len, (_) => random.nextInt(256)),
    );
  }

  static String _b64(List<int> bytes) => base64Encode(bytes);
  static Uint8List _unb64(String s) => base64Decode(s);

  /// 把敏感信息负载加密成可写进 JSON 的 `secrets` 块。
  ///
  /// [payload] 结构见 [SettingsBackupService]（prefs / connection_credentials /
  /// mount_passwords / crypt_profiles / crypt_profile_bindings）。
  static Future<Map<String, dynamic>> encrypt(
    Map<String, dynamic> payload,
    String passphrase,
  ) async {
    final salt = _randomBytes(_saltLen);
    final nonce = _randomBytes(_nonceLen);
    final plain = utf8.encode(jsonEncode(payload));

    // scrypt 占 16MB 内存 + 数十毫秒，放 isolate 避免卡 UI（与保险箱同策）。
    final key = await Isolate.run(() {
      return scrypt(
        utf8.encode(passphrase),
        salt,
        N: 16384,
        r: 8,
        p: 1,
        keyLength: _keyLen,
      );
    });

    final box = SecretBox(key);
    // pinenacl 返回 nonce(24) + ciphertext + tag(16)；nonce 已单独存，剥掉
    final sealed = box.encrypt(plain, nonce: nonce);
    final cipherPlusTag = Uint8List.fromList(sealed.sublist(_nonceLen));

    return <String, dynamic>{
      'scheme': scheme,
      'kdf': 'scrypt',
      'n': 16384,
      'r': 8,
      'p': 1,
      'salt': _b64(salt),
      'nonce': _b64(nonce),
      'ciphertext': _b64(cipherPlusTag),
    };
  }

  /// 解密 `secrets` 块，返回敏感信息负载。
  ///
  /// 口令错误 / 块损坏时抛 [BackupPassphraseException]（Poly1305 校验失败），
  /// 格式非法抛 [FormatException]。
  static Future<Map<String, dynamic>> decrypt(
    Map<String, dynamic> secretsBlock,
    String passphrase,
  ) async {
    final schemeTag = secretsBlock['scheme'];
    if (schemeTag != scheme) {
      throw const FormatException('Unsupported backup secrets scheme');
    }
    final salt = _unb64(secretsBlock['salt'] as String);
    final nonce = _unb64(secretsBlock['nonce'] as String);
    final cipher = _unb64(secretsBlock['ciphertext'] as String);
    final n = secretsBlock['n'] as int? ?? 16384;
    final r = secretsBlock['r'] as int? ?? 8;
    final p = secretsBlock['p'] as int? ?? 1;

    final key = await Isolate.run(() {
      return scrypt(
        utf8.encode(passphrase),
        salt,
        N: n,
        r: r,
        p: p,
        keyLength: _keyLen,
      );
    });

    final box = SecretBox(key);
    try {
      final plain = box.decrypt(ByteList(cipher), nonce: nonce);
      final decoded = jsonDecode(utf8.decode(plain));
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Invalid secrets payload');
      }
      return decoded;
    } catch (e) {
      // Poly1305 校验失败 = 口令错误（或密文损坏），统一按口令错误上抛
      if (e is BackupPassphraseException || e is FormatException) rethrow;
      throw BackupPassphraseException();
    }
  }
}

/// 备份口令错误（解密校验失败）
class BackupPassphraseException implements Exception {
  const BackupPassphraseException();
  @override
  String toString() => 'BackupPassphraseException: wrong passphrase';
}
