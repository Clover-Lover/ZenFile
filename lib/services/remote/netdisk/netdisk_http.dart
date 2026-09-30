// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'dart:async';
import 'dart:io';

import 'package:cronet_http/cronet_http.dart';
import 'package:http/http.dart' as http;

import 'netdisk_log.dart';

/// 聚合网盘的 HTTP 栈选择与自动切换。
///
/// ## 为什么需要这一层（2026-09-30 真机日志结论）
///
/// 此前两个客户端都直接 `CronetClient.defaultCronetEngine()`。`cronet_http`
/// 默认依赖 `com.google.android.gms:play-services-cronet`，而那个 AAR 只是「壳」——
/// 它的 POM 只带 `cronet-api:72`，**没有任何实现**：真正的实现要么来自设备上的
/// Google Play 服务 Cronet 模块，要么来自 `cronet-embedded`。国产 ROM 两者皆无
/// ⇒ `CronetEngine.Builder` 在**构造时**就抛
/// `java.lang.RuntimeException: All available Cronet providers are disabled`，
/// 于是**请求一个字节都没发出去**（真机日志里每次 connect 都倒在同一个 JNI 异常）。
///
/// 对照证据：文析助手（同一台手机、同样网页登录取 Cookie 后访问夸克/阿里/百度等
/// 十余家网盘，工作正常）的 APK 里**完全没有 cronet**（zip 条目无 `libcronet`、
/// dex 无 `org.chromium.net`），它用的就是 Dart 自带的 `dart:io HttpClient`。
/// ⇒ 这些网盘**并不掐 dart:io**；此前"TLS 指纹被风控"的判断缺少证据。
///
/// ## 策略
///
/// - **默认 dart:io**：与可用的对照实现一致，且零原生依赖、任何设备都能用；
/// - 一旦某次请求以**连接级失败**告终（连接被重置/关闭、握手失败、超时），
///   就**自动切到 Cronet**（Chrome 网络栈）并重试一次；
/// - 切换是**会话级粘性**的，切过去不再切回，避免同一批请求来回抖动。
///
/// 业务错误（HTTP 4xx/5xx、接口 `status != 200`）**绝不**触发切换：那说明栈本身
/// 是通的，换栈只会掩盖真实原因（风控/登录态在响应体里写得很清楚）。
class NetdiskHttp {
  NetdiskHttp._();

  /// 本次会话是否已切到 Cronet。
  static bool _preferCronet = false;

  /// 当前是否使用 Cronet 栈（供请求头构造判断）。
  static bool get usingCronet => _preferCronet;

  static bool _cronetProbed = false;
  static bool _cronetUsable = false;
  static CronetEngine? _engine;

  /// 每个 tag 的每类提示只打一次，避免刷屏。
  static final Set<String> _notified = <String>{};

  /// 创建 HTTP 客户端；[tag] 仅用于日志。
  static http.Client create(String tag) {
    if (_preferCronet) {
      if (_ensureCronet(tag)) {
        // 引擎由本类复用 ⇒ 客户端关闭时不销毁引擎。
        return CronetClient.fromCronetEngine(_engine!, closeEngine: false);
      }
      // 想用 Cronet 却建不起来：退回 dart:io，别让整个功能不可用。
      _preferCronet = false;
    }
    _notifyOnce(tag, 'use-io', 'HTTP 栈 = dart:io');
    return http.Client();
  }

  /// 执行一次请求；**首次**遇到连接级失败时自动换栈并重试一次。
  ///
  /// 只在第一跳重试：换栈是全局粘性的，后续请求直接用新栈，不会反复重试。
  static Future<T> run<T>(
      String tag, Future<T> Function(http.Client client) body) async {
    for (var attempt = 0;; attempt++) {
      final client = create(tag);
      try {
        return await body(client);
      } catch (e) {
        if (attempt == 0 && escalateIfStackFailure(tag, e)) continue;
        rethrow;
      } finally {
        client.close();
      }
    }
  }

  /// [error] 是否是「网络栈层面」的失败（而非服务器已回包的业务错误）。
  static bool looksLikeStackFailure(Object error) {
    if (error is SocketException) return true;
    if (error is HandshakeException) return true;
    if (error is HttpException) return true; // 例：Connection closed while receiving data
    if (error is TimeoutException) return true;
    final s = error.toString().toLowerCase();
    return s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('connection terminated') ||
        s.contains('broken pipe') ||
        s.contains('socketexception') ||
        s.contains('handshakeexception') ||
        s.contains('timeoutexception') ||
        s.contains('cronet providers are disabled') ||
        s.contains('jniexception');
  }

  /// 若 [error] 属于网络栈失败，则把本会话切到 Cronet；返回 true = 调用方应重试。
  static bool escalateIfStackFailure(String tag, Object error) {
    if (_preferCronet) return false;
    if (!looksLikeStackFailure(error)) return false;
    if (!_ensureCronet(tag)) {
      _notifyOnce(
          tag,
          'no-cronet',
          'dart:io 连接失败，但本机 Cronet 不可用（既无 GMS 也无 embedded 实现），'
              '无法换栈重试。原始错误：${NetdiskLog.snippet('$error', 160)}');
      return false;
    }
    _preferCronet = true;
    _notifyOnce(
        tag,
        'switch',
        'dart:io 连接失败（${NetdiskLog.snippet('$error', 120)}）'
        '→ 已切换 HTTP 栈 = Cronet 并重试');
    return true;
  }

  /// 构建并缓存 Cronet 引擎；失败即判定本机不可用（不再重复尝试）。
  ///
  /// `CronetEngine.build()` 在构造 Builder 时就会同步抛异常（provider 全禁用），
  /// 所以能干净地探测可用性，不需要发真实请求去试探。
  static bool _ensureCronet(String tag) {
    if (_cronetProbed) return _cronetUsable;
    _cronetProbed = true;
    if (!Platform.isAndroid) {
      _cronetUsable = false;
      return false;
    }
    try {
      _engine = CronetEngine.build();
      _cronetUsable = true;
      NetdiskLog.event(tag, 'Cronet 引擎就绪（embedded 或 GMS provider 可用）');
    } catch (e) {
      _cronetUsable = false;
      NetdiskLog.error(tag, 'Cronet 引擎构建失败', e);
    }
    return _cronetUsable;
  }

  static void _notifyOnce(String tag, String key, String message) {
    if (!_notified.add('$tag:$key')) return;
    NetdiskLog.event(tag, message);
  }
}
