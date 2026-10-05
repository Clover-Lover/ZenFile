import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 通用「处理中」遮罩
///
/// 用于替换此前 `Center(child: CircularProgressIndicator())` 的裸写法：
/// 那种写法配合 `showDialog` / `MaterialPageRoute` 时，遮罩本身没有背景内容，
/// 用户看到的就是「整屏发黑 + 中间一个转圈」，体验很差（原地加解密期间尤为明显）。
///
/// 用法：
/// - 作为 `showDialog` 的 builder（对话框自带 barrier，用 [scrim] = false）；
/// - 或配合 [pushProgressRoute] 压入透明路由（用 [scrim] = true 自带半透明遮罩）。
class ProgressOverlay extends StatelessWidget {
  /// 提示文案
  final String message;

  /// 进度（0.0 ~ 1.0）；为 null 时显示不确定进度的转圈
  final double? value;

  /// 是否自带半透明遮罩（用于非对话框的透明路由场景）
  final bool scrim;

  const ProgressOverlay({
    super.key,
    required this.message,
    this.value,
    this.scrim = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final v = value;

    final card = Card(
      elevation: 8,
      margin: const EdgeInsets.symmetric(horizontal: 48),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 46,
              height: 46,
              child: v == null
                  ? const CircularProgressIndicator()
                  : CircularProgressIndicator(value: v.clamp(0.0, 1.0)),
            ),
            if (v != null) ...[
              const SizedBox(height: 10),
              Text(
                '${(v.clamp(0.0, 1.0) * 100).toStringAsFixed(0)}%',
                style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ],
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );

    final content = Center(child: card);
    if (!scrim) return content;

    return ColoredBox(
      // 半透明遮罩：保留底层页面可见，只是压暗，不再是纯黑屏
      color: isDark ? Colors.black54 : Colors.black26,
      child: content,
    );
  }
}

/// 进度弹窗句柄：缓存弹窗**自己的** context，用来安全地关闭它（幂等）。
///
/// 为什么不能拿页面的 context 直接 pop：
/// - `showDialog` 默认 `useRootNavigator: true` ⇒ 弹窗挂在**根** Navigator；
/// - 而「分类页 / 最近页」这类页面是 `ShellNavigator.push` 进 **HomeScreen body
///   里的嵌套 Navigator** 的，页面 context 解析出来的是**嵌套栈**。
///   此时 `Navigator.of(context).pop()` 会把**页面自己**弹掉、弹窗原地不动；
///   之后的回调里 context 已经失效（`Navigator.canPop` 会抛异常，并被手势回调
///   静默吞掉）⇒ 表现为「点取消 / 后台毫无反应、返回键又被 PopScope 挡住，
///   只能重启应用」。
///
/// 用法：
/// ```dart
/// final handle = ProgressDialogHandle();
/// showDialog(
///   context: context,
///   builder: (dialogContext) {
///     handle.attach(dialogContext);
///     return MyProgressDialog(...);
///   },
/// );
/// ...
/// handle.close(); // 成功 / 失败 / 取消都能调；弹窗已被返回键关掉时是空操作
/// ```
class ProgressDialogHandle {
  BuildContext? _ctx;

  /// 在 `showDialog` 的 builder 里调用，记下弹窗自己的 context
  /// （重新弹窗时再调一次即可覆盖，句柄可复用）。
  void attach(BuildContext dialogContext) => _ctx = dialogContext;

  /// 弹窗是否还在屏幕上。
  bool get isOpen {
    final ctx = _ctx;
    return ctx != null && ctx.mounted;
  }

  /// 关闭弹窗（幂等）。弹窗已经不在了就什么都不做，**绝不会误 pop 掉页面**。
  void close() {
    final ctx = _ctx;
    _ctx = null;
    if (ctx == null || !ctx.mounted) return;
    final navigator = Navigator.of(ctx);
    if (navigator.canPop()) navigator.pop();
  }
}

/// 压入一个不遮挡底层页面的「处理中」遮罩路由（替代全黑的全屏路由）
///
/// 传入 [progress] 可在卡片上显示百分比进度（配合加解密的 onProgress 回调）。
/// 关闭时照常 `navigator.pop()` 即可。
void pushProgressRoute(
  NavigatorState navigator, {
  required String message,
  ValueListenable<double?>? progress,
}) {
  navigator.push(
    PageRouteBuilder(
      opaque: false,
      barrierDismissible: false,
      pageBuilder: (_, _, _) => progress == null
          ? ProgressOverlay(message: message, scrim: true)
          : ValueListenableBuilder<double?>(
              valueListenable: progress,
              builder: (_, v, _) => ProgressOverlay(message: message, value: v, scrim: true),
            ),
    ),
  );
}
