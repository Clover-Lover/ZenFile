// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'dart:convert';

import '../../webdav_debug_log.dart';

/// 网盘（夸克 / 阿里云盘）客户端的诊断日志。
///
/// ## 为什么必须单独有一层
///
/// `netdisk/` 下的客户端由「网页登录态 + 各家内部接口」驱动，**失败原因几乎全在
/// HTTP 层**：风控掐断 TLS 指纹、登录态失效、UA / 签名不匹配、Cookie 取不到
/// HttpOnly 项、接口返回业务码非 200…… 而这些在 UI 上只表现为一句「连接失败」，
/// 没有任何可定位的信息。没有日志，改多少次都只是猜（这正是接手前那轮反复
/// 「改了还是不行」的原因）。
///
/// ## 与 [WebdavDebugLog] 的关系
///
/// 本类只是它的**语义化包装**：统一加 `[netdisk:<tag>]` 前缀，并**强制脱敏**。
/// 开关沿用 [WebdavDebugLog.enabled]（项目既有约定：该开关即「通用诊断日志」，
/// 排查前打开、**发版前必须置 false**）。日志同落一个文件：
/// `/storage/emulated/0/ZenFile/webdav_debug.log`，无 adb 也能用文件管理器取出。
///
/// ## 脱敏是硬要求（不是可选）
///
/// 网盘请求里带的是**用户账号的长期凭据**：
/// * `Cookie`（夸克登录态，含 HttpOnly 项，一旦泄露等于账号易主）；
/// * `Authorization: Bearer <access_token>`（阿里）；
/// * 直链里的 `sign` / `token` 类查询参数（可被他人直接下载文件）。
///
/// 所以本类**只记「有哪些键、多长」，绝不记值**。这看起来"信息少"，但恰好够用：
/// 夸克那条链路的排查只需要回答「`__puus` 在不在 Cookie 里、一共几个键」，
/// 而不需要它的值。
class NetdiskLog {
  NetdiskLog._();

  /// 是否输出：跟随全局诊断开关。
  static bool get enabled => WebdavDebugLog.enabled;

  /// 写一行网盘日志（多行消息会逐行加前缀，便于日志文件里过滤）。
  static void log(String tag, String msg) {
    if (!enabled) return;
    final prefix = '[netdisk:$tag] ';
    for (final line in msg.split('\n')) {
      WebdavDebugLog.log('$prefix$line');
    }
  }

  /// 记录「发起请求」。
  static void request(String tag, String method, Uri uri,
      {Map<String, String>? headers, Object? body}) {
    if (!enabled) return;
    final sb = StringBuffer('→ $method ${redactUrl(uri.toString())}');
    if (headers != null && headers.isNotEmpty) {
      sb.write('\n    hdr: ${redactHeaders(headers)}');
    }
    if (body != null) {
      sb.write(
          '\n    body: ${snippet(body is String ? body : jsonEncodeSafe(body))}');
    }
    log(tag, sb.toString());
  }

  /// 记录「收到响应」。
  static void response(String tag, int statusCode, String body,
      {Duration? elapsed, int? contentLength}) {
    if (!enabled) return;
    final bits = <String>['← $statusCode'];
    if (elapsed != null) bits.add('${elapsed.inMilliseconds}ms');
    if (contentLength != null) bits.add('len=$contentLength');
    log(tag, '${bits.join(' ')}\n    resp: ${snippet(body)}');
  }

  /// 记录异常（保留类型名，便于区分「TLS 被掐」与「业务码非 200」）。
  static void error(String tag, String where, Object e) {
    if (!enabled) return;
    log(tag, '!! $where: ${e.runtimeType}: ${snippet(e.toString(), 300)}');
  }

  /// 记录一条自定义事件（登录态来源、路径解析、UA 等）。
  static void event(String tag, String msg) => log(tag, msg);

  // ---------------- 脱敏 / 摘要 ----------------

  static const int _snippetMax = 512;

  /// 截断 + 抹掉明文 token（JSON 形如 `"access_token":"..."`）。
  static String snippet(String? s, [int max = _snippetMax]) {
    if (s == null) return '<null>';
    var t = s.length > max ? '${s.substring(0, max)}…(+${s.length - max}字)' : s;
    t = t.replaceAllMapped(
      RegExp(
          r'("(?:access_token|refresh_token|token|password|sign)"\s*:\s*")([^"]*)(")'),
      (m) => '${m.group(1)}<redacted:${m.group(2)!.length}字>${m.group(3)}',
    );
    return t.replaceAll('\n', ' ⏎ ');
  }

  /// 请求头摘要：`Cookie` / `Authorization` 只留「键名 + 长度」。
  static String redactHeaders(Map<String, String> headers) {
    final parts = <String>[];
    headers.forEach((k, v) {
      final lk = k.toLowerCase();
      if (lk == 'cookie') {
        final names = v
            .split(';')
            .map((s) => s.split('=').first.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        parts.add('Cookie=[${names.length}项: ${names.join('|')}]');
      } else if (lk == 'authorization') {
        parts.add('Authorization=${maskSecret(v)}');
      } else if (lk == 'user-agent') {
        parts.add('UA="$v"');
      } else {
        parts.add('$k=$v');
      }
    });
    return parts.join(', ');
  }

  /// `Bearer <很长>` → `Bearer ab12cd…(1234字)`。
  static String maskSecret(String v) {
    final sp = v.indexOf(' ');
    if (sp < 0) return _abbrev(v);
    return '${v.substring(0, sp)} ${_abbrev(v.substring(sp + 1))}';
  }

  static String _abbrev(String v) {
    if (v.length <= 12) return '(${v.length}字)';
    return '${v.substring(0, 6)}…(${v.length}字)';
  }

  /// URL 脱敏：长值与 sign / token 类参数替换为 `<redacted>`。
  static String redactUrl(String url) {
    final u = Uri.tryParse(url);
    if (u == null || u.query.isEmpty) return url;
    final keep = <String>[];
    u.queryParameters.forEach((k, v) {
      keep.add(_isSensitiveParam(k, v) ? '$k=<redacted>' : '$k=$v');
    });
    return '${u.scheme}://${u.host}${u.path}?${keep.join('&')}';
  }

  static const List<String> _sensitiveNeedles = [
    'sign',
    'token',
    'auth',
    'secret',
    'password',
    'pwd',
    'key',
  ];

  static bool _isSensitiveParam(String key, String value) {
    if (value.length > 64) return true;
    final k = key.toLowerCase();
    for (final needle in _sensitiveNeedles) {
      if (k.contains(needle)) return true;
    }
    return false;
  }

  static String jsonEncodeSafe(Object o) {
    try {
      return jsonEncode(o);
    } catch (_) {
      return o.toString();
    }
  }
}
