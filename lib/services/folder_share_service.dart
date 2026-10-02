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
    // 安全分享的清理副本：每个文件独占一个子目录（见 _writeCleanCopy）。
    // 这里只记「根目录」以便一次删干净，**不给文件名加后缀去重** —— 磁盘文件名
    // 就是接收方看到的名字。
    Directory? cleanRoot;
    var cleanSeq = 0;
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
            cleanRoot ??= await Directory(
              p.join(tempDir.path, 'zenfile_safe_share'),
            ).create(recursive: true);
            final cleanFile = await _writeCleanCopy(path, cleanRoot, cleanSeq);
            if (cleanFile != null) {
              cleanSeq++;
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
        for (final file in tempZipFiles) {
          try {
            if (file.existsSync()) {
              file.deleteSync();
            }
          } catch (_) {}
        }
        // 清理副本都躺在 zenfile_safe_share/<seq>/ 下，整根递归删掉最干净
        // （逐文件删会留下一堆空目录）。
        try {
          final root = cleanRoot;
          if (root != null && root.existsSync()) {
            root.deleteSync(recursive: true);
          }
        } catch (_) {}
      });
    }
  }

  /// 生成「去元数据副本」写入临时文件（无损、不修改原文件）。
  ///
  /// 🔴 文件名**必须保持原名**：Android 端 share_plus 只会把文件复制成
  /// `cacheDir/share_plus/<磁盘文件名>` 再分享 —— 它的 `Share.kt` **完全不读**
  /// Dart 侧传来的 `fileNameOverrides`（12.0.2 实测：Dart 侧塞进 method channel，
  /// Kotlin 侧根本没有这个字段）⇒ **接收方看到的名字就是磁盘文件名**。
  /// 所以给副本加 `_clean` 后缀等于替用户把文件改了名，对方会以为
  /// 「这文件被改过 / 画质被压过」—— 而安全分享的语义是「内容完全等价，只少了元数据」。
  ///
  /// 防撞车改用**子目录**（`<root>/<seq>/原名`）而不是改文件名：同一批里多个同名
  /// 文件各自独占一个序号目录，磁盘名得以保持原名（这与普通分享的行为一致：
  /// 普通分享遇到两个同名文件同样是两个 `photo.jpg`）。
  ///
  /// 无法安全剥离时返回 null（调用方退回原文件并告知用户）。
  static Future<File?> _writeCleanCopy(
    String path,
    Directory root,
    int seq,
  ) async {
    try {
      final bytes = await File(path).readAsBytes();
      final cleaned = ShareMetadataStripper.strip(bytes, path);
      if (cleaned == null) return null;
      final dir = await Directory(
        p.join(root.path, '$seq'),
      ).create(recursive: true);
      final cleanFile = File(p.join(dir.path, p.basename(path)));
      await cleanFile.writeAsBytes(cleaned, flush: true);
      return cleanFile;
    } catch (_) {
      return null;
    }
  }
}
