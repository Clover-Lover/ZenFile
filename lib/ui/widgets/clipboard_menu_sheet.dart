import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/icon_fonts/broken_icons.dart';
import '../../core/utils.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../providers/file_manager_provider.dart';

/// 剪贴板面板（**全项目唯一实现**，单窗口 + 双窗口共用）。
///
/// ## 多任务剪贴板（issue #36）
/// 每次复制/剪切 = 一个任务（[ClipboardTask]），累计存放（上限 20，超出自动
/// 移除最旧）。面板按任务分组展示，任务之间用**分割线**区分。
///
/// ## 每任务独立操作（不共用一套）
/// - 每个任务有自己的**清除**按钮（区块头部 ✕）与自己的**勾选框**
///   （「粘贴后保留」），互不影响。
/// - **复制任务**：勾选框默认不勾选 ⇒ 粘贴后**自动清除**该任务；
///   勾选后粘贴则保留（可多次粘贴到不同位置）。
/// - **剪切任务**：粘贴后**始终自动清除**（源文件已被移走，留着是死路径），
///   区块内显示提示文案，无勾选框。
/// - 底部「清除」按钮清空全部任务。
///
/// ## 显示内容
/// 每个任务的列表项按**真实文件类型**给图标与配色（复用
/// [FileUtils.getIconForFile] / [FileUtils.getColorForFile]，与文件列表页保持
/// 一致；目录用用户设置里的文件夹图标样式）。
Future<void> showClipboardMenuSheet(
  BuildContext context, {
  required FileManagerProvider provider,
  required Future<void> Function(int taskIndex, {required bool clearAfterPaste}) onPaste,
}) {
  final l10n = L10n.of(context);
  final theme = Theme.of(context);
  // 勾选态直接挂在 ClipboardTask.keepAfterPaste 上（随任务对象保留，
  // 关闭再打开弹窗不丢、多任务各自独立），不再用弹窗局部 map。
  const maxPanelHeight = 340.0;

  return showDialog<void>(
    context: context,
    barrierColor: Colors.black26,
    builder: (_) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final tasks = provider.clipboardTasks;
        return Stack(
          children: [
            GestureDetector(
              onTap: () => Navigator.pop(sheetContext),
              child: Container(color: Colors.transparent),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 任务列表（多任务：任务间分割线 + 每任务独立粘贴/勾选/清除）
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxHeight: maxPanelHeight,
                        ),
                        child: ListView.builder(
                          shrinkWrap: true,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          itemCount: tasks.length,
                          itemBuilder: (_, i) {
                            final task = tasks[i];
                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _ClipboardTaskBlock(
                                  task: task,
                                  folderIconOption:
                                      provider.folderIconOption,
                                  keepClipboard: task.keepAfterPaste,
                                  onToggleKeep: (v) {
                                    task.keepAfterPaste = v;
                                    setSheetState(() {});
                                  },
                                  onPasteTask: () async {
                                    Navigator.pop(sheetContext);
                                    await onPaste(
                                      i,
                                      clearAfterPaste: task.isCut
                                          ? true
                                          : !task.keepAfterPaste,
                                    );
                                  },
                                  onRemoveTask: () {
                                    provider.removeClipboardTask(i);
                                    setSheetState(() {});
                                  },
                                ),
                                // 任务间的分割线（最后一项不显示）
                                if (i < tasks.length - 1)
                                  Divider(
                                    height: 12,
                                    thickness: 0.5,
                                    color: theme.colorScheme.outlineVariant
                                        .withValues(alpha: 0.5),
                                  ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // 底部操作：清除全部（窄）+ 粘贴全部（右侧，按每任务勾选状态操作）
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
                      child: Row(
                        children: [
                          // 清除全部（窄）
                          Expanded(
                            flex: 1,
                            child: OutlinedButton(
                              onPressed: () {
                                Navigator.pop(sheetContext);
                                provider.clearClipboard();
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: theme.colorScheme.error,
                                side: BorderSide(
                                  color: theme.colorScheme.error.withValues(alpha: 
                                    0.25,
                                  ),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: _ButtonLabel(
                                text: l10n.ui_clear,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 粘贴全部：依次粘贴所有任务；每个任务按自己的勾选状态
                          // （勾选=粘贴后保留，不勾选=粘贴后清除；剪切任务始终清除）
                          Expanded(
                            flex: 3,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                Navigator.pop(sheetContext);
                                // 从后往前粘贴：任务被移除时索引保持有效
                                for (int i = tasks.length - 1; i >= 0; i--) {
                                  final task = tasks[i];
                                  await onPaste(
                                    i,
                                    clearAfterPaste: task.isCut
                                        ? true
                                        : !task.keepAfterPaste,
                                  );
                                }
                              },
                              icon: const Icon(
                                Icons.content_paste,
                                size: 16,
                              ),
                              label: _ButtonLabel(
                                text: l10n.ui_paste,
                                fontSize: 14,
                                bold: true,
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: theme.colorScheme.primary,
                                foregroundColor: theme.colorScheme.onPrimary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                  horizontal: 4,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    ),
  );
}

/// 剪贴板里的一条内容（只取展示所需字段）。
class _ClipboardEntry {
  final String name;
  final bool isDirectory;

  const _ClipboardEntry({required this.name, required this.isDirectory});
}

/// 把一个剪贴板任务拍平成展示条目。
///
/// 在弹面板**之前**调用（只算一次）：本地条目判断是否为目录需要一次 `stat`，
/// 放在 build 里会随重建反复触发同步 IO。
List<_ClipboardEntry> _collectTaskItems(ClipboardTask task) {
  if (task.isRemote) {
    return (task.remoteItems ?? const [])
        .map(
          (e) => _ClipboardEntry(name: e.name, isDirectory: e.isDirectory),
        )
        .toList();
  }
  return task.paths.map((path) {
    var isDir = false;
    try {
      isDir = FileSystemEntity.isDirectorySync(path);
    } catch (_) {
      // 受限目录（Android/data、/data 等）元数据被 FUSE 拦截时按文件图标显示，
      // 不影响粘贴本身。
    }
    return _ClipboardEntry(name: p.basename(path), isDirectory: isDir);
  }).toList();
}

/// 剪贴板里的一个任务区块：头部（图标 + 剪切/复制 N 项 + 时间 + 清除）、
/// 文件列表、底部操作行（该任务的勾选框 + 独立「粘贴」按钮）。
class _ClipboardTaskBlock extends StatelessWidget {
  final ClipboardTask task;
  final String folderIconOption;
  final bool keepClipboard;
  final ValueChanged<bool> onToggleKeep;
  final VoidCallback onPasteTask;
  final VoidCallback onRemoveTask;

  const _ClipboardTaskBlock({
    required this.task,
    required this.folderIconOption,
    required this.keepClipboard,
    required this.onToggleKeep,
    required this.onPasteTask,
    required this.onRemoveTask,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final items = _collectTaskItems(task);
    final prefix = task.isCut ? l10n.ui_cut : l10n.ui_copy;
    final t = task.createdAt;
    final time =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 头部：图标 + 剪切/复制 N 项 + 时间 + 清除（该任务）
        Row(
          children: [
            Icon(
              task.isCut ? Broken.scissor : Broken.clipboard,
              size: 16,
              color: task.isCut
                  ? Colors.orange
                  : theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.ui_cut_copy_items(prefix, items.length),
                style: theme.textTheme.labelSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: task.isCut
                      ? Colors.orange
                      : theme.colorScheme.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              time,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
              ),
            ),
            const SizedBox(width: 2),
            IconButton(
              onPressed: onRemoveTask,
              icon: Icon(
                Broken.close_circle,
                size: 16,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
              ),
              visualDensity: VisualDensity.compact,
              tooltip: l10n.ui_clear,
            ),
          ],
        ),
        // 文件列表（任务内条目多时可内部滚动）
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 110),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: items.length,
            itemBuilder: (_, i) => _ClipboardItemRow(
              item: items[i],
              folderIconOption: folderIconOption,
            ),
          ),
        ),
        // 底部操作行：该任务的勾选框（复制）或提示（剪切）+ 独立粘贴按钮
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              if (task.isCut)
                Expanded(
                  child: Text(
                    l10n.ui_cut_paste_hint,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                )
              else
                Expanded(
                  child: InkWell(
                    onTap: () => onToggleKeep(!keepClipboard),
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: keepClipboard,
                          onChanged: (v) =>
                              onToggleKeep(v ?? false),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                        const SizedBox(width: 2),
                        Flexible(
                          child: Text(
                            l10n.paste_keep_clipboard,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurface.withValues(alpha: 
                                0.8,
                              ),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(width: 8),
              // 该任务的独立粘贴按钮
              ElevatedButton.icon(
                onPressed: onPasteTask,
                icon: const Icon(Icons.content_paste, size: 14),
                label: _ButtonLabel(
                  text: l10n.ui_paste,
                  fontSize: 13,
                  bold: true,
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.colorScheme.primary,
                  foregroundColor: theme.colorScheme.onPrimary,
                  padding: const EdgeInsets.symmetric(
                    vertical: 6,
                    horizontal: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 剪贴板列表的一行：真实文件类型图标 + 文件名。
class _ClipboardItemRow extends StatelessWidget {
  final _ClipboardEntry item;
  final String folderIconOption;

  const _ClipboardItemRow({
    required this.item,
    required this.folderIconOption,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icon = item.isDirectory
        ? FileUtils.getFolderIcon(folderIconOption)
        : FileUtils.getIconForFile(item.name);
    final color = item.isDirectory
        ? theme.colorScheme.primary
        : FileUtils.getColorForFile(item.name, context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.name,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 按钮文案：`FittedBox` 兜住「非中文语言 + 系统大字号」下的横排溢出
/// （例如德语 "Einfügen und löschen" 比中文长得多），必要时等比缩小而不截断。
class _ButtonLabel extends StatelessWidget {
  final String text;
  final double fontSize;
  final bool bold;

  const _ButtonLabel({
    required this.text,
    required this.fontSize,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: bold ? FontWeight.bold : FontWeight.w500,
        ),
      ),
    );
  }
}
