/// 远程会话的「失效判定 + 重建后重试一次」通用逻辑。
///
/// 背景（2026-09-20 论坛用户反馈）：远程连接（SFTP/SMB 等）在应用切到后台、
/// 网络切换或服务器空闲回收之后，底层 socket / 原生会话其实已经死了，但 Dart
/// 侧只持有自己的「已连接」标记，感知不到 —— 于是下一次操作直接抛错，用户唯一
/// 出路是退出连接重进（表现为「必须重新登录」）。
///
/// 这里把「哪些错误算连接失效」与「重试一次」的流程抽成纯逻辑，便于单测：
/// 调用方注入 [attempt]（真实操作）与 [reconnect]（重建客户端）。
library;

import 'dart:async';

/// 连接类 / 会话类错误的关键词（小写包含匹配）。
///
/// 命中即认为「重建连接后重试一次可能救回来」。相反，认证失败、权限不足、
/// 文件不存在等**不属于**这里 —— 重连解决不了它们，只会白等一次握手。
///
/// 关键词来源：JSch（`Session is down` / `session is down`）、smbj
/// （`SMB session not established`）、dartssh2（`SocketException`、
/// `Broken pipe`）、ftpconnect（`control connection closed`）以及 dart:io 的
/// 通用 socket 错误文案。
const List<String> kRemoteConnectionLostMarkers = <String>[
  'session is down',
  'session not found',
  'session is not connected',
  'session not established',
  'session has been closed',
  'not connected',
  'broken pipe',
  'connection reset',
  'connection closed',
  'connection aborted',
  'connection refused',
  'control connection closed',
  'channel is closed',
  'channel not opened',
  'socketexception',
  'socket closed',
  'unexpected end of file',
  'end of file',
  'pipe closed',
  'transport closed',
  'client is closed',
  // socket 层超时 = 底层连接已死（smbj `withSoTimeout` 空闲超时、网络中断等），
  // 重建连接即可恢复。必须单独列出：Java 的 SocketTimeoutException toString 是
  // "java.net.SocketTimeoutException: Read timed out"（lowercase 含 read timed
  // out 但不含 socketexception），不补上会导致会话假死后「无法访问且只能重启
  // 客户端」（2026-09-30 排查结论：服务端无空闲超时，问题在客户端判定）。
  'read timed out',
  'socket timed out',
  'socket timeout',
  // Dart 侧超时（Future.timeout 抛 TimeoutException）。必须纳入：SMB 的典型
  // 时序是「原生 smbj withSoTimeout(60s) 还没炸、Dart 侧 30s 超时先炸」，
  // 到达判定层的错误文案是 "TimeoutException after 0:00:30..."，与上面任何
  // Java 侧 marker 都不匹配 → 会话假死后重连分支永远不触发，用户只能退出
  // 连接重进（2026-10-02 排查结论：2f220a88 补的 Java 文案 marker 因此落空）。
  // 会话假活但服务器单纯慢时的代价只是「重建连接 + 多试一次」，可接受。
  'timeoutexception',
];

/// 该错误是否属于「连接/会话已失效」类（重连可能救回来）。
bool isRemoteConnectionLostError(Object? error) {
  if (error == null) return false;
  // Dart 侧 Future.timeout 抛的 TimeoutException 直接按类型判定：它意味着
  // 「规定时间内没有拿到结果」，对长连接协议而言最常见的成因就是底层连接
  // 已死（静默丢包 / 被回收），重建连接重试是对用户最透明的恢复路径。
  if (error is TimeoutException) return true;
  final s = error.toString().toLowerCase();
  if (s.isEmpty) return false;
  for (final marker in kRemoteConnectionLostMarkers) {
    if (s.contains(marker)) return true;
  }
  return false;
}

/// 执行 [attempt]，遇到连接类错误时先 [reconnect] 再重试。
///
/// - [maxRetries] 默认 1：只重试一次。服务器真的不可达时，反复握手只会让
///   用户多等好几秒，不如把原错误原样抛出。
/// - [reconnect] 返回 false（例如处于重连冷却期、或重建本身失败）时**立即**
///   抛出原始错误，不消耗重试次数。
/// - [shouldRetry] 可覆盖判定（默认 [isRemoteConnectionLostError]）。
/// - [onReconnected] 重连成功并即将重试时回调，调用方可用于日志 / 轻提示。
///
/// 返回 [attempt] 的结果；全部尝试失败时抛出最后一次的错误（保留原始堆栈）。
Future<T> retryWithRemoteReconnect<T>({
  required Future<T> Function() attempt,
  required Future<bool> Function() reconnect,
  bool Function(Object error)? shouldRetry,
  int maxRetries = 1,
  void Function(Object error, bool willRetry)? onError,
}) async {
  final canRetry = shouldRetry ?? isRemoteConnectionLostError;
  var retried = 0;
  while (true) {
    try {
      return await attempt();
    } catch (e) {
      if (retried >= maxRetries || !canRetry(e)) {
        onError?.call(e, false);
        rethrow;
      }
      final bool reconnected = await reconnect();
      if (!reconnected) {
        onError?.call(e, false);
        rethrow;
      }
      retried++;
      onError?.call(e, true);
    }
  }
}
