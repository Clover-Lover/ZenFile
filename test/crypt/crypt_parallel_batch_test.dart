import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/crypt/crypt_batch_runner.dart';
import 'package:zenfile/services/crypt/rclone_crypt.dart';

/// `CryptOperations.tmpSuffix` 的字面量副本：这里**故意不走 import**。
/// 它是磁盘上「未完成写入」的标记，改名的代价是遗留脏文件被当成正式产物，
/// 所以让测试独立钉住它，改了就红。
const String kTmpSuffix = '.zencrypt_tmp';

/// 批量「原地」加解密并行执行器（`CryptBatchRunner`）的回归。
///
/// 这是**加密**功能，测试必须证明「数据没坏」，而不只是「跑通了」：
///
/// 1. **磁盘格式零变化**：产物仍是 rclone 格式（32 B 文件头 + 每 64 KiB 明文
///    块 + 16 B tag），长度公式吻合，文件头 magic 正确 —— 这样才继续与
///    rclone / OpenList 互通。长度公式在这份测试里**独立推一遍**，不复用
///    `calculateEncryptedSize`，否则实现改错时公式会跟着一起错。
/// 2. **可还原**：并行加密出来的密文，用**单线程**解密器必须还原出与原文
///    **逐字节相同**的内容。
/// 3. **并行 == 顺序**：解密是确定性的，同一份密文走 `workers=1` 与
///    `workers=4` 两条路径必须给出完全相同的字节。
/// 4. **进度契约**：`onBytes` 单调递增并收敛到总字节；`onJobDone` 次数 == 作业数。
/// 5. **原子写与失败处理**：源文件被删、无 `*.zencrypt_tmp` 残留、mtime 保留；
///    作业失败时抛异常且源文件完好。
void main() {
  final crypt = RcloneCrypt(
    config: const RcloneCryptConfig(
      password: 'parallel-batch-test',
      salt: 'parallel-batch-salt',
      filenameEncoding: FilenameEncoding.base32,
    ),
  );

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zf_batch_');
  });

  tearDown(() async {
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
    }
  });

  /// 造一棵测试树，返回「相对路径 -> 原始字节」。
  ///
  /// 尺寸刻意覆盖三类边界：空文件、小于一块、非整块（尾块不满）。
  Map<String, Uint8List> buildTree(Directory dir) {
    final rand = Random(20260927);
    final spec = <String, int>{
      'empty.dat': 0,
      'tiny.dat': 100,
      'a.dat': 1024 * 1024 + 12345, // 非整块：验「最后一块不满」
      'sub/b.dat': 1024 * 1024, // 恰好一块
      'sub/deep/c.dat': 1024 * 1024 * 3,
    };
    final out = <String, Uint8List>{};
    for (final e in spec.entries) {
      final f = File(p.join(dir.path, p.joinAll(e.key.split('/'))));
      f.parent.createSync(recursive: true);
      final data = Uint8List(e.value);
      // 稀疏打点即可（全量填充纯属浪费时间），但保证长度与内容确定可复现
      for (var i = 0; i < data.length; i += 4093) {
        data[i] = rand.nextInt(256);
      }
      f.writeAsBytesSync(data);
      out[e.key] = data;
    }
    return out;
  }

  /// 按 `encryptDirectory` / `decryptDirectory` 的规则算出作业列表
  /// （原地：产物与源同目录、同目录名）。
  List<CryptBatchJob> buildJobs(Directory dir, {required bool encrypting}) {
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => !f.path.endsWith(kTmpSuffix))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    return files.map((f) {
      final base = p.basename(f.path);
      final targetName = encrypting
          ? crypt.encryptFileName(base)
          : crypt.decryptFileName(base);
      final target = p.join(f.parent.path, targetName);
      final stat = f.statSync();
      return CryptBatchJob(
        srcPath: f.path,
        targetPath: target,
        tmpPath: '$target$kTmpSuffix',
        readBytes: stat.size,
        modifiedMs: stat.modified.millisecondsSinceEpoch,
      );
    }).toList();
  }

  /// 用**单线程**解密器整文件还原（独立于 runner 的验证路径）。
  Uint8List decryptWholeFile(String path) {
    final dec = crypt.createDecrypter();
    final out = BytesBuilder();
    out.add(dec.process(File(path).readAsBytesSync()));
    out.add(dec.finish());
    return out.toBytes();
  }

  /// rclone crypt 期望的密文长度 —— 独立推一遍，**不复用** `calculateEncryptedSize`。
  int expectEncryptedSize(int plainSize) {
    if (plainSize == 0) return fileHeaderSize;
    final full = plainSize ~/ cryptBlockSize;
    final rest = plainSize % cryptBlockSize;
    var size = fileHeaderSize + full * (cryptBlockSize + blockOverhead);
    if (rest > 0) size += rest + blockOverhead;
    return size;
  }

  String encryptedPathOf(String rootPath, String rel) {
    final dir = rel.contains('/')
        ? p.join(
            rootPath,
            p.joinAll(rel.split('/').sublist(0, rel.split('/').length - 1)),
          )
        : rootPath;
    return p.join(dir, crypt.encryptFileName(p.basename(rel)));
  }

  List<File> tmpLeftovers(Directory dir) => dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith(kTmpSuffix))
      .toList();

  // ==================================================================
  group('磁盘格式：与 rclone / OpenList 继续互通', () {
    test('密文长度符合 rclone 公式，且与 calculateEncryptedSize 一致', () async {
      final original = buildTree(root);
      final jobs = buildJobs(root, encrypting: true);

      expect(
        jobs.fold<int>(0, (s, j) => s + j.readBytes),
        greaterThanOrEqualTo(CryptBatchRunner.minBytesForIsolate),
        reason: '本用例应当走并行分支（总量需 ≥ minBytesForIsolate）',
      );

      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: jobs,
        encrypting: true,
        workers: 4,
      );

      for (final e in original.entries) {
        final enc = File(encryptedPathOf(root.path, e.key));
        expect(enc.existsSync(), isTrue, reason: '密文缺失：${e.key}');
        expect(
          enc.lengthSync(),
          expectEncryptedSize(e.value.length),
          reason: '密文长度不符 rclone 公式：${e.key}',
        );
        // 与库自带公式交叉校验（两边同时改错才会漏过）
        expect(
          enc.lengthSync(),
          calculateEncryptedSize(e.value.length),
          reason: '与 calculateEncryptedSize 不一致：${e.key}',
        );
      }
    });

    test('文件头 magic 为 RCLONE\\0\\0', () async {
      final original = buildTree(root);
      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: buildJobs(root, encrypting: true),
        encrypting: true,
        workers: 4,
      );

      for (final key in original.keys) {
        final head = File(encryptedPathOf(root.path, key)).readAsBytesSync();
        expect(
          head.sublist(0, fileMagicSize),
          fileHeaderMagicBytes,
          reason: '文件头 magic 错误：$key',
        );
        expect(head.length, greaterThanOrEqualTo(fileHeaderSize));
      }
    });

    test('并行加密的产物用单线程解密器可逐字节还原', () async {
      final original = buildTree(root);
      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: buildJobs(root, encrypting: true),
        encrypting: true,
        workers: 4,
      );

      for (final e in original.entries) {
        final restored = decryptWholeFile(encryptedPathOf(root.path, e.key));
        expect(restored, orderedEquals(e.value), reason: '并行加密产物无法还原：${e.key}');
      }
    });
  });

  // ==================================================================
  group('并行路径与顺序回退等价', () {
    test('同一密文：workers=1 与 workers=4 解密结果逐字节相同', () async {
      // 先并行加密出一份密文，再分别用两条路径解密（解密是确定性的，
      // 因此可以直接比较字节；加密带随机 nonce，不能这样比）。
      final original = buildTree(root);
      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: buildJobs(root, encrypting: true),
        encrypting: true,
        workers: 4,
      );

      final seqRoot = await Directory.systemTemp.createTemp('zf_batch_seq_');
      final parRoot = await Directory.systemTemp.createTemp('zf_batch_par_');
      try {
        for (final base in [seqRoot, parRoot]) {
          for (final e in original.entries) {
            // ⚠️ 复制时必须保留【密文文件名】：这两个目录接下来要走
            // buildJobs(encrypting: false)，会对文件名做 base32 解密。
            // 若沿用明文名，buildJobs 会把明文名喂进 decryptFileName
            // ⇒ base32 解码直接抛 FormatException（例如字符 'F' 非法）。
            final parts = e.key.split('/');
            final relEncrypted = p.joinAll([
              ...parts.sublist(0, parts.length - 1),
              crypt.encryptFileName(parts.last),
            ]);
            final dst = File(p.join(base.path, relEncrypted));
            dst.parent.createSync(recursive: true);
            File(encryptedPathOf(root.path, e.key)).copySync(dst.path);
          }
        }

        await CryptBatchRunner.run(
          dataKey: crypt.derivedKeys.dataKey,
          jobs: buildJobs(seqRoot, encrypting: false),
          encrypting: false,
          workers: 1, // 强制顺序回退
        );
        await CryptBatchRunner.run(
          dataKey: crypt.derivedKeys.dataKey,
          jobs: buildJobs(parRoot, encrypting: false),
          encrypting: false,
          workers: 4,
        );

        for (final e in original.entries) {
          final seq = File(p.join(seqRoot.path, p.joinAll(e.key.split('/'))));
          final par = File(p.join(parRoot.path, p.joinAll(e.key.split('/'))));
          expect(seq.existsSync(), isTrue, reason: '顺序路径未还原：${e.key}');
          expect(par.existsSync(), isTrue, reason: '并行路径未还原：${e.key}');
          expect(
            par.readAsBytesSync(),
            orderedEquals(seq.readAsBytesSync()),
            reason: '两条路径结果不一致：${e.key}',
          );
          expect(
            par.readAsBytesSync(),
            orderedEquals(e.value),
            reason: '与原文不一致：${e.key}',
          );
        }
      } finally {
        for (final d in [seqRoot, parRoot]) {
          if (await d.exists()) {
            try {
              await d.delete(recursive: true);
            } catch (_) {}
          }
        }
      }
    });

    test('总量低于阈值时自动回退顺序路径，结果同样正确', () async {
      await File(
        p.join(root.path, 'small.dat'),
      ).writeAsBytes(Uint8List(64 * 1024));
      final jobs = buildJobs(root, encrypting: true);
      expect(
        jobs.single.readBytes,
        lessThan(CryptBatchRunner.minBytesForIsolate),
        reason: '前置：单个小文件应触发顺序回退',
      );

      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: jobs,
        encrypting: true,
        workers: 4, // 即便给了 4，也要因为总量不足而回退
      );

      expect(tmpLeftovers(root), isEmpty);
      expect(
        decryptWholeFile(encryptedPathOf(root.path, 'small.dat')),
        orderedEquals(Uint8List(64 * 1024)),
      );
    });

    test('默认分片数在 [1, maxWorkers] 区间内', () {
      final n = CryptBatchRunner.defaultWorkerCount();
      expect(n, greaterThanOrEqualTo(1));
      expect(n, lessThanOrEqualTo(CryptBatchRunner.maxWorkers));
    });
  });

  // ==================================================================
  group('进度契约', () {
    test('onBytes 单调递增并收敛到总字节；onJobDone == 作业数', () async {
      buildTree(root);
      final jobs = buildJobs(root, encrypting: true);
      final totalBytes = jobs.fold<int>(0, (s, j) => s + j.readBytes);

      var last = -1;
      var monotonic = true;
      var jobDone = 0;
      var sawTotal = false;

      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: jobs,
        encrypting: true,
        workers: 4,
        onBytes: (b, t) {
          if (b < last) monotonic = false;
          last = b;
          expect(t, totalBytes, reason: '总字节数应恒定');
          if (b == totalBytes) sawTotal = true;
        },
        onJobDone: () => jobDone++,
      );

      expect(monotonic, isTrue, reason: '进度不得回落（曾因把单块增量当累计值而跳回）');
      expect(jobDone, jobs.length);
      expect(sawTotal, isTrue, reason: '最终必须跑到 100%');
    });

    test('空作业列表：立即返回且不回调', () async {
      var called = false;
      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: const <CryptBatchJob>[],
        encrypting: true,
        workers: 4,
        onBytes: (bytes, total) => called = true,
        onJobDone: () => called = true,
      );
      expect(called, isFalse);
    });
  });

  // ==================================================================
  group('原子写与失败处理', () {
    test('源文件被删除、无临时文件残留、mtime 被保留', () async {
      final original = buildTree(root);
      final jobs = buildJobs(root, encrypting: true);
      final srcPaths = jobs.map((j) => j.srcPath).toList();

      // 钉一个过去的时间戳，验证 setLastModified 真的生效
      final stamp = DateTime(2020, 1, 2, 3, 4, 5);
      for (final j in jobs) {
        File(j.srcPath).setLastModifiedSync(stamp);
      }
      final jobsWithStamp = buildJobs(root, encrypting: true);
      expect(jobsWithStamp.length, jobs.length);

      await CryptBatchRunner.run(
        dataKey: crypt.derivedKeys.dataKey,
        jobs: jobsWithStamp,
        encrypting: true,
        workers: 4,
      );

      for (final s in srcPaths) {
        expect(File(s).existsSync(), isFalse, reason: '源文件未被删除：$s');
      }
      expect(tmpLeftovers(root), isEmpty, reason: '有 *.zencrypt_tmp 残留');

      for (final e in original.entries) {
        final mtime = File(
          encryptedPathOf(root.path, e.key),
        ).lastModifiedSync();
        expect(
          mtime.difference(stamp).inSeconds.abs(),
          lessThanOrEqualTo(2), // 文件系统时间戳精度（FAT 系）按 2 秒算
          reason: 'mtime 未保留：${e.key} -> $mtime',
        );
      }
    });

    test('作业失败：抛出异常、不残留临时文件、源文件完好', () async {
      // 刻意做够 5 MiB，让这批作业**真的走并行分支** —— 失败发生在 worker
      // 侧、其余分片被强杀，才会暴露「强杀打断写盘 ⇒ 留下 *.zencrypt_tmp」
      // 这类只在并行路径上出现的脏状态。
      final good = File(p.join(root.path, 'good.dat'))
        ..writeAsBytesSync(Uint8List(5 * 1024 * 1024));
      final goodTarget = p.join(root.path, crypt.encryptFileName('good.dat'));
      final badTarget = p.join(root.path, crypt.encryptFileName('missing.dat'));

      final jobs = <CryptBatchJob>[
        CryptBatchJob(
          srcPath: good.path,
          targetPath: goodTarget,
          tmpPath: '$goodTarget$kTmpSuffix',
          readBytes: good.lengthSync(),
          modifiedMs: good.statSync().modified.millisecondsSinceEpoch,
        ),
        CryptBatchJob(
          srcPath: p.join(root.path, 'missing.dat'), // 不存在 → 必然失败
          targetPath: badTarget,
          tmpPath: '$badTarget$kTmpSuffix',
          readBytes: 1024,
          modifiedMs: DateTime.now().millisecondsSinceEpoch,
        ),
      ];

      await expectLater(
        CryptBatchRunner.run(
          dataKey: crypt.derivedKeys.dataKey,
          jobs: jobs,
          encrypting: true,
          workers: 4,
        ),
        throwsA(isA<Object>()),
      );

      expect(tmpLeftovers(root), isEmpty, reason: '失败作业的临时文件必须被清理');
      expect(
        good.existsSync() || File(goodTarget).existsSync(),
        isTrue,
        reason: '失败不得把源文件弄丢（要么还是源文件，要么已成产物）',
      );
    });
  });
}
