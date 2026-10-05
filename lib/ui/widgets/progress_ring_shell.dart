import 'package:flutter/material.dart';

/// 统一的双层圆形进度环外壳。
///
/// 复制/剪切、压缩/解压、加密/解密、云备份同步等**所有**进度弹窗都复用此组件，
/// 保证视觉完全一致：300×300 圆底 + 外圈（主题色 8px，整体进度）+ 内圈
/// （绿色 5px，当前文件进度）+ 内容区水平内边距 34。
///
/// 各弹窗只需把内部文案/按钮组织成 [children] 传进来即可，不再各自复制一份
/// 圆环代码。
///
/// - [overall]          外圈整体进度（0.0 ~ 1.0）。
/// - [inner]            内圈当前文件进度（0.0 ~ 1.0）；传 null 不渲染内圈。
/// - [indeterminate]    外圈显示「不确定进度」转圈；为 true 时忽略 [overall]。
/// - [animateOverall]   外圈是否做 300ms 缓动（压缩/解压沿用原动画）。
/// - [children]         内部内容列（外层 Column 已垂直居中，间距自理）。
class ProgressRingShell extends StatelessWidget {
  final double overall;
  final double? inner;
  final bool indeterminate;
  final bool animateOverall;
  final List<Widget> children;

  const ProgressRingShell({
    super.key,
    this.overall = 0.0,
    this.inner,
    this.indeterminate = false,
    this.animateOverall = false,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final circleBgColor = isDark
        ? const Color(0xFF1E1E2E)
        : theme.colorScheme.surface;
    final innerGreen = isDark
        ? const Color(0xFF81C784)
        : const Color(0xFF43A047);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Container(
        width: 300,
        height: 300,
        decoration: BoxDecoration(
          color: circleBgColor,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 30,
              spreadRadius: 2,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 环形进度条（外圈=整体进度：淡底环 + 主题色进度环）
            // padding=strokeWidth/2（4px）：CircularProgressIndicator 的
            // stroke 以约束框圆为路径向两侧各扩半线宽，4px 时环外缘恰好
            // 与圆形背景边缘对齐（无白边、不超出）。
            Padding(
              padding: const EdgeInsets.all(4),
              child: CircularProgressIndicator(
                value: 1.0,
                strokeWidth: 8,
                backgroundColor: Colors.transparent,
                valueColor: AlwaysStoppedAnimation<Color>(
                  theme.colorScheme.primary.withValues(alpha: 0.08),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(4),
              child: indeterminate
                  ? CircularProgressIndicator(
                      strokeWidth: 8,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.primary,
                      ),
                      strokeCap: StrokeCap.round,
                    )
                  : (animateOverall
                        ? TweenAnimationBuilder<double>(
                            tween: Tween<double>(
                              begin: 0,
                              end: overall.clamp(0.0, 1.0),
                            ),
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                            builder: (context, value, child) {
                              return CircularProgressIndicator(
                                value: value,
                                strokeWidth: 8,
                                backgroundColor: Colors.transparent,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  theme.colorScheme.primary,
                                ),
                                strokeCap: StrokeCap.round,
                              );
                            },
                          )
                        : CircularProgressIndicator(
                            value: overall.clamp(0.0, 1.0),
                            strokeWidth: 8,
                            backgroundColor: Colors.transparent,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              theme.colorScheme.primary,
                            ),
                            strokeCap: StrokeCap.round,
                          )),
            ),

            // 环形进度条（内圈=当前文件进度，绿色系区分整体）
            if (inner != null) ...[
              Padding(
                padding: const EdgeInsets.all(12),
                child: CircularProgressIndicator(
                  value: 1.0,
                  strokeWidth: 5,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(
                    innerGreen.withValues(alpha: 0.10),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: CircularProgressIndicator(
                  value: inner!.clamp(0.0, 1.0),
                  strokeWidth: 5,
                  backgroundColor: Colors.transparent,
                  valueColor: AlwaysStoppedAnimation<Color>(innerGreen),
                  strokeCap: StrokeCap.round,
                ),
              ),
            ],

            // 内部内容区域
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 34),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: children,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
