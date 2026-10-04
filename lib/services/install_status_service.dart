import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 安装包「已安装 / 未安装」状态查询。
///
/// 原生侧实现见 `MainActivity.kt` 的 `getInstallStatus`
/// （`.apk` 用 `getPackageArchiveInfo` 读包名核对；`.xapk/.apks/.apkm/.aab`
/// 扫容器内的小元数据条目里是否出现已安装包名）。
class InstallStatusService {
  static const MethodChannel _channel = MethodChannel(
    'com.sequl.zenfile/apk_editor',
  );

  /// 批量查询。返回 `path -> 状态`；`1` = 已安装，`0` = 未安装，`-1` = 无法判定。
  /// 失败返回空表（调用方按「无法判定」处理，不显示标识）。
  static Future<Map<String, int>> getStatuses(List<String> paths) async {
    if (paths.isEmpty) return const {};
    try {
      final res = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getInstallStatus',
        {'paths': paths},
      );
      if (res == null) return const {};
      final out = <String, int>{};
      res.forEach((key, value) {
        final v = value is int ? value : (value as num?)?.toInt() ?? -1;
        out[key.toString()] = v;
      });
      return out;
    } catch (_) {
      return const {};
    }
  }
}

class _Entry {
  final int status;
  final String fingerprint;
  const _Entry(this.status, this.fingerprint);
}

/// 安装状态缓存（单例）：按「路径 + 文件指纹」缓存结果、批量去抖查询、
/// 结果就绪后自增 [revision] 让界面刷新。
///
/// 之所以要缓存：目录列表 / 网格会随滚动反复重建，若每次 build 都发一次原生调用，
/// 会拖慢滚动。这里让每个条目只在「首见」或「文件发生变化」时登记一次，
/// 40ms 内的登记合并成一次原生批量调用。
class InstallStatusCache {
  InstallStatusCache._();

  static final InstallStatusCache instance = InstallStatusCache._();

  /// 查询结果更新时自增，供 ValueListenableBuilder 刷新。
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  final Map<String, _Entry> _entries = {};
  final Map<String, String> _pending = {};
  Timer? _timer;
  bool _flushing = false;

  static String _fp(int size, int modifiedMs) => '$size@$modifiedMs';

  /// 同步取值：`true` 已安装 / `false` 未安装 / `null` 未知（不显示标识）。
  bool? statusOf(String path, int size, int modifiedMs) {
    final entry = _entries[path];
    if (entry == null || entry.fingerprint != _fp(size, modifiedMs)) return null;
    if (entry.status < 0) return null;
    return entry.status == 1;
  }

  /// 登记一个待查询路径（去抖后批量执行）。
  void request(String path, int size, int modifiedMs) {
    final fp = _fp(size, modifiedMs);
    final entry = _entries[path];
    if (entry != null && entry.fingerprint == fp) return;
    if (_pending[path] == fp) return;
    _pending[path] = fp;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 40), _flush);
  }

  Future<void> _flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final batch = Map<String, String>.from(_pending);
      _pending.clear();
      if (batch.isEmpty) return;
      final res = await InstallStatusService.getStatuses(batch.keys.toList());
      for (final item in batch.entries) {
        _entries[item.key] = _Entry(res[item.key] ?? -1, item.value);
      }
      revision.value++;
    } finally {
      _flushing = false;
      if (_pending.isNotEmpty) {
        _timer?.cancel();
        _timer = Timer(const Duration(milliseconds: 40), _flush);
      }
    }
  }

  /// 安装 / 卸载可能改变任何安装包的状态，回到前台时清空缓存重查。
  void invalidateAll() {
    _timer?.cancel();
    _timer = null;
    if (_entries.isEmpty && _pending.isEmpty) return;
    _entries.clear();
    _pending.clear();
    revision.value++;
  }
}
