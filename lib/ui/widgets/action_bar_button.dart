import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';

/// 多选操作栏的通用按钮：图标 + 可选文字标签。
///
/// 抽出为独立组件，供 [SelectionActionBar]（浏览页 / 最近页）与
/// [MediaCategoryScreen]（图片 / 视频 / 音频 / 文档等分类页）共用，
/// 让「隐藏操作栏文字标签」(`FileManagerProvider.hideActionText`) 的渲染逻辑
/// 只在一处维护，外观与交互保持一致。
class ActionBarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;
  final bool hideLabel;

  const ActionBarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.hideLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayColor = color ?? theme.colorScheme.primary;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: displayColor, size: 24),
            if (!hideLabel) ...[
              const SizedBox(height: 4),
              AutoSizeText(
                label,
                minFontSize: 8,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: displayColor,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
