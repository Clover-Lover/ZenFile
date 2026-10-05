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

  /// 对应加密/解密目录的 onProgress(processed, total) 回调（文件数粒度）
  void onOverall(int processed, int total) {
    _overall = total > 0 ? processed / total : 0;
    // 顺带记录文件计数器（目录级操作时 total 即文件总数）
    _fileIndex = processed;
    _fileCount = total;
    _push();
  }

  /// 直接设置整体进度（0.0 ~ 1.0），用于批量场景自定义折算公式
  void setOverall(double value) {
    _overall = value;
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
    final fileCount = p?.fileCount ?? 0;
    final showCounter = fileCount > 1;
    final counterIndex = (p?.fileIndex ?? 0).clamp(1, fileCount);

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
          if (showCounter) ...[
            const SizedBox(height: 4),
            Text(
              '$counterIndex/$fileCount',
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
