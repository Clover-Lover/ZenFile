/// CryptFile 块级随机写回归（2026-10-02 重写 write 实现）。
///
/// 旧实现把 `[0..offset)` 明文全部读入内存并**整文件重加密重写**；
/// 新实现利用 rclone crypt「每块 nonce 由块号派生、块间独立」的性质做
/// 块级读-改-写。本测试钉住两个不变式：
///  1. 写入后的明文内容 = `[0..offset)` 原文 + 新数据（超出部分被截断）；
///  2. 产物与流式加密格式逐字节兼容（可用 RcloneStreamDecrypter 完整解出）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/crypt/crypt.dart';

/// 简单字节收集器（dart:io 与 dart:typed_data 同时导入时 BytesBuilder 有歧义）。
class _Collector {
  final List<int> _out = <int>[];
  void add(List<int> bytes) => _out.addAll(bytes);
  Uint8List take() => Uint8List.fromList(_out);
}

void main() {
  late Directory tmp;
  final crypt = RcloneCrypt(
    config: const RcloneCryptConfig(password: 'test-password', salt: 'test-salt'),
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('zenfile_cfw_test');
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('中间跨块写入：覆盖并截断（与旧实现语义一致）', () async {
    final path = '${tmp.path}/a.bin';
    final original = List<int>.generate(150000, (i) => i & 0xFF); // 跨 3 个块
    final cf = await CryptFile.open(path, crypt, mode: CryptFileMode.write);
    await cf.write(0, original);
    await cf.close();

    // 跨块边界写入（块大小 64KiB，60000..70000 跨越 65536 边界）。
    // 语义：从 offset 覆盖，写入后文件长度 = offset + data.length（截断）。
    final patch = List<int>.generate(10000, (i) => (i * 13 + 7) & 0xFF);
    final cf2 = await CryptFile.open(path, crypt, mode: CryptFileMode.append);
    expect(cf2.length, original.length);
    await cf2.write(60000, patch);
    expect(cf2.length, 70000);
    await cf2.close();

    final cf3 = await CryptFile.open(path, crypt, mode: CryptFileMode.read);
    final out = await cf3.read(0);
    await cf3.close();
    expect(out.length, 70000);
    expect(out.sublist(0, 60000), original.sublist(0, 60000), reason: '补丁前内容不变');
    expect(out.sublist(60000), patch, reason: '补丁内容正确（其后被截断）');
  });

  test('写入会截断超出部分（与旧实现语义一致）', () async {
    final path = '${tmp.path}/b.bin';
    final original = List<int>.generate(100000, (i) => i & 0xFF);
    final cf = await CryptFile.open(path, crypt, mode: CryptFileMode.write);
    await cf.write(0, original);
    await cf.close();

    final cf2 = await CryptFile.open(path, crypt, mode: CryptFileMode.append);
    await cf2.write(100, [9, 9, 9]); // 新长度 = 103 < 旧长度
    await cf2.close();

    final cf3 = await CryptFile.open(path, crypt, mode: CryptFileMode.read);
    final out = await cf3.read(0);
    await cf3.close();
    expect(out.length, 103);
    expect(out.sublist(0, 100), original.sublist(0, 100));
    expect(out.sublist(100), [9, 9, 9]);
  });

  test('offset 超出文件末尾时按追加处理', () async {
    final path = '${tmp.path}/c.bin';
    final cf = await CryptFile.open(path, crypt, mode: CryptFileMode.write);
    await cf.write(0, [1, 2, 3]);
    await cf.close();

    final cf2 = await CryptFile.open(path, crypt, mode: CryptFileMode.append);
    await cf2.write(99999, [4, 5]); // 远超旧长度 → 紧接旧内容追加
    await cf2.close();

    final cf3 = await CryptFile.open(path, crypt, mode: CryptFileMode.read);
    final out = await cf3.read(0);
    await cf3.close();
    expect(out, [1, 2, 3, 4, 5]);
  });

  test('产物与流式加密格式逐字节兼容（RcloneStreamDecrypter 可完整解出）', () async {
    final path = '${tmp.path}/d.bin';
    final original = List<int>.generate(140000, (i) => (i * 31 + 5) & 0xFF);
    final cf = await CryptFile.open(path, crypt, mode: CryptFileMode.write);
    await cf.write(0, original);
    // 同一打开句柄上再改一次中间内容：写入后文件 = 原[0..70000) + 新 3 字节
    await cf.write(70000, [42, 43, 44]);
    await cf.close();

    final encBytes = await File(path).readAsBytes();
    final decrypter = RcloneStreamDecrypter(dataKey: crypt.derivedKeys.dataKey);
    final plain = _Collector();
    plain.add(decrypter.process(encBytes));
    plain.add(decrypter.finish());

    final expected = List<int>.of(original).sublist(0, 70000)..addAll([42, 43, 44]);
    expect(plain.take(), expected);
  });
}
