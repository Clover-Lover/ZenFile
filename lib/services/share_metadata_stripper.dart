import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import 'image_metadata_service.dart';

/// 「安全分享」的元数据剥离入口 —— 能力判定与剥离实现的**唯一来源**。
///
/// UI（三点菜单要不要给出「安全分享」）与执行（真的剥一遍）都用 [isSupported]
/// 这同一个判据，避免出现「菜单里有选项、点了却什么都没发生」这类多入口不一致。
///
/// 两类策略，安全性都排在第一位：
/// * **图片（JPEG/PNG）**：按分段结构整段删掉 EXIF/GPS/ICC 区块。JPEG/PNG 由
///   「带长度的段」串成，删段后文件依然合法（不依赖任何绝对偏移）。
/// * **文档（ZIP/PDF）**：**等长就地覆盖** —— 只把时间戳清零、把字符串内容换成
///   空格，所有长度字段与偏移量一个字节都不动，因此不存在「清完打不开」的风险。
///   代价是找不到可清理位置时必须老实放弃（返回 null），由调用方退化为普通分享。
class ShareMetadataStripper {
  const ShareMetadataStripper._();

  /// 一次读入内存做等长覆盖的体积上限。
  ///
  /// 超过此值宁可不给「安全分享」选项 —— 给一个会把手机撑爆（OOM）的选项，
  /// 比没有选项更糟。图片天然远小于此值；压缩包/PDF 超过这个体积时本身也不适合
  /// 走 IM 分享。
  static const int maxBytes = 96 * 1024 * 1024;

  /// 该路径能否安全剥离元数据（同时用于决定菜单是否展示「安全分享」）。
  static bool isSupported(String path) {
    final ext = _ext(path);
    const strippable = {'.jpg', '.jpeg', '.png', '.zip', '.pdf'};
    if (!strippable.contains(ext)) return false;
    try {
      final file = File(path);
      if (!file.existsSync()) return false;
      return file.lengthSync() <= maxBytes;
    } catch (_) {
      return false;
    }
  }

  /// 剥离元数据，返回新字节；null = 这个文件没法安全剥离（调用方退化为普通分享）。
  static Uint8List? strip(Uint8List src, String path) {
    switch (_ext(path)) {
      case '.jpg':
      case '.jpeg':
        return ImageMetadataService.stripMetadataBytes(src);
      case '.png':
        return ImageMetadataService.stripMetadataBytes(src, isPng: true);
      case '.zip':
        return _stripZip(src);
      case '.pdf':
        return _stripPdf(src);
    }
    return null;
  }

  static String _ext(String path) => p.extension(path).toLowerCase();

  // ─── ZIP：等长就地清理 ──────────────────────────────────────────────────
  //
  // ZIP 会泄露的东西都躺在「固定长度的头部字段」里，所以可以精确覆盖：
  //   1. 每个条目的修改时间/日期（本地文件头与中央目录各存一份）
  //   2. 归档注释与每个条目的注释（明文，不少工具会把打包路径写进去）
  //   3. 扩展字段里另存的真时间戳（UT 0x5455 / NTFS 0x000a）
  // 条目的**名字**同样是隐私（可能带用户名），但改它要牵动所有偏移量与
  // 中央目录，只能重打包 —— 代价与风险都太高，因此不做。

  static const int _sigLocal = 0x04034b50;
  static const int _sigCentral = 0x02014b50;
  static const int _sigEocd = 0x06054b50;

  static Uint8List? _stripZip(Uint8List src) {
    final n = src.length;
    if (n < 22) return null;
    final eocd = _findEocd(src);
    if (eocd < 0) return null;
    // Zip64（>4GB 或 >65535 个条目）的偏移量在 Zip64 EOCD 里，本实现不处理 ⇒
    // 老实放弃，交给普通分享。
    final cdSize = _u32(src, eocd + 12);
    final cdOffset = _u32(src, eocd + 16);
    if (cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) return null;
    if (cdOffset < 0 || cdOffset >= n) return null;

    final out = Uint8List.fromList(src);

    // 归档注释：直接填空格（长度不变 ⇒ EOCD 自身无需改动）
    final commentLen = _u32(src, eocd + 20) & 0xFFFF;
    if (commentLen > 0 && eocd + 22 + commentLen <= n) {
      _fill(out, eocd + 22, commentLen, _space);
    }

    var entries = 0;
    var off = cdOffset;
    while (off + 46 <= n && _u32(src, off) == _sigCentral) {
      _zeroDosTime(out, off + 12);
      final nameLen = _u16(src, off + 28);
      final extraLen = _u16(src, off + 30);
      final cmtLen = _u16(src, off + 32);
      final localOffset = _u32(src, off + 42);
      entries++;

      final extraAt = off + 46 + nameLen;
      if (extraAt + extraLen + cmtLen > n) break;
      _zeroZipExtraTimestamps(out, extraAt, extraLen);
      _fill(out, extraAt + extraLen, cmtLen, _space);

      // 同一个时间戳在本地文件头里还有一份
      if (localOffset + 30 <= n && _u32(src, localOffset) == _sigLocal) {
        _zeroDosTime(out, localOffset + 10);
        final lNameLen = _u16(src, localOffset + 26);
        final lExtraLen = _u16(src, localOffset + 28);
        _zeroZipExtraTimestamps(out, localOffset + 30 + lNameLen, lExtraLen);
      }

      off = extraAt + extraLen + cmtLen;
    }

    return entries == 0 ? null : out;
  }

