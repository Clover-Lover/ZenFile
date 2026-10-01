import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zenfile/services/update_apk_cache.dart';

/// 回归测试：自动下载的更新安装包**不能无限堆积**。
///
/// 背景：用户在「版本更新」页点「下载并安装」时，APK 落在 app 私有缓存
/// （`getTemporaryDirectory()`，即 `/data/user/0/<pkg>/cache`）。下载完交给系统
/// 安装器后应用拿不到「装完了没」的回报，于是**从来没人删它** —— 每更新一次就
/// 多一个十几 MB 的文件，几次之后应用缓存越来越大。
///
/// 因此这里钉住三件事：
///  1. 过期的旧包会被清掉，且**只清自己命名的那批**（别的缓存/用户文件不许碰）；
///  2. 正在用（`keepPath`）和刚下载的文件绝对不删 —— 删了会让安装失败；
///  3. 下载失败留下的半成品能被立即删掉。
void main() {
  late Directory tmp;

  File write(String name, {DateTime? modified}) {
    final f = File(p.join(tmp.path, name));
    f.writeAsStringSync('x' * 64);
    if (modified != null) f.setLastModifiedSync(modified);
    return f;
  }

  DateTime daysAgo(int d) => DateTime.now().subtract(Duration(days: d));

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zf_update_apk_');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('过期更新包被清掉，刚下载的保留（清早了会让系统安装器读不到）', () async {
    final old = write('${UpdateApkCache.prefix}3.4.0.apk',
        modified: daysAgo(3));
    final fresh = write('${UpdateApkCache.prefix}3.4.1.apk');

    final deleted = await UpdateApkCache.sweep(dirPathOverride: tmp.path);

    expect(old.existsSync(), isFalse, reason: '3 天前的旧包必须被清掉');
    expect(fresh.existsSync(), isTrue, reason: '刚下完的包还在被安装器读，不能删');
    expect(deleted, 1);
  });

  test('keepPath 指定的文件无论多旧都不删（本次要用的那个）', () async {
    final keep =
        write('${UpdateApkCache.prefix}3.4.1.apk', modified: daysAgo(9));
    final other =
        write('${UpdateApkCache.prefix}3.3.9.apk', modified: daysAgo(9));

    await UpdateApkCache.sweep(keepPath: keep.path, dirPathOverride: tmp.path);

    expect(keep.existsSync(), isTrue, reason: '本次下载目标不许被自己的清理删掉');
    expect(other.existsSync(), isFalse);
  });

  test('只清自己命名的那批：别处的缓存 / 用户自己的 apk 一律不碰', () async {
    final foreign = <File>[
      write('media_meta_cache.json', modified: daysAgo(30)),
      write('some_thumb.thumb', modified: daysAgo(30)),
      write('ZenFile_update_3.4.0.apk.bak', modified: daysAgo(30)),
      write('my_own_backup.apk', modified: daysAgo(30)),
    ];
    Directory(p.join(tmp.path, 'sub')).createSync(recursive: true);
    write(p.join('sub', '${UpdateApkCache.prefix}1.0.0.apk'),
        modified: daysAgo(30));

    await UpdateApkCache.sweep(dirPathOverride: tmp.path);

    for (final f in foreign) {
      expect(f.existsSync(), isTrue,
          reason: '${p.basename(f.path)} 不归更新包缓存管，绝不能被误删');
    }
    expect(File(p.join(tmp.path, 'sub', '${UpdateApkCache.prefix}1.0.0.apk'))
        .existsSync(), isTrue, reason: '只扫顶层，不下钻子目录');
  });

  test('下载失败：discard 能删自己的半成品，且不越权删别人的文件', () async {
    final partial = write('${UpdateApkCache.prefix}3.4.1.apk');
    final mine = write('my_own_backup.apk');

    await UpdateApkCache.discard(partial.path);
    await UpdateApkCache.discard(mine.path); // 非本类命名的路径必须被忽略
    await UpdateApkCache.discard(p.join(tmp.path, 'never_existed.apk'));

    expect(partial.existsSync(), isFalse, reason: '半成品留着只会占地方');
    expect(mine.existsSync(), isTrue, reason: '用户自己的 apk 不许删');
  });

  test('目录不存在时返回 0 且不抛（清理失败不该变成新的崩溃源）', () async {
    expect(
      await UpdateApkCache.sweep(
          dirPathOverride: p.join(tmp.path, 'not-exists')),
      0,
    );
  });

  test('目标文件命名规则与识别规则必须一致（能下的 = 能清的）', () async {
    final f = await UpdateApkCache.targetFile(
      '3.4.1',
      dirPathOverride: tmp.path,
    );
    expect(p.basename(f.path), '${UpdateApkCache.prefix}3.4.1.apk');
    expect(p.dirname(f.path), tmp.path);
    expect(UpdateApkCache.isUpdateApk(f.path), isTrue);

    // 前缀必须与历史版本一致，否则用户机器上已经堆积的旧包清不掉。
    expect(UpdateApkCache.prefix, 'ZenFile_update_');
    expect(UpdateApkCache.retention, const Duration(hours: 24));
  });
}
