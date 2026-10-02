import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cache_clean_service.dart';
import 'update_apk_cache.dart';

/// 「空间」页**垃圾清理**的扫描与清理实现。
///
/// ## 范围（三处，全部是「删了不影响用户数据」的缓存）
/// 1. ZenFile 公共缓存目录（`/storage/emulated/0/ZenFile`）——**删除范围与
///    `CacheCleanService.wipe` 严格一致**：保留项一律通过
///    `CacheCleanService.shouldPreserve` 判断，本类**绝不维护第二份保留清单**
///    （本项目已栽过多次「改一处 ≠ 改完」；保留清单一旦不同步就是丢用户数据）。
///    `Backups` / `crash` / `Receive` / `webdav_debug.log` 既不算垃圾、也永远不会被删。
/// 2. 旧版残留的远程缓存目录（设置页「清除远程缓存」清理的同一份清单）。
/// 3. app 私有缓存（[getTemporaryDirectory]）：各类临时文件。其中**未过期的
///    版本更新安装包**（[UpdateApkCache.retention] 24h 窗口内）可能是系统安装器
///    正在读取的文件，扫描与清理都跳过（详见 [UpdateApkCache] 的类注释）。
///
/// ## 约定（与 `CacheCleanService` 相同）
/// **任何异常都不外抛** —— 清理失败只该是「没清干净」，不该变成新的崩溃源。
/// 扫描/统计一律在独立 isolate 中执行，避免大缓存目录阻塞 UI。
class JunkCleanService {
  JunkCleanService._();

  /// 旧版残留的缓存位置（与设置页 `_clearRemoteCache` 同一份清单，勿单独维护）。
  static const List<String> _legacyCacheDirs = [
    '/storage/emulated/0/Android/data/com.sequl.zenfile/cache/remote_cache',
    '/storage/emulated/0/Android/data/com.sequl.zenfile/cache/remote_thumbnails',
  ];

  /// [scan] 返回的下标含义。
  static const int idxZenfileCache = 0;
  static const int idxLegacyCache = 1;
  static const int idxAppTemp = 2;

  /// 扫描可清理的垃圾体积。
  ///
  /// 返回三元组字节数（见 [idxZenfileCache] 等）：
  /// `[ZenFile 公共缓存, 旧版残留缓存, app 私有临时文件]`。
  static Future<List<int>> scan() async {
    try {
      final tempDir = await getTemporaryDirectory();
      return await Isolate.run(() => _scanSync([
            CacheCleanService.basePath,
            ..._legacyCacheDirs,
            tempDir.path,
          ]));
    } catch (_) {
      return const [0, 0, 0];
    }
  }

  /// 执行清理，返回**实际释放**的字节数（清理前后各扫一次的差值，
  /// 个别文件被占用删不掉时不会虚报）。
  static Future<int> clean() async {
    var freed = 0;
    try {
      final before = await scan();

      // ① ZenFile 公共缓存目录：CacheCleanService 是**唯一**清理入口
      //    （保留清单 / 运行目录重建 / .nomedia 标记都在那边）。
      await CacheCleanService.wipe();

      // ② 旧版残留的缓存目录：整目录删除（与设置页一致）。
      for (final dir in _legacyCacheDirs) {
        try {
          final d = Directory(dir);
          if (d.existsSync()) await d.delete(recursive: true);
        } catch (_) {}
      }

      // ③ app 私有缓存：跳过未过期的更新安装包，其余全部删除。
      try {
        final tempDir = await getTemporaryDirectory();
        await Isolate.run(() => _cleanTempSync(tempDir.path));
      } catch (_) {}

      final after = await scan();
      for (var i = 0; i < before.length && i < after.length; i++) {
        final d = before[i] - after[i];
        if (d > 0) freed += d;
      }
    } catch (_) {
      // 清理失败不外抛：返回已统计到的释放量即可。
    }
    return freed;
  }

  // ---------------- 以下都在 isolate 中同步执行 ----------------

  static List<int> _scanSync(List<String> paths) {
    final zenfile = _dirSize(paths[0], preserveTopLevel: true);
    var legacy = 0;
    for (var i = 1; i < paths.length - 1; i++) {
      legacy += _dirSize(paths[i]);
    }
    final temp = paths.length > 1 ? _tempJunkSize(paths.last) : 0;
    return [zenfile, legacy, temp];
  }

  /// 统计 [path] 的总体积。[preserveTopLevel] = true 时跳过
  /// `CacheCleanService` 保留清单里的**顶层**条目（与删除范围严格对齐）。
  static int _dirSize(String path, {bool preserveTopLevel = false}) {
    try {
      final base = Directory(path);
      if (!base.existsSync()) return 0;
      var total = 0;

      void walk(Directory dir, {required bool isTop}) {
        try {
          for (final entity in dir.listSync(followLinks: false)) {
            if (isTop &&
                preserveTopLevel &&
                CacheCleanService.shouldPreserve(p.basename(entity.path))) {
              continue;
            }
            try {
              if (entity is File) {
                total += entity.lengthSync();
              } else if (entity is Directory) {
                walk(entity, isTop: false);
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      walk(base, isTop: true);
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// app 私有缓存里的垃圾体积：未过期的更新安装包不算垃圾。
  static int _tempJunkSize(String path) {
    try {
      final base = Directory(path);
      if (!base.existsSync()) return 0;
      final cutoff = DateTime.now().subtract(UpdateApkCache.retention);
      var total = 0;

      void walk(Directory dir) {
        try {
          for (final entity in dir.listSync(followLinks: false)) {
            try {
              if (entity is File) {
                if (UpdateApkCache.isUpdateApk(entity.path) &&
                    entity.lastModifiedSync().isAfter(cutoff)) {
                  continue;
                }
                total += entity.lengthSync();
              } else if (entity is Directory) {
                walk(entity);
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      walk(base);
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// 删除 app 私有缓存内容（跳过未过期的更新安装包）。
  /// 正在被占用的文件删不掉就静默跳过 —— 与「没清干净」的约定一致。
  static void _cleanTempSync(String path) {
    try {
      final base = Directory(path);
      if (!base.existsSync()) return;
      final cutoff = DateTime.now().subtract(UpdateApkCache.retention);

      void walk(Directory dir) {
        try {
          for (final entity in dir.listSync(followLinks: false)) {
            try {
              if (entity is File) {
                if (UpdateApkCache.isUpdateApk(entity.path) &&
                    entity.lastModifiedSync().isAfter(cutoff)) {
                  continue;
                }
                entity.deleteSync();
              } else if (entity is Directory) {
                walk(entity);
                try {
                  entity.deleteSync(); // 只删得掉空目录
                } catch (_) {}
              }
            } catch (_) {}
          }
        } catch (_) {}
      }

      walk(base);
    } catch (_) {}
  }
}