  /// 从尾部往前找 EOCD（归档注释最长 64KB，所以最多回看 65557 字节）。
  static int _findEocd(Uint8List b) {
    final lowest = b.length - 65557 > 0 ? b.length - 65557 : 0;
    for (var i = b.length - 22; i >= lowest; i--) {
      if (_u32(b, i) == _sigEocd) return i;
    }
    return -1;
  }

  /// DOS 日期字段全 0 是非法值（会显示成 0 年），统一写 1980-01-01 00:00:00。
  static void _zeroDosTime(Uint8List b, int at) {
    if (at + 4 > b.length) return;
    b[at] = 0;
    b[at + 1] = 0;
    b[at + 2] = 0x21;
    b[at + 3] = 0x00;
  }

  /// 扩展字段本身不能动（长度变了会连累所有偏移量），但里面另存的**时间戳值**
  /// 可以就地清零：字段头与长度保持原样，只是时间变 0。
  static void _zeroZipExtraTimestamps(Uint8List b, int at, int len) {
    final end = at + len > b.length ? b.length : at + len;
    var i = at;
    while (i + 4 <= end) {
      final id = _u16(b, i);
      final size = _u16(b, i + 2);
      if (size == 0 || i + 4 + size > end) return;
      final body = i + 4;
      if (id == 0x5455) {
        // UT：flags(1B) + 修改/访问/创建时间（各 4B，按 flags 位决定是否存在）
        final flags = b[body];
        var q = body + 1;
        for (var k = 0; k < 3; k++) {
          if (flags & (1 << k) == 0) continue;
          if (q + 4 > body + size) break;
          _fill(b, q, 4, 0);
          q += 4;
        }
      } else if (id == 0x000A) {
        // NTFS：保留 4B + 若干 (tag 2B, 长度 2B, 值)；tag 1 = 三个 FILETIME
        var q = body + 4;
        while (q + 4 <= body + size) {
          final tag = _u16(b, q);
          final tlen = _u16(b, q + 2);
          if (q + 4 + tlen > body + size) break;
          if (tag == 1 && tlen >= 24) _fill(b, q + 4, 24, 0);
          q += 4 + tlen;
        }
      }
      i = body + size;
    }
  }

  // ─── PDF：等长就地清理 ──────────────────────────────────────────────────
  //
  // 不做 PDF 解析（要正确处理 xref 流、增量更新、对象流才敢重写，写错就是文件
  // 损坏），改为在原始字节里把**明文元数据**就地覆盖掉：字符串内容换空格、
  // 十六进制串换 '0'（即全零字节）。长度一字节不变 ⇒ xref 表与所有 offset
  // 依然全部正确。
  //
  // 局限（宁可放弃也不冒险）：加密 PDF（字符串是密文，找不到）、/Info 被压进
  // 对象流的 PDF（在压缩数据里，找不到）⇒ 返回 null，退化普通分享。

  static const List<String> _pdfInfoKeys = [
    '/Title',
    '/Author',
    '/Subject',
    '/Keywords',
    '/Creator',
    '/Producer',
    '/CreationDate',
    '/ModDate',
    '/Trapped',
    '/Company',
    '/SourceModified',
  ];

  static Uint8List? _stripPdf(Uint8List src) {
    if (!_matchesAscii(src, 0, '%PDF-')) return null;
    // 加密 PDF：正文全为密文，就地覆盖无意义（也不该宣称「已去元数据」）
    if (_indexOfBytes(src, _ascii('/Encrypt'), 0) >= 0) return null;

    final out = Uint8List.fromList(src);
    var changed = 0;
    for (final key in _pdfInfoKeys) {
      changed += _blankPdfTextStrings(out, _ascii(key));
    }
    changed += _blankXmpPackets(out);
    return changed == 0 ? null : out;
  }

