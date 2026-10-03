import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 被第三方 App 以 ACTION_GET_CONTENT / ACTION_PICK 调起时的「系统文件选择器」桥接。
///
/// 背景：ZenFile 注册了 GET_CONTENT 入口后，会作为可选来源出现在系统 chooser 中。
/// 此时不应显示常规首页，而是直接打开 ZenFile 自己的文件浏览器
/// （`InternalFilePickerScreen`）让用户选文件，选完把结果回传给调起方 ——
/// 这比系统选择器里由 DocumentsUI 渲染的「ZenFile Storage」列表页好用得多。
///
/// ⚠️ 所有方法都只能在 `runApp()` **之后**调用（内部 await 原生通道）。
class SystemFilePickerService {
  static const MethodChannel _channel = MethodChannel('com.sequl.zenfile/file_picker');

  /// 查询本次启动是否为「系统文件选择器」模式。
  static Future<SystemFilePickerInfo> getInfo() async {
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>('getPickerInfo');
      if (res == null) return SystemFilePickerInfo.none;
      return SystemFilePickerInfo(
        isPicker: res['isPicker'] == true,
        allowMultiple: res['allowMultiple'] == true,
        mime: res['mime'] as String?,
      );
    } on PlatformException catch (e) {
      // 原生侧尚未注册该通道时也会走这里（MissingPluginException 是
      // PlatformException 的实现类），一律按「普通启动」处理。
      debugPrint('[file_picker] getPickerInfo failed: ${e.code}');
      return SystemFilePickerInfo.none;
    }
  }

  /// 注册「原生侧主动推送选文件请求」的回调。
  ///
  /// 用于 `onNewIntent`：MainActivity 是 singleTask，ZenFile 已在后台运行时第三方
  /// 再次调起选文件不会走 onCreate，此时原生侧没有机会回答 Dart 的查询，只能主动推。
  /// 不注册的话，这种「ZenFile 在后台」场景只会把首页带到前台，选文件界面不出现。
  static void setIntentHandler(void Function(SystemFilePickerInfo info) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onPickerIntent') return;
      final args = call.arguments;
      if (args is! Map) return;
      handler(
        SystemFilePickerInfo(
          isPicker: args['isPicker'] == true,
          allowMultiple: args['allowMultiple'] == true,
          mime: args['mime'] as String?,
        ),
      );
    });
  }

  /// 把选中的文件路径回传给调起方，并结束本页（原生侧 setResult + finish）。
  static Future<bool> finishPick(List<String> paths) async {
    try {
      final ok = await _channel.invokeMethod<bool>('finishPick', {'paths': paths});
      return ok == true;
    } on PlatformException catch (e) {
      debugPrint('[file_picker] finishPick failed: ${e.code}');
      return false;
    }
  }

  /// 用户取消选择（原生侧 setResult(CANCELED) + finish）。
  static Future<void> cancelPick() async {
    try {
      await _channel.invokeMethod<void>('cancelPick');
    } on PlatformException catch (e) {
      debugPrint('[file_picker] cancelPick failed: ${e.code}');
    }
  }
}

/// 本次启动的「系统文件选择器」上下文。
class SystemFilePickerInfo {
  /// 是否由第三方 App 以选文件为目的调起。
  final bool isPicker;

  /// 调起方是否允许选择多个文件（Intent.EXTRA_ALLOW_MULTIPLE）。
  final bool allowMultiple;

  /// 调起方要求的 MIME 类型（可能为 `*/*` 或 null，表示不限制）。
  final String? mime;

  const SystemFilePickerInfo({
    required this.isPicker,
    this.allowMultiple = false,
    this.mime,
  });

  /// 普通启动（不是被调起选文件）。
  static const SystemFilePickerInfo none = SystemFilePickerInfo(isPicker: false);
}
