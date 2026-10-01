import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'archive_service.dart';
import 'share_metadata_stripper.dart';

class FolderShareService {
  /// 分享路径列表：
  /// - 全部选中项都支持安全分享（JPEG/PNG 图片、ZIP/PDF 文档）时，
  ///   先弹出「普通分享 / 安全分享」选择；
  /// - 其余情况（含其他格式、文件夹、混合选择）直接普通分享，不弹窗。
  static Future<void> sharePaths(BuildContext context, List<String> paths) async {
    if (paths.isEmpty) return;

    if (_allStrippable(paths)) {
      final l10n = L10n.of(context);
      final mode = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: Theme.of(context).colorScheme.surface,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.share_outlined),
                title: Text(
                  l10n.share_normal_share,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(l10n.share_normal_share_hint),
                onTap: () => Navigator.pop(ctx, 'normal'),
              ),
              const Divider(height: 1, indent: 16, endIndent: 16),
              ListTile(
                leading: const Icon(Icons.shield_outlined),
                title: Text(
                  l10n.share_safe_share,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(l10n.share_safe_share_hint),
                onTap: () => Navigator.pop(ctx, 'safe'),
              ),
            ],
          ),
        ),
      );
      if (mode == null) return; // 用户取消分享
      if (!context.mounted) return;
      await _sharePathsInternal(context, paths, stripMetadata: mode == 'safe');
      return;
    }

    await _sharePathsInternal(context, paths, stripMetadata: false);
  }

  /// 是否**全部**条目都能安全分享。
  ///
  /// 判据只有 [ShareMetadataStripper.isSupported] 一处 —— 「菜单给不给这个选项」
  /// 与「执行时能不能真的剥掉」永远是同一个答案，不会出现选项点了没反应。
  static bool _allStrippable(List<String> paths) {
    for (final path in paths) {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
        return false;
      }
      if (!ShareMetadataStripper.isSupported(path)) return false;
    }
    return true;
  }

  static Future<void> _sharePathsInternal(
    BuildContext context,
    List<String> paths, {
    required bool stripMetadata,
  }) async {
    // Show a loading dialog since compression can take a while
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Center(
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                  L10n.of(ctx).share_preparing_title,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  L10n.of(ctx).share_preparing_body,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final filesToShare = <XFile>[];
    final tempZipFiles = <File>[];
    final tempCleanFiles = <File>[];
    final cleanNames = <String>{};
    final failedToStrip = <String>[];

    try {
      final tempDir = Directory.systemTemp;

      for (final path in paths) {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.file) {
          if (stripMetadata) {
            // 安全分享：把「去元数据副本」写到临时文件，绝不改动原文件。
            // 剥不掉时（加密 PDF、Zip64 压缩包等）**退回原文件**并记名，
            // 事后明确告知 —— 静默当成「已清理」等于骗用户。
            final cleanFile = await _writeCleanCopy(path, tempDir, cleanNames);
            if (cleanFile != null) {
              tempCleanFiles.add(cleanFile);
              filesToShare.add(XFile(cleanFile.path));
              continue;
            }
            failedToStrip.add(p.basename(path));
          }
          filesToShare.add(XFile(path));
        } else if (type == FileSystemEntityType.directory) {
          final folderName = p.basename(path);
          final tempZipName = '${folderName}_${DateTime.now().millisecondsSinceEpoch}';

          // Compress the folder using high-performance ArchiveService
          await ArchiveService.createArchive(
            sourcePaths: [path],
            destinationDir: tempDir.path,
            archiveName: tempZipName,
            format: 'zip',
            compressionLevel: 3, // Fast compression for quick sharing
            deleteSource: false,
            separateArchives: false,
          );

          final zipFile = File(p.join(tempDir.path, '$tempZipName.zip'));
          if (zipFile.existsSync()) {
            tempZipFiles.add(zipFile);
            filesToShare.add(XFile(zipFile.path));
          }
        }
      }

      // Close the loading dialog
      if (context.mounted) {
        Navigator.pop(context);
      }

      if (filesToShare.isNotEmpty) {
        await Share.shareXFiles(filesToShare);
        if (failedToStrip.isNotEmpty && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                L10n.of(context).share_safe_unsupported(failedToStrip.length),
              ),
            ),
          );
        }
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(L10n.of(context).share_nothing_found)),
          );
        }
      }
    } catch (e) {
      // Close the loading dialog if it's still showing
      if (context.mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(L10n.of(context).share_prepare_error(e.toString()))),
        );
      }
    } finally {
      // Delete temp files after a delay so the share sheet can read them.
      // 2 分钟而不是 15 秒：接收集（IM/网盘）拿到的是 content URI，大压缩包可能
      // 要读好一会儿，删早了对方就拿到半截文件。
      Future.delayed(const Duration(minutes: 2), () {
        for (final file in [...tempZipFiles, ...tempCleanFiles]) {
          try {
            if (file.existsSync()) {
              file.deleteSync();
            }
          } catch (_) {}
        }
      });
    }
  }

  /// 生成「去元数据副本」写入临时文件（无损、不修改原文件）。
  /// 临时文件名：`原文件名_clean.扩展名`；无法安全剥离时返回 null。
  static Future<File?> _writeCleanCopy(
    String path,
    Directory tempDir,
    Set<String> usedNames,
  ) async {
    try {
      final bytes = await File(path).readAsBytes();
      final cleaned = ShareMetadataStripper.strip(bytes, path);
      if (cleaned == null) return null;
      final base = p.basenameWithoutExtension(path);
      final ext = p.extension(path).toLowerCase();
      var name = '${base}_clean$ext';
      // 不同目录下的同名文件会撞同一个临时路径，撞上时补一串稳定短标签
      if (usedNames.contains(name)) {
        name = '${base}_clean_${_stableTag(path)}$ext';
      }
      usedNames.add(name);
      final cleanFile = File(p.join(tempDir.path, name));
      await cleanFile.writeAsBytes(cleaned, flush: true);
      return cleanFile;
    } catch (_) {
      return null;
    }
  }

  /// 由完整路径算出的稳定短标签（同名文件去重用）。
  static String _stableTag(String path) {
    var hash = 0;
    for (final unit in path.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0').substring(0, 6);
  }
}
