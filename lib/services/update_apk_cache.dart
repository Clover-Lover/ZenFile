import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'webdav_debug_log.dart';

/// 「版本更新」自动下载的安装包，在 **app 私有缓存目录**里的唯一管理者。
///
/// ## 为什么要有这个类
/// 「版本更新」页下载 APK 用的是 [getTemporaryDirectory]（Android 上是
/// `/data/user/0/<pkg>/cache`），文件名 `ZenFile_update_<版本>.apk`。下载完交给
/// 系统安装器（`ACTION_VIEW` + FileProvider）后，应用**拿不到「装完了没」的回报**
/// ——于是谁也没删它。结果每更新一次就在私有缓存里留一个十几 MB 的安装包，
/// 更新几次后「应用缓存」越滚越大（用户反馈的正是这个）。
///
/// 半成品更糟：下载中途失败/被取消时，写了一半的文件同样没人清理。
///
/// ## 清理时机（三处，都不依赖安装结果）
/// 1. **启动时**：[sweep] 清掉超过 [retention] 的历史包（挂在新版本检测前，
///    幂等、失败静默）；
/// 2. **每次下载前**：再 [sweep] 一次并保护本次目标文件 —— 用户点「下载安装」
///    就说明上一轮已经结束，历史包没用了；
/// 3. **下载失败**：[discard] 立即删掉写了一半的文件。
///
/// ⚠️ 故意**不做**「安装一返回就删」：走系统安装器时应用无法得知用户是「装完了」
/// 还是「还在确认」，立刻删会让安装器读不到文件而安装失败（`ApkInstallerService`
/// 里临时副本用 24h 延迟兜底，就是同一个原因）。真正的兜底点是**下一次启动**：
/// 那时新版本已经装上，旧安装包必然用完。
class UpdateApkCache {
  UpdateApkCache._();

  /// 文件名前缀。⚠️ 与历史版本**完全一致**，这样用户机器上已经堆积的旧包也能被
  /// 一次启动清理掉（改名等于放过存量垃圾）。
  static const String prefix = 'ZenFile_update_';

  static const String _suffix = '.apk';

  /// 过期兜底窗口：超过这个时长仍留在缓存里的更新包，视为安装流程已结束。
  ///
  /// 与 `ApkInstallerService` 临时文件的保留时长（24h）取同一口径 —— 宁可多留
  /// 一天，也不要冒「删掉正在被系统安装器读取的文件」的风险。
  static const Duration retention = Duration(hours: 24);

  /// 本次下载的目标文件（文件名规则只在这里定义一次）。
  ///
  /// [dirPathOverride] 是**测试注入点**：真机缓存路径在宿主上必然不存在，
  /// 不注入就等于没测到清理逻辑本身。
  static Future<File> targetFile(
    String version, {
    String? dirPathOverride,
  }) async {
    final dir = dirPathOverride ?? (await getTemporaryDirectory()).path;
    return File(p.join(dir, '$prefix$version$_suffix'));
  }

  /// 删掉私有缓存里**已过期**的更新安装包，返回删除个数。
  ///
  /// * [keepPath]：本次要用的文件，无论多旧都**不删**（避免刚下完就被自己清掉）；
  /// * [dirPathOverride]：测试注入点（见 [targetFile]）；
  /// * **任何异常都不外抛** —— 清理失败只该是「没清干净」，不该变成新的崩溃源
  ///   （与 `CacheCleanService` 同一约定）。
  static Future<int> sweep({
    String? keepPath,
    String? dirPathOverride,
  }) async {
    try {
      final base = dirPathOverride ?? (await getTemporaryDirectory()).path;
      final dir = Directory(base);
      if (!await dir.exists()) return 0;

      final cutoff = DateTime.now().subtract(retention);
      var deleted = 0;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        if (!isUpdateApk(entity.path)) continue;
        if (keepPath != null && p.equals(entity.path, keepPath)) continue;
        try {
          if ((await entity.stat()).modified.isAfter(cutoff)) continue;
          await entity.delete();
          deleted++;
        } catch (_) {}
      }
      if (deleted > 0) {
        WebdavDebugLog.log('[update] swept $deleted cached apk(s)');
      }
      return deleted;
    } catch (_) {
      return 0;
    }
  }

  /// 立即删掉某个更新安装包（下载失败留下的半成品）。
  ///
  /// 只认 [prefix] / [suffix] 命名的文件 —— 传进来的若是别的路径（例如更新页
  /// 降级成「浏览器下载」时用户自己的文件），绝不越权删除。
  static Future<void> discard(String path) async {
    if (!isUpdateApk(path)) return;
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 是否由本类管理（`ZenFile_update_*.apk`）。
  static bool isUpdateApk(String path) {
    final name = p.basename(path);
    return name.startsWith(prefix) && name.endsWith(_suffix);
  }
}
