import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';
import 'archive_service.dart';
import 'image_metadata_service.dart';

class FolderShareService {
  /// 分享路径列表：
  /// - 全部选中项均为 JPEG/PNG 图片时，先弹出「普通分享 / 安全分享」选择；
  /// - 其余情况（含其他格式、文件夹、混合选择）直接普通分享，不弹窗。
  static Future<void> sharePaths(BuildContext context, List<String> paths) async {
    if (paths.isEmpty) return;

    if (_allShareableImages(paths)) {
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

  /// 是否全部为可去元数据的图片（JPEG/PNG）：
  /// 只有 JPEG/PNG 能被 ImageMetadataService.stripMetadataBytes 无损剥离元数据，
  /// 其他格式（GIF/WebP/HEIC 等）无法保证去除，因此不弹安全分享选项。
  static bool _allShareableImages(List<String> paths) {
    for (final path in paths) {
      if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
        return false;
      }
      final lower = path.toLowerCase();
      if (!lower.endsWith('.jpg') &&
          !lower.endsWith('.jpeg') &&
          !lower.endsWith('.png')) {
        return false;
      }
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
      builder: (ctx) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text(
                  'Preparing folders for sharing...',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                SizedBox(height: 8),
                Text(
                  'Compressing contents, please wait',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
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

    try {
      final tempDir = Directory.systemTemp;

      for (final path in paths) {
        final type = FileSystemEntity.typeSync(path);
        if (type == FileSystemEntityType.file) {
          if (stripMetadata) {
            // 安全分享：去除元数据后保存到临时文件（不修改原图）
            final cleanFile = await _writeCleanImage(path, tempDir);
            tempCleanFiles.add(cleanFile);
            filesToShare.add(XFile(cleanFile.path));
          } else {
            filesToShare.add(XFile(path));
          }
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
      // Delete temporary zip files after a delay to let the share sheet access them
      Future.delayed(const Duration(seconds: 15), () {
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

  /// 读取图片字节，剥离 EXIF/GPS/ICC 等元数据后写入临时文件（无损、不修改原图）。
  /// 临时文件名：`原文件名_clean.扩展名`
  static Future<File> _writeCleanImage(String path, Directory tempDir) async {
    final bytes = await File(path).readAsBytes();
    final isPng = p.extension(path).toLowerCase() == '.png';
    final cleaned = ImageMetadataService.stripMetadataBytes(bytes, isPng: isPng);
    final base = p.basenameWithoutExtension(path);
    final ext = p.extension(path).toLowerCase();
    final cleanFile = File(p.join(tempDir.path, '${base}_clean$ext'));
    await cleanFile.writeAsBytes(cleaned, flush: true);
    return cleanFile;
  }
}
