import 'package:flutter/material.dart';
import '../../services/background_archive_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import '../../core/utils.dart';
import 'progress_ring_shell.dart';

class BackgroundOperationProgressDialog extends StatelessWidget {
  final BackgroundArchiveService service;

  const BackgroundOperationProgressDialog({
    super.key,
    required this.service,
  });

  static Future<void> show(BuildContext context, BackgroundArchiveService service) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (dialogContext) {
        service.setActiveDialogContext(dialogContext);
        service.dialogCloseCallback = () {
          if (Navigator.canPop(dialogContext)) {
            Navigator.pop(dialogContext);
          }
        };
        return PopScope(
          canPop: false,
          child: BackgroundOperationProgressDialog(service: service),
        );
      },
    );
  }

  String _formatETA(double speedBytesPerSecond, double progress, int totalBytes) {
    if (speedBytesPerSecond <= 0 || progress <= 0) {
      return '--:--';
    }
    final remainingBytes = totalBytes * (1.0 - progress);
    final remainingSeconds = remainingBytes / speedBytesPerSecond;
    if (remainingSeconds < 60) {
      return '${remainingSeconds.round()}s';
    } else if (remainingSeconds < 3600) {
      final minutes = (remainingSeconds / 60).floor();
      final seconds = (remainingSeconds % 60).floor();
      return '${minutes}m ${seconds}s';
    } else {
      final hours = (remainingSeconds / 3600).floor();
      final minutes = ((remainingSeconds % 3600) / 60).floor();
      return '${hours}h ${minutes}m';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: ValueListenableBuilder<BackgroundOperation?>(
        valueListenable: service.activeOperation,
        builder: (context, operation, child) {
          if (operation == null) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (Navigator.canPop(context)) {
                Navigator.pop(context);
              }
            });
            return const SizedBox.shrink();
          }

          final percent = operation.progress.clamp(0.0, 1.0);

          final speedText = operation.speedBytesPerSecond > 0
              ? '${FileUtils.formatBytes((operation.speedBytesPerSecond).round(), 1)}/s'
              : '—';
          final etaText = _formatETA(operation.speedBytesPerSecond, percent, operation.totalBytes);
          final bytesText = '${FileUtils.formatBytes(operation.bytesProcessed, 1)} / ${FileUtils.formatBytes(operation.totalBytes, 1)}';

          // 文件计数器（如「3/10」）：仅在多文件操作时显示。
          final showCounter = operation.totalFiles > 1;
          final counterIndex =
              operation.currentFileIndex.clamp(1, operation.totalFiles);

          return ProgressRingShell(
            overall: percent,
            animateOverall: true,
            inner: operation.currentFileTotal > 0
                ? (operation.currentFileBytes / operation.currentFileTotal)
                    .clamp(0.0, 1.0)
                : 0.0,
            children: [
              // 顶部后台按钮（文字）
              SizedBox(
                height: 32,
                child: OutlinedButton(
                  onPressed: () {
                    service.runInBackground();
                    if (Navigator.canPop(context)) {
                      Navigator.pop(context);
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.primary,
                    side: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                  ),
                  child: Text(
                    L10n.of(context).ui_background,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // 标题
              Text(
                operation.title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),

              // 副标题（压缩包名 + 速度）
              Text(
                operation.archiveName,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),

              // 当前文件信息
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  operation.currentFile.isEmpty
                      ? L10n.of(context).msg67bd9375
                      : operation.currentFile,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 10),

              // 统计信息
              Column(
                children: [
                  Text(
                    bytesText,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  if (showCounter) ...[
                    const SizedBox(height: 3),
                    Text(
                      '$counterIndex/${operation.totalFiles}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 3),
                  Text(
                    speedText,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    etaText.isNotEmpty
                        ? '${L10n.of(context).ui_time_remaining} $etaText'
                        : '',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // 停止按钮
              SizedBox(
                width: 100,
                height: 36,
                child: OutlinedButton(
                  onPressed: () {
                    service.cancelOperation();
                    Navigator.of(context).pop();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    side: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.2),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                    ),
                    padding: EdgeInsets.zero,
                  ),
                  child: Text(
                    L10n.of(context).ui_cancel,
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
