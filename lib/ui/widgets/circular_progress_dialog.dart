import 'package:flutter/material.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'progress_overlay.dart';
import 'progress_ring_shell.dart';

/// 通用圆形进度对话框（双层圆环，与复制/剪切、压缩/解压、保险箱加解密一致）。
///
/// 外圈（主题色 8px，padding=4 贴齐背景圆）= 整体进度；
/// 内圈（绿色 5px，padding=12）= 当前文件进度。
///
/// [title]        顶部标题（如「备份」「复制」）。
/// [statusNotifier] 监听状态文本变化（当前文件名 / 阶段说明）。
/// [percentage]   0~1 的静态整体进度；传 null 且未传 [progressNotifier] 时
///                显示不确定环（不显示百分比）。
/// [progressNotifier] 动态整体+当前文件进度（整体 0~1、当前文件 0~1，可为 null）。
/// [counterText]  文件计数器文本（如「3/10」）；为空则不显示。
/// [onCancel]     点「取消」回调；为空则不显示取消按钮。
/// [cancelLabel]  取消按钮文案，默认取 l10n.ui_cancel。
/// [onBackground] 点「后台」回调；为空则不显示后台按钮。
class CircularProgressDialog extends StatelessWidget {
  final String title;
  final ValueNotifier<String> statusNotifier;
  final double? percentage;
  final ValueNotifier<({double overall, double? inner})>? progressNotifier;
  final String? counterText;
  final VoidCallback? onCancel;
  final String? cancelLabel;
  final VoidCallback? onBackground;

  const CircularProgressDialog({
    super.key,
    required this.title,
    required this.statusNotifier,
    this.percentage,
    this.progressNotifier,
    this.counterText,
    this.onCancel,
    this.cancelLabel,
    this.onBackground,
  });

  static Future<void> show({
    required BuildContext context,
    required String title,
    required ValueNotifier<String> statusNotifier,
    double? percentage,
    ValueNotifier<({double overall, double? inner})>? progressNotifier,
    ValueNotifier<String>? counterNotifier,
    ProgressDialogHandle? handle,
    VoidCallback? onCancel,
    String? cancelLabel,
    VoidCallback? onBackground,
    bool barrierDismissible = false,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (dialogContext) {
        // 记下弹窗**自己**的 context：调用方之后用 `handle.close()` 关弹窗时
        // 必须落到弹窗所在的（根）Navigator，而不是页面所在的嵌套栈 ——
        // 否则 pop 会把页面自己弹掉、弹窗原地不动，表现为「取消 / 后台无响应、
        // 只能重启应用」（详见 progress_overlay.dart 的 ProgressDialogHandle）。
        handle?.attach(dialogContext);
        final dialog = counterNotifier == null
            ? CircularProgressDialog(
                title: title,
                statusNotifier: statusNotifier,
                percentage: percentage,
                progressNotifier: progressNotifier,
                onCancel: onCancel,
                cancelLabel: cancelLabel,
                onBackground: onBackground,
              )
            : ValueListenableBuilder<String>(
                valueListenable: counterNotifier,
                builder: (_, counter, __) => CircularProgressDialog(
                  title: title,
                  statusNotifier: statusNotifier,
                  percentage: percentage,
                  progressNotifier: progressNotifier,
                  counterText: counter.isEmpty ? null : counter,
                  onCancel: onCancel,
                  cancelLabel: cancelLabel,
                  onBackground: onBackground,
                ),
              );
        return PopScope(canPop: false, child: dialog);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final innerGreen =
        isDark ? const Color(0xFF81C784) : const Color(0xFF43A047);

    return Center(
      // ⚠️ 必须**同时**订阅 progressNotifier：此前这里只订阅 statusNotifier，而
      // `progressNotifier?.value` 只是「读一次」，并不在依赖树里 ⇒ 一旦同一文件内
      // 文件名不变（ValueNotifier 同值不 notify），整个文件处理期间圆环纹丝不动，
      // 只有切换到下一个文件时才顺带跳一下 —— 表现为「内圈和外圈都不滚动」
      //（云备份到远程时尤其明显）。
      child: ListenableBuilder(
        listenable: progressNotifier == null
            ? statusNotifier
            : Listenable.merge([statusNotifier, progressNotifier!]),
        builder: (context, _) {
          final status = statusNotifier.value;
          final progress = progressNotifier?.value;
          final percent =
              (progress?.overall ?? percentage ?? 0).clamp(0.0, 1.0);
          final innerPercent = progress?.inner;
          final showPercent = percentage != null || progressNotifier != null;

          return ProgressRingShell(
            overall: percent,
            indeterminate: !showPercent,
            inner: progressNotifier != null ? (innerPercent ?? 0) : null,
            children: [
              // 标题
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),

              // 整体百分比（确定进度时显示）
              if (showPercent)
                Text(
                  '${(percent * 100).round()}%',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: theme.colorScheme.primary,
                  ),
                ),
              if (showPercent) const SizedBox(height: 4),

              // 文件计数器（如「3/10」）
              if (counterText != null)
                Text(
                  counterText!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              if (counterText != null) const SizedBox(height: 4),

              // 当前文件百分比（绿色，与内圈同色）
              if (innerPercent != null)
                Text(
                  '${(innerPercent * 100).round()}%',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: innerGreen,
                  ),
                ),
              const SizedBox(height: 8),

              // 状态文本（当前文件名 / 阶段）
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 220),
                child: Text(
                  status.isEmpty
                      ? L10n.of(context).msg67bd9375
                      : status,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface
                        .withValues(alpha: 0.6),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: 12),

              // 操作按钮：取消 / 后台
              if (onCancel != null || onBackground != null)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (onCancel != null)
                      SizedBox(
                        width: 100,
                        height: 36,
                        child: OutlinedButton(
                          onPressed: onCancel,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme
                                .onSurface
                                .withValues(alpha: 0.6),
                            side: BorderSide(
                              color: theme.colorScheme.outline
                                  .withValues(alpha: 0.2),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(18),
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            cancelLabel ??
                                L10n.of(context).ui_cancel,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                    if (onCancel != null && onBackground != null)
                      const SizedBox(width: 12),
                    if (onBackground != null)
                      SizedBox(
                        width: 100,
                        height: 36,
                        child: OutlinedButton(
                          onPressed: onBackground,
                          style: OutlinedButton.styleFrom(
                            foregroundColor:
                                theme.colorScheme.primary,
                            side: BorderSide(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.3),
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(18),
                            ),
                            padding: EdgeInsets.zero,
                          ),
                          child: Text(
                            L10n.of(context).ui_background,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ),
                      ),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}
