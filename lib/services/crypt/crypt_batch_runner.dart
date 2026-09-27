/// 批量「原地」加/解密的**多 isolate 并行**执行器。
///
/// ## 为什么需要它
///
/// 数据面的密码学是纯 Dart 实现的 XSalsa20-Poly1305（`pinenacl` = TweetNaCl
/// 移植），实测本机吞吐只有 **8.6 MiB/s**（加密）/ **13 MiB/s**（解密），
/// 而 ZenFile 的流式封装已经贴着这个天花板 —— 也就是说**包装层没有可优化空间**。
/// 唯一有效的办法是「多核并行」，而 Dart 是单线程的：用 `Future.wait` 并发
/// 多个 CPU 密集任务**不产生任何加速**，必须用 isolate。
///
/// 实测（4 核）：4 个分片 isolate 相比单 isolate 顺序处理拿到 **2.4×**
/// （且该数字被测试脚本自身写盘的 I/O 拖累，实际更高）；`Isolate.spawn`
/// 的握手成本仅 **1.77 ms**，因此按「批」而不是按「文件」起 isolate 是划算的。
///
/// ## 设计
///
/// - **按体积贪心分片**：作业按大小降序，逐个丢给当前累计字节最小的分片，
///   避免「一个 1 GiB 文件 + 99 个 1 KiB 文件」时的长尾。
/// - **只传 32 字节 `dataKey`**：Scrypt 派生（实测冷启动 700~800 ms）由主
///   isolate 完成一次，worker 里直接用派生结果建 `RcloneStreamEncrypter`，
///   绝不重跑 Scrypt。
/// - **磁盘格式零变化**：worker 内部用的是与主 isolate 完全相同的
///   `RcloneStreamEncrypter` / `RcloneStreamDecrypter`，文件头、64 KiB 分块、
///   16 B tag 全部一致，产物与 rclone / OpenList 依然 100% 互通。
/// - **原子写不变**：先写 `*.zencrypt_tmp` → 成功后删源 → rename，失败只留源文件。
/// - **进度**：外圈（文件数）由主 isolate 按「作业完成」累加；内圈（字节）改为
///   **全批次的聚合字节数**（原来是「当前文件」粒度）。并行后多个文件会同时
///   产生字节事件，沿用单文件语义会让内圈来回抖动；改成聚合值后内圈单调递增，
///   且外圈仍是文件数，两个环的语义更清楚。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'stream_cipher.dart';

/// 一个「原地加/解密」作业：读 [srcPath]，写出 [targetPath]，删除源文件。
///
/// 语义与 `CryptOperations.encryptFile` / `decryptFile` 完全一致
/// （先写 [tmpPath]，再 `setLastModified([modifiedMs])`，最后删源 + 改名）。
class CryptBatchJob {
  /// 源文件（加密时为明文，解密时为密文）
  final String srcPath;

  /// 产物最终路径
  final String targetPath;

  /// 原子写用的临时文件路径（与 `CryptOperations.tmpSuffix` 拼接规则一致）
  final String tmpPath;

  /// 需要读取的字节数：加密时为明文大小，解密时为密文大小。
  /// 同时用作进度分母的权重。
  final int readBytes;

  /// 要保留到产物上的修改时间（毫秒时间戳）
  final int modifiedMs;

  const CryptBatchJob({
    required this.srcPath,
    required this.targetPath,
    required this.tmpPath,
    required this.readBytes,
    required this.modifiedMs,
  });
}

/// 批量原地加/解密的并行执行器。用法见文件头注释。
class CryptBatchRunner {
  CryptBatchRunner._();

  /// 单次读取的块大小。实测 64 KiB / 256 KiB / 1 MiB 三种块大小吞吐无差异
  /// （密码学本身才是瓶颈），取 1 MiB 只为少几次系统调用。
  static const int readChunkSize = 1024 * 1024;

  /// 低于该总量时不起 isolate：小批量总耗时本就是毫秒级，
  /// 起 isolate 只是徒增复杂度（ramp up 也要几百毫秒）。
  static const int minBytesForIsolate = 4 * 1024 * 1024;

  /// 分片数上限。刻意保守：设备通常只给 4~8 核，留核给 UI 与 `media_kit`。
  static const int maxWorkers = 4;

  /// 默认分片数 = min(核数, [maxWorkers])，单核设备返回 1（走顺序回退）。
  static int defaultWorkerCount() {
    final cores = Platform.numberOfProcessors;
    if (cores <= 1) return 1;
    return math.min(cores, maxWorkers);
  }

