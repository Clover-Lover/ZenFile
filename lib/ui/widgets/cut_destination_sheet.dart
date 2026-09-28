import 'package:flutter/material.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';

/// 双窗口模式下「剪切」的出口选择：
/// - 单窗口（或无法定位另一窗口）：直接执行默认剪切（剪切到剪贴板），行为不变；
/// - 双窗口：弹出底部选项 —— 剪切到剪贴板 / 剪切到另一窗口（立即移动到另一窗口当前目录）。
Future<void> handleCutWithDestination(
  BuildContext context,
  FileManagerProvider provider, {
  required List<String> paths,
  required Future<void> Function() defaultCut,
}) async {
  if (paths.isEmpty) return;

  // 单窗口或无法定位另一窗口：保持原行为
  if (!provider.enableSplitScreen || provider.tabs.length < 2) {
    await defaultCut();
    return;
  }
  final targetTab = provider.otherPaneTabIndexForPath(paths.first);
  if (targetTab < 0) {
    await defaultCut();
    return;
  }

  final l10n = L10n.of(context);
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
              Broken.clipboard,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            title: Text(l10n.cut_to_clipboard),
            onTap: () => Navigator.pop(ctx, 'clipboard'),
          ),
          ListTile(
            leading: Icon(
              Icons.drive_file_move_rounded,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            title: Text(l10n.cut_to_other_window),
            onTap: () => Navigator.pop(ctx, 'other_window'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  // 先走现有剪切（本地/远程剪贴板统一由 cutFile/cutSelected 处理）
  await defaultCut();
  // 选项二：立即粘贴（移动）到另一窗口的当前目录
  if (choice == 'other_window') {
    if (!context.mounted) return;
    await provider.pasteFileToTab(context, targetTab, clearAfterPaste: true);
  }
}
