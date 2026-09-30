import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// 文件哈希计算结果（十六进制字符串）。
class FileHashResult {
  final String md5;
  final String sha256;

  const FileHashResult(this.md5, this.sha256);
}

/// 文件 MD5 / SHA-256 计算服务。
///
/// 采用流式分块读取，避免大文件把整文件读进内存；单次读取同时喂给
/// MD5 与 SHA-256 两条 digest 管线，磁盘只扫一遍。
class FileHashService {
  FileHashService._();

  /// 计算本地文件 [filePath] 的 MD5 与 SHA-256。
  /// 文件不存在时抛出 [FileSystemException]。
  static Future<FileHashResult> compute(String filePath) async {
    final file = File(filePath);
    if (!file.existsSync()) {
      throw FileSystemException('File not found', filePath);
    }

    late crypto.Digest md5Digest;
    late crypto.Digest sha256Digest;

    final md5Sink = crypto.md5.startChunkedConversion(
      ChunkedConversionSink<crypto.Digest>.withCallback(
        (digests) => md5Digest = digests.single,
      ),
    );
    final sha256Sink = crypto.sha256.startChunkedConversion(
      ChunkedConversionSink<crypto.Digest>.withCallback(
        (digests) => sha256Digest = digests.single,
      ),
    );

    await for (final chunk in file.openRead()) {
      md5Sink.add(chunk);
      sha256Sink.add(chunk);
    }
    md5Sink.close();
    sha256Sink.close();

    return FileHashResult(md5Digest.toString(), sha256Digest.toString());
  }
}
