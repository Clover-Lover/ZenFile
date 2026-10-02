/// Web 分享路径安全校验回归。
///
/// 旧实现用 `p.normalize(x).startsWith(p.normalize(root))`：缺少尾分隔符，
/// `/root/../rootEvil` 归一化后仍以 `/root` 开头 → 通过校验并逃逸到同级目录。
/// 新实现用 `p.isWithin`。本测试钉住经典的绕过样本必须全部被拒绝。
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/web_sharing_service.dart';

void main() {
  const root = '/storage/emulated/0';

  test('根内路径放行', () {
    expect(WebSharingService.isWithinRoot('/storage/emulated/0/DCIM', root), isTrue);
    expect(WebSharingService.isWithinRoot('/storage/emulated/0/a/b/c.txt', root), isTrue);
    expect(WebSharingService.isWithinRoot('/storage/emulated/0', root), isTrue,
        reason: '根目录本身放行');
    expect(WebSharingService.isWithinRoot('/storage/emulated/0/', root), isTrue);
  });

  test('经典前缀绕过样本全部拒绝', () {
    // /root/../0evil → 归一化为 /storage/emulated/0evil（同级兄弟目录）
    expect(
      WebSharingService.isWithinRoot('/storage/emulated/0/../0evil', root),
      isFalse,
      reason: '旧 startsWith 实现会放行此路径',
    );
    expect(WebSharingService.isWithinRoot('/storage/emulated/0/..', root), isFalse);
    expect(WebSharingService.isWithinRoot('/storage/emulated/0/../..', root), isFalse);
    expect(WebSharingService.isWithinRoot('/storage/emulated/0evil', root), isFalse);
    expect(WebSharingService.isWithinRoot('/data/local/tmp', root), isFalse);
  });

  test('含 .. 但最终仍在根内的路径放行', () {
    expect(
      WebSharingService.isWithinRoot('/storage/emulated/0/DCIM/../Download', root),
      isTrue,
    );
  });

  test('未归一化的相对混淆形式拒绝', () {
    expect(
      WebSharingService.isWithinRoot('/storage/emulated/0/./../../etc', root),
      isFalse,
    );
  });
}
