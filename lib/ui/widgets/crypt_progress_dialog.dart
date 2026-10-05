import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'progress_ring_shell.dart';

/// 保险箱加密/解密进度数据：整体进度 + 当前文件字节进度 + 文件计数器。
class CryptProgressData {
  /// 整体进度（0.0 ~ 1.0）
  final double overall;

  /// 当前文件已处理字节（内圈绿色进度环）
  final int fileBytes;

  /// 当前文件总字节；0 表示未知/未开始（内圈显示空环）
  final int fileTotal;

  /// 当前处理到第几个文件（1 基）；0 表示未知
  final int fileIndex;

  /// 本次操作涉及的文件总数；0 表示未知
  final int fileCount;

  const CryptProgressData({
    required this.overall,
    this.fileBytes = 0,
    this.fileTotal = 0,
    this.fileIndex = 0,
    this.fileCount = 0,
  });
}

/// 加密/解密进度控制器：把「文件数粒度」与「当前文件字节粒度」两个回调
/// 合并到同一个 ValueNotifier，供双层圆环弹窗消费。
class CryptProgressController {
  final ValueNotifier<CryptProgressData?> notifier = ValueNotifier(null);

  double _overall = 0;
  int _fileBytes = 0;
  int _fileTotal = 0;
  int _fileIndex = 0;
  int _fileCount = 0;

  /// 是否已有「显式整体进度」来源（[setOverall]，即批量多选的自定义折算）。
  /// 批量场景由调用方把「第 i 个文件 + 其内部进度」折算成全局比例，优先级最高，
  /// 不能被下面的字节兜底覆盖。
  bool _explicitOverall = false;

  /// 是否收到过字节级进度（[onFile]）。
  /// 字节进度来自 `CryptBatchRunner.onBytes`，是**全批次已处理 / 全批次总字节**
  /// （单调递增），因此无论单文件还是目录级它都是一个完整、连续的整体进度。
  bool _byteDriven = false;

  /// 对应加密/解密目录的 onProgress(processed, total) 回调（文件数粒度）
  void onOverall(int processed, int total) {
    // 文件计数器（目录级操作时 total 即文件总数）
    _fileIndex = processed;
    _fileCount = total;
    // 整体进度优先用字节（连续、精确）；只有拿不到字节时才退回文件数粒度
    //（少数路径如远程加密只给文件数）。
    if (!_byteDriven && !_explicitOverall) {
      _overall = total > 0 ? processed / total : 0;
    }
    _push();
  }

  /// 直接设置整体进度（0.0 ~ 1.0），用于批量场景自定义折算公式
  void setOverall(double value) {
    _explicitOverall = true;
    _overall = value.clamp(0.0, 1.0);
    _push();
  }

  /// 设置文件计数器（如「3/10」）。批量多选时 index 为「第几个选中项」。
  void setCounter(int index, int count) {
    _fileIndex = index;
    _fileCount = count;
    _push();
  }

  /// 对应单文件加密/解密的当前文件字节回调
  void onFile(int bytes, int total) {
    _fileBytes = bytes;
    _fileTotal = total;
    // 🔴 单文件加密/解密**没有** onProgress 回调（`CryptOperations.encryptFile` /
    // `decryptFile` 根本没有该参数）⇒ 外圈 `_overall` 恒为 0 ⇒ 表现为
    //「外圈不滚动、只有内圈在滚动」。这里用字节进度驱动整体进度：
    // - 单文件时「整体进度」本就等于该文件的进度；
    // - 目录级时 onBytes 是**全批次**字节，也是正确的整体进度。
    // 批量自定义折算（[setOverall]）优先，一旦用过就不再被字节覆盖。
    if (total > 0 && !_explicitOverall) {
      _byteDriven = true;
      _overall = (bytes / total).clamp(0.0, 1.0);
    }
    _push();
  }

  void _push() {
    notifier.value = CryptProgressData(
      overall: _overall.clamp(0.0, 1.0),
      fileBytes: _fileBytes,
      fileTotal: _fileTotal,
      fileIndex: _fileIndex,
      fileCount: _fileCount,
    );
  }

  void dispose() => notifier.dispose();
}

/// 保险箱加密/解密进度弹窗：双层圆环（与复制/剪切、压缩/解压一致）。
///
/// 外圈（主题色 8px）= 整体进度；内圈（绿色 5px）= 当前文件进度。
class CryptProgressDialog extends StatelessWidget {
  final String message;
  final CryptProgressData? progress;

  const CryptProgressDialog({
    super.key,
    required this.message,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final p = progress;
    final overall = (p?.overall ?? 0).clamp(0.0, 1.0);

    final fileBytesText = (p != null && p.fileTotal > 0)
        ? '${(p.fileBytes / p.fileTotal).clamp(0.0, 1.0) * 100}%'
        : '';

    // 文件计数器（如「3/10」）：仅在多文件操作时显示。
    // ⚠️ 必须走 [ProgressRingShell.counterLabel]：弹窗首帧 progress 还是 null、
    // 单文件路径只回调 onFile（不记文件数）时 fileCount 都是 0，直接 clamp 会抛
    // ArgumentError ⇒ 整个弹窗变成浅灰错误块（「白色透明层 + 没有进度条」）。
    final counterLabel = ProgressRingShell.counterLabel(
      p?.fileIndex ?? 0,
      p?.fileCount ?? 0,
    );

    return Center(
      child: ProgressRingShell(
        overall: overall,
        inner: (p != null && p.fileTotal > 0)
            ? (p.fileBytes / p.fileTotal).clamp(0.0, 1.0)
            : 0.0,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${(overall * 100).toStringAsFixed(0)}%',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: theme.colorScheme.primary,
            ),
          ),
          if (counterLabel != null) ...[
            const SizedBox(height: 4),
            Text(
              counterLabel,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            fileBytesText,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isDark
                  ? const Color(0xFF81C784)
                  : const Color(0xFF43A047),
            ),
          ),
        ],
      ),
    );
  }
}