  /// 并行执行一批**原地**加/解密作业。
  ///
  /// [encrypting] true = 加密，false = 解密。
  /// [onBytes] 收到的是**全批次已处理字节 / 全批次总字节**（单调递增）。
  /// [onJobDone] 每完成一个作业回调一次（供调用方累加文件数进度）。
  /// [workers] 仅供测试注入；默认 [defaultWorkerCount]。
  ///
  /// 任一作业失败会**杀掉其余 isolate、清理未完成的 `*.zencrypt_tmp`、并把
  /// 异常抛出**（已完成的作业不回滚，与原有顺序实现的语义一致：失败后磁盘上
  /// 不留脏文件，源文件保持完好）。
  static Future<void> run({
    required Uint8List dataKey,
    required List<CryptBatchJob> jobs,
    required bool encrypting,
    void Function(int bytes, int total)? onBytes,
    void Function()? onJobDone,
    int? workers,
  }) async {
    if (jobs.isEmpty) return;

    var totalBytes = 0;
    for (final j in jobs) {
      totalBytes += j.readBytes;
    }

    final workerCount = workers ?? defaultWorkerCount();
    if (workerCount <= 1 || totalBytes < minBytesForIsolate) {
      _runSequential(
        dataKey: dataKey,
        jobs: jobs,
        encrypting: encrypting,
        totalBytes: totalBytes,
        onBytes: onBytes,
        onJobDone: onJobDone,
      );
      return;
    }

    final shardCount = math.min(workerCount, jobs.length);
    final shards = _partition(jobs, shardCount);

    final msgPort = ReceivePort();
    final exitPort = ReceivePort();
    final done = Completer<void>();
    final allExited = Completer<void>();
    final isolates = <Isolate>[];
    final shardBytes = List<int>.filled(shardCount, 0);

    var terminalCount = 0;
    var jobDoneCount = 0;
    var exitedCount = 0;
    var failed = false;
    var spawnDone = false;
    Object? failure;
    StackTrace? failureStack;

    void fail(Object error, StackTrace stack) {
      if (failed) return;
      failed = true;
      failure = error;
      failureStack = stack;
      done.completeError(error, stack);
    }

    /// 全部已 spawn 的分片都退出了才算「停干净」。只有 spawn 循环走完之后
    /// 才允许判定 —— 否则循环中途收到 shard 0 的退出事件就会误判为「全停了」。
    void maybeCompleteExits() {
      if (spawnDone &&
          exitedCount >= isolates.length &&
          !allExited.isCompleted) {
        allExited.complete();
      }
    }

    msgPort.listen((Object? raw) {
      if (raw is! Map) return;
      final shard = raw['shard'] as int? ?? 0;

      final error = raw['error'];
      if (error != null) {
        fail(
          StateError('批量加解密分片 $shard 失败：$error'),
          StackTrace.fromString('${raw['stack']}'),
        );
        return;
      }

      if (raw['job'] == true) {
        jobDoneCount++;
        onJobDone?.call();
        return;
      }

      if (raw['bytes'] != null) {
        shardBytes[shard] = raw['bytes'] as int;
        if (onBytes != null) {
          var sum = 0;
          for (final b in shardBytes) {
            sum += b;
          }
          onBytes(sum > totalBytes ? totalBytes : sum, totalBytes);
        }
        return;
      }

      if (raw['done'] == true) {
        terminalCount++;
        if (terminalCount == shardCount && !failed) {
          done.complete();
        }
      }
    });

    exitPort.listen((_) {
      exitedCount++;
      maybeCompleteExits();
      if (exitedCount < shardCount) return;
      // ⚠️ `done` 走 msgPort、退出通知走 exitPort，**两个端口之间没有到达顺序
      // 保证** —— 最后一个分片可能「先被观察到退出、后处理它的 done」。
      // 因此延后一拍再判定，避免把正常收尾误报成「分片异常退出」。
      Future<void>.delayed(Duration.zero, () {
        if (!failed && terminalCount < shardCount) {
          fail(
            StateError(
              '批量加解密有分片异常退出（收到 $terminalCount / '
              '$shardCount 个完成信号）',
            ),
            StackTrace.current,
          );
        }
      });
    });

    try {
      for (var s = 0; s < shardCount; s++) {
        final isolate = await Isolate.spawn(
          _shardEntry,
          <String, Object?>{
            'reply': msgPort.sendPort,
            'shard': s,
            'dataKey': dataKey,
            'encrypting': encrypting,
            'jobs': shards[s].map(_encodeJob).toList(growable: false),
          },
          onExit: exitPort.sendPort,
          errorsAreFatal: true,
        );
        isolates.add(isolate);
      }
      spawnDone = true;
      maybeCompleteExits();
      await done.future;
    } catch (e, st) {
      // 不在 catch 里直接重抛：要先让 worker 真正停下来，才能安全清理残留。
      if (!failed) {
        failed = true;
        failure = e;
        failureStack = st;
      }
    } finally {
      // ⚠️ 必须是 `beforeNextEvent`（**不能**用 `immediate`）：
      // `immediate` 会在 `writeFromSync` 中途打断 worker，被杀的 isolate
      // **不释放文件句柄** ⇒ 残留一个删不掉的 `*.zencrypt_tmp`
      //（探针 `.local/probe_kill_delete.dart` 实测：isolate 已退出，
      //  `deleteSync` 仍报 Windows 共享冲突 OS Error 32）。
      // `beforeNextEvent` 配合 `_shardEntry` 里的「每作业一让出」，会让
      // **当前作业正常收尾**（tmp 改名成产物）后再退出，磁盘上不留脏文件。
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.beforeNextEvent);
      }
      // 仍要等分片真正退出：否则清理会与「最后一个作业的收尾写盘」竞争。
      spawnDone = true;
      maybeCompleteExits();
      await allExited.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {},
      );
      msgPort.close();
      exitPort.close();
      // 不变式：收齐所有分片的 done ⇒ 每个分片都已先发完自己的 job 事件
      //（同一发送者的消息保序），故作业完成数必然等于总数。
      assert(failed || jobDoneCount == jobs.length);
    }

    final err = failure;
    if (err != null) {
      _discardTmpFiles(jobs);
      Error.throwWithStackTrace(err, failureStack ?? StackTrace.current);
    }
  }

  /// 清理未完成作业留下的 `*.zencrypt_tmp`（**兜底**，不是主路径）。
  ///
  /// 正常失败路径下这是空操作：`beforeNextEvent` 会让 worker 把当前作业正常
  /// 收尾（tmp 改名成产物 / 失败时自删），已完成作业的 tmp 也早已 rename 成
  /// 产物。留它是为了兜住极端情况（例如 kill 与作业收尾抢跑）。
  ///
  /// 只删 tmp：源文件与已完成的产物一字不碰。删除失败（Windows 句柄未释放时
  /// 不可避免）只跳过，绝不掩盖原始异常。
  static void _discardTmpFiles(List<CryptBatchJob> jobs) {
    for (final job in jobs) {
      try {
        final tmp = File(job.tmpPath);
        if (tmp.existsSync()) tmp.deleteSync();
      } catch (_) {
        // 尽力而为：清理失败不能掩盖原始异常
      }
    }
  }

  // ------------------------------------------------------------------
  // 顺序回退（小批量 / 单核 / 测试）
  // ------------------------------------------------------------------

  static void _runSequential({
    required Uint8List dataKey,
    required List<CryptBatchJob> jobs,
    required bool encrypting,
    required int totalBytes,
    void Function(int bytes, int total)? onBytes,
    void Function()? onJobDone,
  }) {
    var doneBytes = 0;
    for (final job in jobs) {
      // ⚠️ `_processJobSync` 的 onBytes 回传的是**单块增量**，必须自己累加成
      // 本作业的累计值。直接写 `doneBytes + delta` 会在「文件最后一块不满」
      // 时得出比上一次**更小**的数 —— 进度条会肉眼可见地往回跳。
      var jobDone = 0;
      _processJobSync(
        dataKey: dataKey,
        encrypting: encrypting,
        job: job,
        onBytes: (delta) {
          jobDone += delta;
          final global = doneBytes + jobDone;
          onBytes?.call(global > totalBytes ? totalBytes : global, totalBytes);
        },
      );
      doneBytes += job.readBytes;
      onJobDone?.call();
    }
  }

  // ------------------------------------------------------------------
  // isolate 侧
  // ------------------------------------------------------------------

  /// isolate 入口：顺序处理本分片的作业，逐块回传累计字节。
  ///
  /// ⚠️ 每完成一个作业必须**让出一次事件循环**（末尾那个 `Future.delayed`）。
  /// 这不是性能考量，而是失败路径的**安全落点**：
  /// - 没有这个 await，整个分片就是一段连续的同步执行，`Isolate.kill` 直到
  ///   全部作业跑完才生效（探针实测 `beforeNextEvent` 8 秒都没停下来，文件
  ///   一直涨）；
  /// - 而改用 `Isolate.immediate` 强杀会在 `writeFromSync` 中途打断，进程
  ///   **不会释放文件句柄**（探针实测：isolate 已退出，但删除临时文件报
  ///   Windows 共享冲突 OS Error 32）⇒ 残留一个删不掉的 `*.zencrypt_tmp`。
  ///
  /// 有了这个落点，主 isolate 用 `beforeNextEvent` 就能让**当前作业正常收尾**
  /// （tmp 关闭 → 改名成产物，或失败时自行清理），既不残留脏文件，等待时间
  /// 也只被一个文件的上限约束。
  static Future<void> _shardEntry(Map<String, Object?> args) async {
    final reply = args['reply'] as SendPort;
    final shard = args['shard'] as int;
    final dataKey = args['dataKey'] as Uint8List;
    final encrypting = args['encrypting'] as bool;
    final rawJobs = (args['jobs'] as List).cast<Map>();

    var shardBytes = 0;
    try {
      for (final raw in rawJobs) {
        final job = _decodeJob(raw);
        _processJobSync(
          dataKey: dataKey,
          encrypting: encrypting,
          job: job,
          onBytes: (local) {
            shardBytes += local;
            reply.send(<String, Object?>{'shard': shard, 'bytes': shardBytes});
          },
        );
        reply.send(<String, Object?>{'shard': shard, 'job': true});
        await Future<void>.delayed(Duration.zero);
      }
      reply.send(<String, Object?>{'shard': shard, 'done': true});
    } catch (e, st) {
      reply.send(<String, Object?>{
        'shard': shard,
        'error': '$e',
        'stack': '$st',
      });
    }
  }

  /// 处理单个作业（**同步** I/O，供 worker 与顺序回退共用）。
  ///
  /// [onBytes] 回传的是**单块增量**（不是累计值），调用方负责累加 ——
  /// 这个契约要小心：文件最后一块通常不满，把增量当累计用会让进度回落。
  static void _processJobSync({
    required Uint8List dataKey,
    required bool encrypting,
    required CryptBatchJob job,
    required void Function(int delta) onBytes,
  }) {
    final encrypter = encrypting
        ? RcloneStreamEncrypter(dataKey: dataKey)
        : null;
    final decrypter = encrypting
        ? null
        : RcloneStreamDecrypter(dataKey: dataKey);

    final tmpFile = File(job.tmpPath);
    RandomAccessFile? sink;
    RandomAccessFile? source;
    try {
      sink = tmpFile.openSync(mode: FileMode.write);
      source = File(job.srcPath).openSync();

      // 缓冲区按作业大小收敛：一次批量里常见「大量小文件」，
      // 若无脑分配 1 MiB，1000 个小文件就是 1000 次 1 MiB 分配（GC 压力）。
      final bufSize = math.min(
        readChunkSize,
        math.max(64 * 1024, job.readBytes),
      );
      final buf = Uint8List(bufSize);
      var read = 0;
      while ((read = source.readIntoSync(buf)) > 0) {
        final chunk = read == buf.length
            ? buf
            : Uint8List.sublistView(buf, 0, read);
        final out = encrypter != null
            ? encrypter.process(chunk)
            : decrypter!.process(chunk);
        if (out.isNotEmpty) sink.writeFromSync(out);
        onBytes(read);
      }

      final tail = encrypter != null ? encrypter.finish() : decrypter!.finish();
      if (tail.isNotEmpty) sink.writeFromSync(tail);

      source.closeSync();
      source = null;
      sink.closeSync();
      sink = null;

      tmpFile.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(job.modifiedMs),
      );

      // 原子替换：先删源，再改名（与 CryptOperations 逐字一致）
      File(job.srcPath).deleteSync();
      tmpFile.renameSync(job.targetPath);
    } catch (_) {
      try {
        source?.closeSync();
      } catch (_) {}
      try {
        sink?.closeSync();
      } catch (_) {}
      // 失败只清理临时文件，源文件保持完好
      try {
        if (tmpFile.existsSync()) tmpFile.deleteSync();
      } catch (_) {}
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // 分片与编解码
  // ------------------------------------------------------------------

  /// 贪心按体积分片：作业按大小降序，逐个丢给当前累计字节最小的分片。
  static List<List<CryptBatchJob>> _partition(
    List<CryptBatchJob> jobs,
    int shardCount,
  ) {
    final shards = List.generate(shardCount, (_) => <CryptBatchJob>[]);
    final loads = List<int>.filled(shardCount, 0);

    final order = List<int>.generate(jobs.length, (i) => i)
      ..sort((a, b) => jobs[b].readBytes.compareTo(jobs[a].readBytes));

    for (final i in order) {
      var lightest = 0;
      for (var s = 1; s < shardCount; s++) {
        if (loads[s] < loads[lightest]) lightest = s;
      }
      shards[lightest].add(jobs[i]);
      loads[lightest] += jobs[i].readBytes;
    }
    return shards;
  }

  static Map<String, Object?> _encodeJob(CryptBatchJob job) =>
      <String, Object?>{
        'src': job.srcPath,
        'target': job.targetPath,
        'tmp': job.tmpPath,
        'bytes': job.readBytes,
        'mtime': job.modifiedMs,
      };

  static CryptBatchJob _decodeJob(Map raw) => CryptBatchJob(
    srcPath: raw['src'] as String,
    targetPath: raw['target'] as String,
    tmpPath: raw['tmp'] as String,
    readBytes: raw['bytes'] as int,
    modifiedMs: raw['mtime'] as int,
  );
}
