import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/share_metadata_stripper.dart';

/// 回归测试：「安全分享」必须**真的**把元数据去掉，且**绝不能**改坏文件。
///
/// 为什么这么较真：安全分享是「用户以为隐私已清理、然后发了出去」的承诺。
/// 假成功（说清干净了其实没清）比不做更糟；而清坏了文件（打不开）同样是事故。
/// 因此这里钉住三类断言：
///  1. 该清的都清了（图片走已有实现；ZIP 的时间戳/注释/扩展字段；PDF 的 /Info + XMP）；
///  2. 文件结构一字节不动 —— 长度不变、括号配平不变、条目内容不变；
///  3. 无法保证清理时不冒充成功（加密 PDF / Zip64 返回 null，由调用方降级普通分享）。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zf_share_strip_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ─── 工具 ────────────────────────────────────────────────────────────────

  int u16(Uint8List b, int at) => b[at] | (b[at + 1] << 8);

  /// 在字节流里找一个子串（找不到返回 -1）。
  int find(Uint8List hay, List<int> needle) {
    for (var i = 0; i + needle.length <= hay.length; i++) {
      var ok = true;
      for (var j = 0; j < needle.length; j++) {
        if (hay[i + j] != needle[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return i;
    }
    return -1;
  }

  /// 手工拼一个最小 ZIP（单条目、stored、无数据描述符）。
  /// 用 archive 包生成不了「扩展字段里带真时间戳」这种归档，只能手工拼。
  Uint8List buildZip({
    String name = 'a.txt',
    String data = 'hello world',
    int modTime = 0x8888,
    int modDate = 0x5C41,
    List<int> extra = const [],
    String entryComment = 'entry comment',
    String archiveComment = 'archive comment',
  }) {
    final nameBytes = utf8.encode(name);
    final dataBytes = utf8.encode(data);
    final cmtBytes = utf8.encode(entryComment);
    final acBytes = utf8.encode(archiveComment);
    final out = BytesBuilder();

    void w16(int v) {
      out.addByte(v & 0xFF);
      out.addByte((v >> 8) & 0xFF);
    }

    void w32(int v) {
      out.addByte(v & 0xFF);
      out.addByte((v >> 8) & 0xFF);
      out.addByte((v >> 16) & 0xFF);
      out.addByte((v >> 24) & 0xFF);
    }

    // 本地文件头 + 数据
    w32(0x04034B50);
    w16(20);
    w16(0);
    w16(0);
    w16(modTime);
    w16(modDate);
    w32(0);
    w32(dataBytes.length);
    w32(dataBytes.length);
    w16(nameBytes.length);
    w16(extra.length);
    out.add(nameBytes);
    out.add(extra);
    out.add(dataBytes);

    // 中央目录
    final cdStart = out.length;
    w32(0x02014B50);
    w16(20);
    w16(20);
    w16(0);
    w16(0);
    w16(modTime);
    w16(modDate);
    w32(0);
    w32(dataBytes.length);
    w32(dataBytes.length);
    w16(nameBytes.length);
    w16(extra.length);
    w16(cmtBytes.length);
    w16(0);
    w16(0);
    w32(0);
    w32(0);
    out.add(nameBytes);
    out.add(extra);
    out.add(cmtBytes);
    final cdSize = out.length - cdStart;

    // EOCD
    w32(0x06054B50);
    w16(0);
    w16(0);
    w16(1);
    w16(1);
    w32(cdSize);
    w32(cdStart);
    w16(acBytes.length);
    out.add(acBytes);

    return out.toBytes();
  }

  // ─── 能力判定 ────────────────────────────────────────────────────────────

  test('能力判定：只对能保证剥离的格式给「安全分享」选项', () {
    final jpg = File(p.join(tmp.path, 'a.jpg'))..writeAsBytesSync([0xFF, 0xD8]);
    final zip = File(p.join(tmp.path, 'a.zip'))..writeAsBytesSync([1, 2, 3]);
    final pdf = File(p.join(tmp.path, 'a.pdf'))..writeAsBytesSync([1, 2, 3]);
    final txt = File(p.join(tmp.path, 'a.txt'))..writeAsBytesSync([1, 2, 3]);
    final gif = File(p.join(tmp.path, 'a.gif'))..writeAsBytesSync([1, 2, 3]);

    expect(ShareMetadataStripper.isSupported(jpg.path), isTrue);
    expect(ShareMetadataStripper.isSupported(zip.path), isTrue);
    expect(ShareMetadataStripper.isSupported(pdf.path), isTrue);
    expect(ShareMetadataStripper.isSupported(txt.path), isFalse,
        reason: '纯文本没有可剥的元数据，给了选项等于骗人');
    expect(ShareMetadataStripper.isSupported(gif.path), isFalse,
        reason: 'GIF/WebP 等无法保证去除，与图片查看器里的判据保持一致');
    expect(ShareMetadataStripper.isSupported(p.join(tmp.path, 'nope.zip')),
        isFalse,
        reason: '文件不存在时不能给选项');
  });

  test('体积上限：超过上限的文件不给选项（宁可不给，也不给一个会 OOM 的选项）', () {
    final big = File(p.join(tmp.path, 'big.zip'));
    // truncate 直接把长度撑到上限之上，不真的写 96MB 数据
    final raf = big.openSync(mode: FileMode.write);
    raf.truncateSync(ShareMetadataStripper.maxBytes + 1);
    raf.closeSync();
    expect(ShareMetadataStripper.isSupported(big.path), isFalse);
    expect(ShareMetadataStripper.strip(
            Uint8List.fromList([1, 2, 3]), big.path), isNull);
  });

  // ─── ZIP ────────────────────────────────────────────────────────────────

  test('ZIP：扩展字段（UT / NTFS）里的真时间戳也清零，字段长度不变', () {
    final ut = <int>[
      0x55, 0x54, 0x05, 0x00, // id=0x5455(UT) size=5
      0x01, // flags：只有 mtime
      0x11, 0x22, 0x33, 0x44, // mtime = 0x44332211
    ];
    final ntfs = <int>[
      0x0A, 0x00, 0x20, 0x00, // id=0x000a(NTFS) size=32
      0, 0, 0, 0, // 保留位
      0x01, 0x00, 0x18, 0x00, // tag=1, 24 字节 FILETIME
      ...List<int>.filled(24, 0xAB),
    ];
    final extra = [...ut, ...ntfs];
    final src = buildZip(extra: extra);

    final out = ShareMetadataStripper.strip(src, 'x.zip')!;

    expect(out.length, src.length, reason: '等长覆盖：一个字节都不许变长变短');
    // UT 的时间值清零，但 id/size/flags 原样保留
    expect(find(out, [0x55, 0x54, 0x05, 0x00, 0x01, 0, 0, 0, 0]) >= 0, isTrue,
        reason: 'UT 扩展字段的 mtime 没被清零');
    expect(find(out, [0x11, 0x22, 0x33, 0x44]) >= 0, isFalse,
        reason: '真时间戳还在文件里，等于没清');
    // NTFS 的三个 FILETIME 清零，字段头不变
    expect(
        find(out, [
          0x0A, 0x00, 0x20, 0x00, 0, 0, 0, 0, 0x01, 0x00, 0x18, 0x00,
          ...List<int>.filled(24, 0),
        ]) >=
            0,
        isTrue,
        reason: 'NTFS 扩展字段的 FILETIME 没被清零');
    expect(out.where((b) => b == 0xAB).isEmpty, isTrue,
        reason: 'FILETIME 的原始内容还在');
  });

  test('ZIP：条目/归档注释换成空格，时间戳清零，长度与条目内容不变', () {
    final src = buildZip(
      entryComment: 'C:\\Users\\jane\\secret',
      archiveComment: 'packed by jane',
    );

    final out = ShareMetadataStripper.strip(src, 'x.zip')!;
    expect(out.length, src.length);

    // ASCII 注释内容必须彻底消失
    final asLatin = latin1.decode(out);
    expect(asLatin.contains('jane'), isFalse,
        reason: '注释里的路径/用户名必须清掉');
    expect(asLatin.contains('packed by'), isFalse);

    // 条目数据保持原样（stored，直接可比）
    expect(find(out, utf8.encode('hello world')) >= 0, isTrue,
        reason: '剥离元数据不许动内容');

    // 两处 DOS 时间/日期都归零为 1980-01-01 00:00:00
    final local = find(out, [0x50, 0x4B, 0x03, 0x04]);
    final central = find(out, [0x50, 0x4B, 0x01, 0x02]);
    expect([u16(out, local + 10), u16(out, local + 12)], [0, 0x21]);
    expect([u16(out, central + 12), u16(out, central + 14)], [0, 0x21]);
  });

  test('ZIP：剥完仍是能被正常解析的压缩包（内容与 CRC 都对得上）', () async {
    const archiveComment = 'packed by jane';
    const entryComment = 'comment for jane';

    final archive = Archive()
      ..comment = archiveComment
      ..addFile(
          ArchiveFile('docs/note.txt', 11, utf8.encode('hello world').toList()))
      ..addFile(ArchiveFile('img.bin', 4, <int>[9, 8, 7, 6]));
    // ⚠️ archive 包的类型不一致：写进去的是 epoch 秒，读出来的是打包后的 DOS 值，
    // 所以判定要用 lastModDateTime 这个 getter。
    archive.files[0].lastModTime =
        DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000;
    archive.files[0].comment = entryComment;
    archive.files[1].lastModTime =
        DateTime(2024, 6, 7, 8, 9, 10).millisecondsSinceEpoch ~/ 1000;
    final src = Uint8List.fromList(ZipEncoder().encode(archive)!);

    final out = ShareMetadataStripper.strip(src, 'x.zip')!;
    expect(out.length, src.length);

    final back = ZipDecoder().decodeBytes(out);
    expect(back.files.length, 2, reason: '剥离后必须还能当压缩包读');
    expect(back.files[0].name, 'docs/note.txt');
    expect(utf8.decode(back.files[0].content as List<int>), 'hello world',
        reason: '内容不许被动过');
    expect(back.files[1].content as List<int>, [9, 8, 7, 6]);
    expect(back.files[0].lastModDateTime.year, 1980,
        reason: '修改时间已被归零，不再泄露真实时间');
    expect(back.files[1].lastModDateTime.year, 1980);

    // ⚠️ archive 的 ZipDecoder 不解析注释（zip_decoder.dart 里没有任何 comment
    // 相关代码）⇒ 注释只能在原始字节上核对：长度不变、内容全被空格填满。
    final eocd = find(out, [0x50, 0x4B, 0x05, 0x06]);
    final acLen = u16(out, eocd + 20);
    expect(acLen, utf8.encode(archiveComment).length,
        reason: '注释长度不许变（改了 EOCD 就得跟着改）');
    expect(
        out.sublist(eocd + 22, eocd + 22 + acLen).every((b) => b == 0x20),
        isTrue,
        reason: '归档注释应被空格覆盖');
    final cdAt = find(out, [0x50, 0x4B, 0x01, 0x02]);
    final cmtLen = u16(out, cdAt + 32);
    final cmtAt = cdAt + 46 + u16(out, cdAt + 28) + u16(out, cdAt + 30);
    expect(cmtLen, utf8.encode(entryComment).length);
    expect(out.sublist(cmtAt, cmtAt + cmtLen).every((b) => b == 0x20), isTrue,
        reason: '条目注释应被空格覆盖');
    expect(latin1.decode(out).contains('jane'), isFalse,
        reason: '注释里的用户名不许残留');
  });

  test('ZIP：不是压缩包就返回 null（绝不拿别的格式瞎改）', () {
    expect(ShareMetadataStripper.strip(
        Uint8List.fromList(List<int>.filled(100, 7)), 'x.zip'), isNull);
  });

  // ─── PDF ────────────────────────────────────────────────────────────────

  String buildPdf({
    String info = '/Title (Secret Doc) /Author (Jane Doe)'
        '/Producer (ZenFile) /CreationDate (D:20260101120000Z)',
    String? xmp,
    String trailerExtra = '/Info 3 0 R',
  }) {
    final xmpObj = xmp == null
        ? ''
        : '4 0 obj\n<< /Type /Metadata /Subtype /XML /Length ${xmp.length} >>\n'
            'stream\n$xmp\nendstream\nendobj\n';
    return '%PDF-1.4\n'
        '1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n'
        '2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n'
        '3 0 obj\n<< $info >>\nendobj\n'
        '$xmpObj'
        'trailer\n<< /Size 5 /Root 1 0 R $trailerExtra >>\n'
        '%%EOF\n';
  }

  const xmpPacket =
      '<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>'
      '<x:xmpmeta xmlns:x="adobe:ns:meta/">'
      '<rdf:RDF><rdf:Description xmp:CreatorTool="ZenFile"/></rdf:RDF>'
      '</x:xmpmeta><?xpacket end="w"?>';

  test('PDF：/Info 字符串与 XMP 包被就地清空，长度与括号配平不变', () {
    final src = Uint8List.fromList(utf8.encode(buildPdf(xmp: xmpPacket)));
    expect(utf8.decode(src).contains('Jane Doe'), isTrue);

    final out = ShareMetadataStripper.strip(src, 'x.pdf')!;

    expect(out.length, src.length, reason: '等长覆盖 ⇒ xref 偏移全部依旧正确');
    final text = latin1.decode(out);
    for (final secret in [
      'Secret Doc',
      'Jane Doe',
      'ZenFile',
      'D:20260101120000Z',
      'xmp:CreatorTool',
      'rdf:Description',
    ]) {
      expect(text.contains(secret), isFalse, reason: '$secret 没被清掉');
    }
    // 结构标记原样保留，只有内容变空格
    expect(text.contains('/Info 3 0 R'), isTrue);
    expect(text.contains('/Subtype /XML'), isTrue);
    expect(text.contains('%PDF-1.4'), isTrue);
    // 括号/尖括号配平不变（内容被空格整体覆盖，不会多出未配对的括号）
    int count(String ch) => ch.allMatches(text).length;
    expect(count('('), count(')'), reason: '括号配平被破坏 ⇒ 文件会解析失败');
    expect(count('<'), count('>'));
    expect(text.contains('/Title ('), isTrue,
        reason: '键名与括号要在，只是内容空了');
  });

  test('PDF：内容里的转义括号 / 假 key 不会把结构改坏', () {
    final src = Uint8List.fromList(utf8.encode(
        buildPdf(info: r'/Author (a\)b\\c (nested))', trailerExtra: '')));
    final out = ShareMetadataStripper.strip(src, 'x.pdf')!;
    expect(out.length, src.length);
    final text = latin1.decode(out);
    expect(text.contains('nested'), isFalse);
    int count(String ch) => ch.allMatches(text).length;
    expect(count('('), count(')'));
  });

  test('PDF：加密文档拒绝安全分享（字符串是密文，剥不掉就不能说已清理）', () {
    final src =
        utf8.encode(buildPdf(trailerExtra: '/Info 3 0 R /Encrypt 9 0 R'));
    expect(ShareMetadataStripper.strip(src, 'x.pdf'), isNull);
  });

  test('PDF：没有明文元数据时返回 null（不做一份毫无意义的副本）', () {
    final src = utf8.encode(buildPdf(
        info: '/Type /Catalog', trailerExtra: ''));
    expect(ShareMetadataStripper.strip(src, 'x.pdf'), isNull);
  });

  test('PDF：不是 PDF 就返回 null', () {
    expect(
        ShareMetadataStripper.strip(Uint8List.fromList(utf8.encode('hello')),
            'x.pdf'),
        isNull);
  });
}