  /// 把 `/Key (...)` / `/Key <...>` 的**内容**就地换成空格 / '0'。
  /// 覆盖整段内容（含转义序列）后括号天然配平，结果永远是合法的空字符串。
  static int _blankPdfTextStrings(Uint8List b, List<int> key) {
    var hits = 0;
    var from = 0;
    var i = _indexOfBytes(b, key, from);
    while (i >= 0) {
      from = i + key.length;
      // 必须是独立的 name token：前一个字节是分隔符或文件开头
      if (i > 0 && !_isPdfDelimiter(b[i - 1])) {
        i = _indexOfBytes(b, key, from);
        continue;
      }
      var q = i + key.length;
      while (q < b.length && _isPdfSpace(b[q])) {
        q++;
      }
      if (q < b.length && b[q] == _lparen) {
        final close = _pdfLiteralStringEnd(b, q);
        if (close > q) {
          _fill(b, q + 1, close - q - 1, _space);
          hits++;
          from = close;
        }
      } else if (q < b.length && b[q] == _lt) {
        final close = _indexOfByte(b, _gt, q + 1);
        if (close > q) {
          _fill(b, q + 1, close - q - 1, 0x30);
          hits++;
          from = close + 1;
        }
      }
      i = _indexOfBytes(b, key, from);
    }
    return hits;
  }

  /// 返回与 `(` 配对的 `)` 的下标；处理 `\` 转义与嵌套括号。
  static int _pdfLiteralStringEnd(Uint8List b, int open) {
    var depth = 1;
    var i = open + 1;
    while (i < b.length) {
      final c = b[i];
      if (c == 0x5C) {
        i += 2;
        continue;
      }
      if (c == _lparen) {
        depth++;
      } else if (c == _rparen) {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    return -1;
  }

  /// XMP 元数据包（`<?xpacket begin=…` 到 `<?xpacket end=…?>`）整段换成空格。
  /// XMP 规范本身允许在包尾用空白填充以便就地编辑，所以「整段变空白」对 PDF
  /// 结构无害，只是相机/作者/GPS/编辑历史这些属性不再存在。
  static int _blankXmpPackets(Uint8List b) {
    final begin = _ascii('<?xpacket begin=');
    final end = _ascii('<?xpacket end=');
    var hits = 0;
    var from = 0;
    var i = _indexOfBytes(b, begin, from);
    while (i >= 0) {
      final endAt = _indexOfBytes(b, end, i);
      if (endAt < 0) break;
      final gt = _indexOfByte(b, _gt, endAt);
      if (gt < 0) break;
      _fill(b, i, gt + 1 - i, _space);
      hits++;
      from = gt + 1;
      i = _indexOfBytes(b, begin, from);
    }
    return hits;
  }

  // ─── 字节工具 ───────────────────────────────────────────────────────────

  static const int _space = 0x20;
  static const int _lparen = 0x28;
  static const int _rparen = 0x29;
  static const int _lt = 0x3C;
  static const int _gt = 0x3E;

  static int _u16(Uint8List b, int at) {
    if (at + 2 > b.length) return 0;
    return b[at] | (b[at + 1] << 8);
  }

  static int _u32(Uint8List b, int at) {
    if (at + 4 > b.length) return 0;
    return b[at] |
        (b[at + 1] << 8) |
        (b[at + 2] << 16) |
        (b[at + 3] << 24);
  }

  static void _fill(Uint8List b, int at, int len, int value) {
    final end = at + len > b.length ? b.length : at + len;
    for (var i = at < 0 ? 0 : at; i < end; i++) {
      b[i] = value;
    }
  }

  static int _indexOfByte(Uint8List b, int value, int from) {
    for (var i = from < 0 ? 0 : from; i < b.length; i++) {
      if (b[i] == value) return i;
    }
    return -1;
  }

  static int _indexOfBytes(Uint8List b, List<int> needle, int from) {
    if (needle.isEmpty) return -1;
    final last = b.length - needle.length;
    for (var i = from < 0 ? 0 : from; i <= last; i++) {
      var matched = true;
      for (var j = 0; j < needle.length; j++) {
        if (b[i + j] != needle[j]) {
          matched = false;
          break;
        }
      }
      if (matched) return i;
    }
    return -1;
  }

  static bool _matchesAscii(Uint8List b, int at, String text) {
    if (at + text.length > b.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[at + i] != text.codeUnitAt(i)) return false;
    }
    return true;
  }

  static List<int> _ascii(String s) => s.codeUnits;

  /// PDF 空白字符：NUL / HT / LF / FF / CR / SP（**不含** VT=0x0B）。
  static bool _isPdfSpace(int c) =>
      c == 0x00 || c == 0x20 || (c >= 0x09 && c <= 0x0D && c != 0x0B);

  /// PDF 分隔符（name token 的合法边界）。
  static bool _isPdfDelimiter(int c) {
    const delimiters = [
      0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25,
    ];
    return delimiters.contains(c) || _isPdfSpace(c);
  }
}
