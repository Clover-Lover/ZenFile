/// 保险箱解锁密码哈希方案回归。
///
/// 旧方案为单轮 sha256(password+salt)，6 位数字 PIN 可被秒级穷举。
/// 新方案 scrypt(N=16384,r=8,p=1)，且对存量 sha256 记录在**首次验证通过时
/// 透明升级**（用户无感知、无需重设密码）。本测试钉住：
///  1. 新设密码走 scrypt 且可验证；
///  2. 旧 sha256 记录可无感解锁并自动升级为 scrypt；
///  3. 升级后旧哈希被替换、错误密码仍被拒绝。
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/vault_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('新设密码使用 scrypt 方案并可验证', () async {
    SharedPreferences.setMockInitialValues({});
    await VaultService.setPassword('123456');
    expect(await VaultService.verifyPassword('123456'), isTrue);
    expect(await VaultService.verifyPassword('654321'), isFalse);
    expect(await VaultService.isPasswordSet(), isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vault_password_scheme'), 'scrypt-v1');
    // scrypt 输出为 32 字节的 base64
    final hash = prefs.getString('vault_password_hash')!;
    expect(base64.decode(hash).length, 32);
  });

  test('旧版 sha256 记录可无感解锁并自动升级', () async {
    final saltBytes = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      saltBytes[i] = i;
    }
    final salt = base64Encode(saltBytes);
    final legacyHash =
        crypto.sha256.convert(utf8.encode('pin123$salt')).toString();
    SharedPreferences.setMockInitialValues({
      'vault_salt': salt,
      'vault_password_hash': legacyHash,
      // 无 vault_password_scheme 键 → 视为旧版 sha256
    });

    // 旧密码无感通过（不要求用户重设）
    expect(await VaultService.verifyPassword('pin123'), isTrue);

    // 已自动升级为 scrypt，且旧哈希被替换
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('vault_password_scheme'), 'scrypt-v1');
    expect(prefs.getString('vault_password_hash'), isNot(legacyHash));

    // 升级后仍可正常验证（含错误密码拒绝）
    expect(await VaultService.verifyPassword('pin123'), isTrue);
    expect(await VaultService.verifyPassword('wrong'), isFalse);
  });

  test('未设置密码时验证直接失败', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await VaultService.isPasswordSet(), isFalse);
    expect(await VaultService.verifyPassword('anything'), isFalse);
  });
}
