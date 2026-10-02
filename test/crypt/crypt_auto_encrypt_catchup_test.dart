/// 「新文件自动加密」服务回归。
///
/// 钉住两个不变式：
///  1. 兜底补加密（catch-up）：容器目录内混进的明文文件被就地加密
///     （standard 配置下改名为密文名），内容可用同一挂载解回原样；
///  2. 已有密文绝不被二次加密（字节级断言）。
/// 另覆盖实时分支的文件名过滤纯逻辑。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zenfile/services/crypt/crypt.dart';
import 'package:zenfile/services/crypt/vault_crypt_service.dart';
import 'package:zenfile/services/crypt_auto_encrypt_service.dart';

const _fakeJpegMagic = [0xFF, 0xD8, 0xFF, 0xE0];

List<int> _fakePhoto(int seed, int len) {
  final bytes = List<int>.of(_fakeJpegMagic);
  for (var i = 0; i < len; i++) {
    bytes.add((seed + i) & 0xFF);
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late Directory container;
  late CryptMountPoint mount;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zenfile_autoenc_test');
    // 容器目录名避开 base32/base64 启发式（非 16 字节倍数、含下划线）
    container = Directory('${tmp.path}/plain_camera');
    await container.create();

    mount = CryptMountPoint(
      physicalPath: tmp.path,
      config: const RcloneCryptConfig(
        password: 'test-password',
        salt: 'test-salt',
      ),
      name: 'plain_camera_parent',
      isSandboxMode: false,
    );

    // legacy 主密码 + 容器登记表（runCatchUp 从这两处解析配置与目录）
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'test-password',
      VaultCryptService.kMasterSaltKey: 'test-salt',
      VaultCryptService.kFilenameEncodingKey: 'base32',
      VaultCryptService.kEncryptedSuffixKey: '.bin',
      'crypt_inplace_container_dirs':
          jsonEncode([container.path.replaceAll('\\', '/')]),
    });
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('兜底补加密：容器内明文文件被加密，解回后内容一致', () async {
    final original = _fakePhoto(7, 5000);
    final plainFile = File('${container.path}/IMG_001.jpg');
    await plainFile.writeAsBytes(original, flush: true);

    await CryptAutoEncryptService.instance.runCatchUp();

    // 原明文路径已不存在（standard 配置下改名为密文名）
    expect(await plainFile.exists(), isFalse,
        reason: '明文文件应被加密并改名为密文名');
    final entries = await container.list().toList();
    final files = entries.whereType<File>().toList();
    expect(files, isNotEmpty);
    for (final f in files) {
      expect(await CryptOperations.isEncryptedFile(f.path), isTrue,
          reason: '${f.path} 应为密文');
    }

    // 解回验证内容一致
    final ops = CryptOperations(mount);
    final decryptedPath = await ops.decryptFile(files.first.path);
    final decrypted = await File(decryptedPath).readAsBytes();
    expect(decrypted, original);
  });

  test('已有密文不被二次加密（字节级断言）', () async {
    final ops = CryptOperations(mount);
    final original = _fakePhoto(11, 3000);
    final seedPlain = File('${container.path}/IMG_000.jpg');
    await seedPlain.writeAsBytes(original, flush: true);
    final encryptedPath = await ops.encryptFile(seedPlain.path);
    final encryptedBytes = await File(encryptedPath).readAsBytes();

    // 模拟相机新增一张明文照片
    final newPlain = File('${container.path}/IMG_002.jpg');
    await newPlain.writeAsBytes(_fakePhoto(23, 4000), flush: true);

    await CryptAutoEncryptService.instance.runCatchUp();

    expect(await File(encryptedPath).exists(), isTrue,
        reason: '既有密文名保持不变');
    expect(await File(encryptedPath).readAsBytes(), encryptedBytes,
        reason: '既有密文字节级不变（不得二次加密）');
    expect(await newPlain.exists(), isFalse, reason: '新明文已被加密改名');
  });

  test('未登记/不存在的容器目录不抛异常（幂等空转）', () async {
    SharedPreferences.setMockInitialValues({
      VaultCryptService.kMasterPasswordKey: 'test-password',
      VaultCryptService.kMasterSaltKey: 'test-salt',
      'crypt_inplace_container_dirs': jsonEncode(
          ['${tmp.path.replaceAll('\\', '/')}/not_exist_dir']),
    });
    await CryptAutoEncryptService.instance.runCatchUp();
  });

  group('文件名过滤（实时分支）', () {
    test('隐藏文件与临时/中间态文件被跳过', () {
      expect(CryptAutoEncryptService.shouldConsiderForEncryption('IMG_1.jpg'),
          isTrue);
      expect(CryptAutoEncryptService.shouldConsiderForEncryption('.nomedia'),
          isFalse);
      expect(
          CryptAutoEncryptService.shouldConsiderForEncryption(
              'a.jpg.zencrypt_tmp'),
          isFalse);
      expect(CryptAutoEncryptService.shouldConsiderForEncryption('a.bin.zw'),
          isFalse);
      expect(CryptAutoEncryptService.shouldConsiderForEncryption('dl.part'),
          isFalse);
      expect(CryptAutoEncryptService.shouldConsiderForEncryption('dl.crdownload'),
          isFalse);
    });
  });

  group('同名明文兄弟目录推导（pending 监听登记）', () {
    test('目录名加密配置：密文容器 → 同名明文路径', () {
      expect(
        CryptAutoEncryptService.shadowPlainDirFor(
            '/storage/emulated/0/DCIM/Cx8sNf2Qz', 'Camera'),
        '/storage/emulated/0/DCIM/Camera',
      );
    });

    test('目录名未加密（明文名 == 容器名）→ null，无需监听影子目录', () {
      expect(
        CryptAutoEncryptService.shadowPlainDirFor(
            '/storage/emulated/0/DCIM/Camera', 'Camera'),
        isNull,
      );
    });

    test('明文名为空 → null', () {
      expect(
        CryptAutoEncryptService.shadowPlainDirFor(
            '/storage/emulated/0/DCIM/Cx8sNf2Qz', ''),
        isNull,
      );
    });
  });
}
