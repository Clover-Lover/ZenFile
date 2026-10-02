/// 「加密新增文件」增量合并（mergeNewFilesIntoEncryptedDir）的回归测试
///
/// 场景（用户报障）：原地加密 `/DCIM/Camera` 会把目录名换成密文名 ⇒ 相机下次拍照时
/// 这个路径已不存在 ⇒ 系统**新建同名明文目录**继续写 ⇒ 新照片永远是明文。
/// 而「再执行一次原地加密」修不好：EME 是确定性加密 ⇒ `encryptDirName('Camera')`
/// 恒定 ⇒ rename 的目标就是那个已存在的密文目录，且 `encryptDirectory` 阶段④
/// 没有同名检查 ⇒ 直接抛异常。
///
/// 修复：`CryptOperations.mergeNewFilesIntoEncryptedDir` 只做「并入」——
/// 把同名明文目录里的条目加密后搬进密文目录，一步都不改目录名。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_config.dart';
import 'package:zenfile/services/crypt/crypt_mount.dart';
import 'package:zenfile/services/crypt/crypt_operations.dart';

void main() {
  late Directory root;
  late Directory cipherDir;
  late CryptMountPoint mount;

  setUp(() {
    root = Directory.systemTemp.createTempSync('zenfile_merge_');
    // 挂载点建在「被加密条目的父目录」上（与 VaultCryptService.encryptInPlace 一致）
    mount = CryptMountPoint(
      physicalPath: root.path,
      config: const RcloneCryptConfig(password: 'test-pass'),
    );
    cipherDir =
        Directory(p.join(root.path, mount.crypt.encryptDirName('Camera')))
          ..createSync();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  CryptOperations ops() => CryptOperations(mount);

  /// 往密文目录里放一个「已经是密文」的文件（模拟原地加密过的既有内容）
  Future<void> seedCipherFile(String plainName, String content) async {
    final src = File(p.join(root.path, 'seed_$plainName'))
      ..writeAsStringSync(content);
    await ops().encryptFileTo(
      src.path,
      p.join(cipherDir.path, mount.crypt.encryptFileName(plainName)),
    );
    src.deleteSync();
  }

  List<String> cipherEntries() =>
      cipherDir.listSync().map((e) => p.basename(e.path)).toList();

  group('mergeNewFilesIntoEncryptedDir', () {
    test('把同名明文目录的新条目并入密文目录，并清理掉空的明文目录', () async {
      await seedCipherFile('old.jpg', 'old-content');

      final plainDir = Directory(p.join(root.path, 'Camera'))..createSync();
      File(p.join(plainDir.path, 'IMG_1.jpg')).writeAsStringSync('new-1');
      File(p.join(plainDir.path, 'IMG_2.jpg')).writeAsStringSync('new-2');

      final merged = await ops().mergeNewFilesIntoEncryptedDir(cipherDir.path);

      expect(merged, 2, reason: '两个新文件都应被搬进来');
      expect(
        Directory(p.join(root.path, 'Camera')).existsSync(),
        isFalse,
        reason: '明文目录搬空后应被删除，否则用户会看到两个 Camera',
      );
      expect(
        cipherEntries(),
        containsAll(<String>[
          mount.crypt.encryptFileName('old.jpg'),
          mount.crypt.encryptFileName('IMG_1.jpg'),
          mount.crypt.encryptFileName('IMG_2.jpg'),
        ]),
      );

      // 内容端到端：新文件能解回原文
      final decrypted = await ops().decryptFile(
        p.join(cipherDir.path, mount.crypt.encryptFileName('IMG_1.jpg')),
      );
      expect(File(decrypted).readAsStringSync(), 'new-1');

      // 既有密文不得被二次加密（阶段① 的 skipEncrypted 必须生效）
      final oldDecrypted = await ops().decryptFile(
        p.join(cipherDir.path, mount.crypt.encryptFileName('old.jpg')),
      );
      expect(File(oldDecrypted).readAsStringSync(), 'old-content');
    });

    test('同名冲突按明文名加 _1 后缀，两条都保留', () async {
      await seedCipherFile('IMG_1.jpg', 'old-1');

      final plainDir = Directory(p.join(root.path, 'Camera'))..createSync();
      File(p.join(plainDir.path, 'IMG_1.jpg')).writeAsStringSync('new-1');

      final merged = await ops().mergeNewFilesIntoEncryptedDir(cipherDir.path);

      expect(merged, 1);
      final names = cipherEntries();
      expect(names, contains(mount.crypt.encryptFileName('IMG_1.jpg')));
      expect(
        names,
        contains(mount.crypt.encryptFileName('IMG_1_1.jpg')),
        reason: '冲突必须回到明文名加后缀再加密；直接改密文名会让解密层认不出',
      );

      final a = await ops().decryptFile(
        p.join(cipherDir.path, mount.crypt.encryptFileName('IMG_1.jpg')),
      );
      final b = await ops().decryptFile(
        p.join(cipherDir.path, mount.crypt.encryptFileName('IMG_1_1.jpg')),
      );
      expect(
        <String>[File(a).readAsStringSync(), File(b).readAsStringSync()],
        containsAll(<String>['old-1', 'new-1']),
      );
    });

    test('密文目录内混进的明文文件被就地加密（没有同名明文目录时也生效）', () async {
      File(p.join(cipherDir.path, 'loose.txt')).writeAsStringSync('loose');

      final merged = await ops().mergeNewFilesIntoEncryptedDir(cipherDir.path);

      expect(merged, 0, reason: '没有同名明文目录可合并');
      expect(File(p.join(cipherDir.path, 'loose.txt')).existsSync(), isFalse);
      final decrypted = await ops().decryptFile(
        p.join(cipherDir.path, mount.crypt.encryptFileName('loose.txt')),
      );
      expect(File(decrypted).readAsStringSync(), 'loose');
    });
  });
}
