import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../ui/screens/audio_player/audio_artwork_widget.dart';
import '../core/navigator_key.dart';
import '../l10n/generated/app_localizations.dart';
import 'desktop_lyric_controller.dart';
import 'mpv_audio_output_service.dart';
import 'preferences_service.dart';
import 'power_management_service.dart';
import 'webdav_debug_log.dart';

/// Global singleton handler instance
ZenFileAudioHandler? _audioHandlerInstance;

/// Whether AudioService.init has successfully registered the handler.
/// 若为 false，表示 audio_service 框架未注册，通知栏无法显示，
/// 此时 playbackState 的更新不会到达系统通知层。
bool isAudioServiceInitialized = false;

/// Returns the global audio handler, creating it lazily if needed.
ZenFileAudioHandler getAudioHandler() {
  _audioHandlerInstance ??= ZenFileAudioHandler._();
  return _audioHandlerInstance!;
}

/// Utility to query artwork bytes, cache them locally in a temporary directory,
/// and return the local file [Uri] for the [MediaItem].
Future<Uri?> getArtworkUri(int audioId) async {
  if (audioId <= 0) return null;
  try {
    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/artwork_$audioId.png');
    if (await file.exists()) {
      return file.uri;
    }
    final data = await AudioArtworkCache.getArtwork(audioId);
    if (data != null && data.isNotEmpty) {
      await file.writeAsBytes(data);
      return file.uri;
    }
  } catch (e) {
    debugPrint('[ZenFile] Error getting artwork URI: $e');
  }
  return null;
}

/// Bridges media_kit [Player] to [audio_service] so the OS shows a proper
/// media notification with play / pause / skip controls.
class ZenFileAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  ZenFileAudioHandler._();

  Player? _player;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _positionSaveTimer;

  /// position 推送到通知栏的最小间隔（毫秒）。
  ///
  /// 🔴 为什么必须节流（2026-09-28 v3.2.0 线上 ANR 事故）：media_kit 的 `position`
  /// 流在播放期间持续推送（视频模式下尤其密），而每次 `playbackState.add(...)` 都会
  /// 让 audio_service 走 MethodChannel 到**原生主线程**重建整条通知（4 个 action +
  /// MediaStyle + Binder IPC）。3.2.0 让视频也走这条通知链路后，不节流等于把主线程
  /// 泡在 IPC 里 ⇒ 用户反馈「ZenFile 没有响应，点『等待』还能继续用」（ANR，
  /// 主线程 utm≈92s、native 栈在 libapp.so 里周期性重复）。
  /// 通知栏进度条只需秒级精度，1 秒一次完全够用。
  static const int _positionEmitIntervalMs = 1000;

  /// 上次推送 position 的时间戳（毫秒），配合 [_positionEmitIntervalMs] 做节流。
  int _lastPositionEmitMs = 0;

  /// 上一次真正推送出去的播放状态（**去重**：状态没变就不再重建通知）。
  /// ⚠️ 复位只在 [detach] 里做 —— 别在别处清，否则 attach 后的首次推送会被误吞。
  bool? _lastEmittedPlaying;
  Duration? _lastEmittedPosition;

  /// 当前**被前台播放页持有**的那个 player（原为全局单布尔 `foregroundHoldsPlayer`）。
  ///
  /// ⚠️ 为什么必须**按 player 身份**记，而不是「有没有人持有任意 player」的全局布尔：
  /// 音频播放页与视频播放页会叠加（音频在后台播、用户再打开视频），此时 A 页
  /// `dispose()` 会把全局布尔无条件置 false ⇒ **B 页仍在用的 player 被误判为无主**
  /// ⇒ 被回收 ⇒ 返回 B 页时一次原生调用就是 use-after-free ⇒ `CRASH_NATIVE`。
  ///
  /// 语义：非 null ⇔「handler 当前关联的 player 正被某个前台页持有，两条路径都
  /// **绝不能** dispose 它」（1. `stop()`；2. `attach()` 换绑时回收 oldPlayer）。
  /// 由播放页在 attach 成功后 `markForegroundHolds(player)`、在 `dispose()` 时
  /// `clearForegroundHolds(player)`（**带身份**，只撤销自己的登记）。
  Player? _foregroundPlayer;

  /// 兼容旧读法：是否有 player 正被前台页持有。
  bool get foregroundHoldsPlayer => _foregroundPlayer != null;

  /// [p] 是否正被前台播放页持有（回收前的判据）。
  bool isForegroundHeld(Player p) => _foregroundPlayer == p;

  /// 登记「本页仍持有 [p]」。
  void markForegroundHolds(Player p) {
    _foregroundPlayer = p;
    WebdavDebugLog.log('[bg] markForegroundHolds(#${identityHashCode(p)})');
  }

  /// 撤销登记（页面销毁时调用）。
  ///
  /// ⚠️ 必须带 player 身份：只有当登记的正是 [p] 才清空，否则「视频页退出」会把
  /// 「音频页的登记」一起清掉，音频的 player 又变成可被误回收。
  void clearForegroundHolds(Player p) {
    if (_foregroundPlayer == p) {
      _foregroundPlayer = null;
      WebdavDebugLog.log('[bg] clearForegroundHolds(#${identityHashCode(p)})');
    }
  }

  /// 正在退役 / 已退役的 player，防止**重复 dispose**（重复销毁同样是 native 崩溃源）。
  final Set<Player> _retiring = {};

  /// 退役串行队列 —— 「停 → 销毁」全程排队执行，避免与其它原生调用并发。
  Future<void> _retireQueue = Future<void>.value();

  /// 优雅退役一个不再需要的 player。
  ///
  /// ⚠️ 铁律（本项目已多次踩坑，详见技能 `zenfile-crash-forensics`）：
  /// **绝不能对正在播放 / 仍可能被原生调用的 player 直接 `dispose()`。**
  /// `dispose()` 会立刻释放 mpv native 上下文，而此刻它的 AO 线程、解码线程、
  /// MediaCodec 可能仍在跑，任何 pending 的 `setProperty` / `open` 恢复后就是
  /// use-after-free ⇒ SIGSEGV ⇒ `CRASH_NATIVE`（Dart 侧拿不到栈，崩溃报告只写
  /// 「系统未提供 trace」）。
  ///
  /// 正确顺序（本方法职责）：先 `stop()` 让 mpv 正常收尾、**await 完成**，再
  /// `dispose()`；顺便让桌面歌词控制器停止跟踪该 player；整个过程**串行 + 去重**。
  /// 返回**整条退役队列的尾部**：不需要排序的调用方可以忽略（fire-and-forget）；
  /// 需要「旧实例先死、新实例再 open」的调用方（`stop()` /
  /// [takeOverBackgroundSession]）**必须** await 它。
  Future<void> _retirePlayer(Player p, {required String reason}) {
    if (_retiring.contains(p)) {
      WebdavDebugLog.log('[bg] retire($reason, #${identityHashCode(p)}) 已在队列，跳过');
      // ⚠️ 不能写裸 `return;`：本方法返回 `Future<void>`（**非 async**），
      // 裸 return 会报 `The return value is missing after 'return'`
      // （return_without_value，编译级错误）。返回当前队列尾部即可。
      return _retireQueue;
    }
    _retiring.add(p);
    // ⚠️ 先声明作废，再排队销毁：本服务（`MpvAudioOutputService`）里有多个
    // 「延迟 N 秒后回读 mpv 属性」的诊断任务**正持有同一个 player**，它们发的是
    // 裸原生调用。不先声明作废，销毁后这些任务会对着已释放的 mpv ctx 调
    // `getProperty` ⇒ use-after-free ⇒ CRASH_NATIVE（Dart 侧无栈）。
    MpvAudioOutputService.abandon(p);
    WebdavDebugLog.log('[bg] retire($reason, #${identityHashCode(p)}) 入队');
    _retireQueue = _retireQueue.then((_) async {
      try {
        await p.stop();
      } catch (e) {
        debugPrint('[ZenFile] retire stop failed: $e');
      }
      try {
        DesktopLyricController.instance.stopIfPlayer(p);
      } catch (_) {}
      try {
        await p.dispose();
        WebdavDebugLog.log('[bg] retire($reason, #${identityHashCode(p)}) 已销毁');
      } catch (e) {
        debugPrint('[ZenFile] retire dispose failed: $e');
      } finally {
        _retiring.remove(p);
      }
    }).catchError((Object e) {
      // 兜底：任何意外都不能让队列停在 error 态 —— 一旦停在 error，后续所有
      // `.then` 都不会再执行 ⇒ 之后每个要退役的 player 都永远不释放（泄漏）。
      debugPrint('[ZenFile] retire queue error: $e');
    });
    return _retireQueue;
  }

  /// 本次后台会话是否来自**视频**播放器（由 `attach(videoSession: true)` 置位）。
  ///
  /// 视频后台播放时 `mediaItem` 里放的是视频（通知栏要显示视频标题），但音频类别页
  /// 顶部的「继续播放」卡片也读 `mediaItem`/`currentMediaItem`，于是会显示成视频
  /// 播放记录（用户反馈 2026-09-27）。**读 `currentMediaItem` 的音频侧代码必须先看
  /// 这个标志**，为 true 时退回 `lastPlayedAudio`。
  /// 生命周期：`attach()` 里按参数赋值、`detach()` 里复位 false（`attach` 内部先
  /// 调 `detach()`，所以赋值必须写在 `detach()` 之后）。
  bool videoSession = false;

  /// 当前关联的播放器（后台播放时可用于恢复界面）
  Player? get currentPlayer => _player;

  /// 音频后台会话的**原始歌曲队列快照**（来自播放页的 `_allSongs`）。
  ///
  /// 用途：从通知栏 / 类别页「继续播放」重新进入播放页时，调用方**拿不到**当初那个
  /// 播放队列 —— 通知栏这条路只给得到「当前这一首」的路径；类别页那条给的却是
  /// 「全盘音频列表」。于是恢复出来的播放列表与后台实际在放的队列不一致，
  /// 下一首就跳到「播放列表之外」的歌，用户还会看到「播放列表变了」
  /// （用户反馈 issue #34）。以本快照为准恢复，保证「后台在放什么，列表就是什么」。
  ///
  /// 生命周期：`attach()` 赋值、`detach()` 清空（`attach()` 内部先调 `detach()`，
  /// 所以赋值必须写在它之后）。视频会话（videoSession）不涉及音频队列，恒为 null。
  List<SongModel>? audioSongQueue;

  /// 当前播放项在 [queue] 中的下标，由播放页通过 [updateCurrentItem] 同步。
  ///
  /// ⚠️ 为什么不靠 `queue.value.indexOf(mediaItem.value)`：播放页会用**带封面 artUri**
  /// 的实例覆盖 `mediaItem`（封面是异步取回来的），而 `queue` 里存的是 `attach()` 时
  /// 的**无 artUri** 实例。`MediaItem` 的相等性包含 artUri ⇒ `indexOf` 恒返回 **-1**
  /// ⇒ `skipToNext()` 算出 `(-1 + 1) % n = 0` ⇒ 每次后台切歌都跳回第一首
  /// （这正是 issue #34 里「下一首是播放列表之外的歌」的机制之一）。
  int _queueIndex = 0;

  /// 当前播放的媒体项
  MediaItem? get currentMediaItem => mediaItem.value;

  /// 当前播放路径（来自 MediaItem.id）
  String? get currentPath => mediaItem.value?.id;

  /// 是否有活跃的播放器实例
  bool get hasActivePlayer => _player != null;

  /// 判断指定路径是否正在当前播放器中播放
  bool isPlayingPath(String path) => _player != null && mediaItem.value?.id == path;

  /// 本次视频后台会话的**源路径**（`VideoPlayerScreen.widget.videoPath`）。
  ///
  /// ## 为什么不能只靠 [isPlayingPath]（2026-09-28 真机事故）
  ///
  /// `attach()` 写进 `mediaItem.id` 的是**当时**解析出的播放地址
  /// （`_currentStreamUrl ?? widget.videoPath`）。而 `_currentStreamUrl` 对
  /// 远程/加密视频是**本次会话专属的本地代理 URL**（`http://127.0.0.1:<随机端口>/…`），
  /// 对本地视频也可能在起播后才被赋值。
  ///
  /// 播放页**重进**时判断「是否已在后台播同一视频」用的却是页面自己的
  /// `widget.videoPath` —— 于是拿「源路径」和「曾经的会话 URL」判等：
  /// * 解析完成前重进 ⇒ 两者都是 `widget.videoPath`，判等**成立**（不重复 attach）；
  /// * 解析完成后重进 ⇒ 一个是 `http://127.0.0.1:端口/…`、一个是源路径，判等**不成立**
  ///   ⇒ 每次重进都重复 `attach()`。
  ///
  /// 而 `attach()` 会把 handler 里那个**仍在后台播放**的旧 player 当成
  /// `oldPlayer` 退役（`stop()` + `dispose()`）。反复进出播放页 = 反复
  /// 「销毁仍在播的 player ＋ 挂上刚创建的新 player」，与通知栏 MediaSession、
  /// 上一页尚未跑完的异步清理正面并发 ⇒ `CRASH_NATIVE`（native 崩溃、无栈、
  /// 与硬解/软解无关）。用户复现：「开后台播放后反复进出播放页必崩」。
  ///
  /// ⇒ 用**源路径**做会话身份，判等就成了「同一源 vs 同一源」，跨页面实例稳定。
  ///
  /// 生命周期：`attach()` 里按参数赋值、`detach()` 里清空（同 [videoSession]）。
  String? videoSourcePath;

  /// 是否正在后台播放「同一个视频源」——[source] 传播放页的 `widget.videoPath`。
  ///
  /// 判据（任一成立即算在播同一视频，避免重复 `attach()` 引发的换绑/退役链）：
  /// 1. [videoSourcePath] 相等（跨页面实例稳定，见该字段注释）；
  /// 2. 回退到 [isPlayingPath]：兼容「源路径恰好等于会话地址」的情形
  ///    （本地文件、以及调用方直接把流地址当 `videoPath` 传入的入口）。
  ///
  /// ⚠️ 不要用它取代音频侧的 [isPlayingPath]：音频会话不走本判据。
  bool isPlayingSource(String source) {
    if (_player == null) return false;
    if (source.isEmpty) return false;
    if (videoSourcePath != null && videoSourcePath == source) return true;
    return isPlayingPath(source);
  }

  /// 将当前 MediaItem 持久化为 lastPlayedAudio，确保后台切歌或界面销毁后仍能恢复
  void _persistCurrentMediaItem() {
    final item = mediaItem.value;
    if (item != null && item.id.isNotEmpty) {
      PreferencesService.saveLastPlayedAudio(item.id, item.title, item.artist ?? '');
    }
  }

  // ─── Attach / detach ────────────────────────────────────────────────────

  /// Call this whenever you want background mode to start (or restart with a
  /// new player / queue).
  ///
  /// [persistAsAudio] 默认 true：音频后台播放会持久化 lastPlayedAudio 与
  /// 播放进度，供音频播放器下次恢复。视频进入后台播放时传 false，
  /// 避免视频路径污染音频的"上次播放"记录。
  void attach({
    required Player player,
    required List<MediaItem> queue,
    required int currentIndex,
    bool persistAsAudio = true,
    bool videoSession = false,
    List<SongModel>? songQueue,
    /// 视频后台会话的**源路径**（见 [videoSourcePath]）：用来判断「重复打开同一部
    /// 视频」时是否已在后台播放，避免每次重进都重复 attach（换绑 + 退役仍在播的
    /// 旧 player）——那是反复进出播放页崩溃的触发链。仅 [videoSession] 为 true 时有意义。
    String? videoSourcePath,
  }) {
    final oldPlayer = _player;
    WebdavDebugLog.log(
      '[bg] attach(new=#${identityHashCode(player)}, '
      'old=${oldPlayer == null ? 'null' : '#${identityHashCode(oldPlayer)}'}, '
      'videoSession=$videoSession, fgHeld=$foregroundHoldsPlayer)',
    );
    // ⚠️ 只有「旧 player **本身**已无前台页面持有」时才回收。这里有两个踩过的坑：
    // 1. 判据必须按 player 身份（`isForegroundHeld`）—— 不能用「有没有人持有任意
    //    player」的全局布尔（多播放页叠加时会被别的页面误清，见 `_foregroundPlayer`）；
    // 2. 回收**绝不能**裸 `dispose()`（哪怕丢进 `Future.microtask`）：那是在
    //    mpv 的 AO / 解码线程仍活跃时直接释放 native 上下文，与任何 pending 的
    //    setProperty / open 并发就是 SIGSEGV ⇒ CRASH_NATIVE（Dart 侧无栈）。
    //    统一走 [_retirePlayer]：先 stop 收尾、再 dispose。
    if (oldPlayer != null && oldPlayer != player) {
      if (isForegroundHeld(oldPlayer)) {
        debugPrint('[ZenFile] 跳过回收旧 player：仍被前台页面持有');
        WebdavDebugLog.log('[bg] attach 跳过回收：old 仍被前台页持有');
      } else {
        _retirePlayer(oldPlayer, reason: 'attach-swap');
      }
    }

    detach();
    _player = player;
    // 会话归属（见 videoSession 字段）。⚠️ 必须放在 detach() 之后：detach() 会复位它。
    this.videoSession = videoSession;
    // 视频会话的源路径（见 [videoSourcePath]）。同样必须写在 detach() 之后。
    // 只认视频会话：音频会话下恒为 null，避免音频路径污染本判据。
    this.videoSourcePath = videoSession ? videoSourcePath : null;
    // 原始歌曲队列快照（仅音频会话；见 audioSongQueue）。同样必须写在 detach() 之后。
    audioSongQueue = (videoSession || songQueue == null || songQueue.isEmpty)
        ? null
        : songQueue;
    // 当前下标同步登记，供后台自动切歌使用（见 _queueIndex）。
    _queueIndex = (currentIndex >= 0 && currentIndex < queue.length)
        ? currentIndex
        : 0;

    // Push the queue
    this.queue.add(queue);
    if (queue.isNotEmpty) {
      mediaItem.add(queue[currentIndex]);
      if (persistAsAudio) {
        _persistCurrentMediaItem();
      }
    }

    // Mirror playing state
    _subs.add(player.stream.playing.listen((playing) {
      _emitPlaybackState(playing: playing);
    }));

    // Mirror position（⚠️ 必须节流，理由见 _positionEmitIntervalMs：
    // 每次推送都会让原生主线程重建整条通知，不节流就是 ANR）
    _subs.add(player.stream.position.listen((pos) {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - _lastPositionEmitMs < _positionEmitIntervalMs) return;
      _lastPositionEmitMs = nowMs;
      _emitPlaybackState(playing: _player?.state.playing ?? false, position: pos);
    }));

    // Mirror track completion → advance (only when background, otherwise let screen handle it)
    _subs.add(player.stream.completed.listen((completed) {
      if (completed && _onSkipCallback == null) {
        skipToNext();
      }
    }));

    // 直接 emit 当前播放状态，立即触发通知栏显示
    _emitPlaybackState(playing: player.state.playing);

    // 后台播放期间定期保存进度，即使界面被销毁也能记住位置
    // （仅音频后台模式启用，视频不写入音频播放记录）
    if (persistAsAudio) {
      _positionSaveTimer?.cancel();
      _positionSaveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final path = mediaItem.value?.id;
        final pos = _player?.state.position;
        if (path != null && pos != null && pos.inMilliseconds > 1000) {
          PreferencesService.savePlaybackPosition(path, pos.inMilliseconds);
        }
      });
    }

    // ── 申请通知栏权限（安卓13+ 必须，否则系统拦截通知不显示）──
    unawaited(_requestNotificationPermission());
  }

  /// 申请通知栏权限（安卓 13+ 必须，否则系统拦截通知不显示）。
  /// permission_handler 会自动按版本处理：安卓 12- 返回已授予不弹框，
  /// 安卓 13+ 才弹系统授权框。低版本与已授权时直接跳过，绝不阻塞播放器启动。
  Future<void> _requestNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await Permission.notification.status;
      if (status.isDenied) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[ZenFile] request notification permission failed: $e');
    }
    // 申请忽略电池优化 + 唤醒锁，防止后台播放被系统中断
    _ensurePowerManagement();
  }

  /// 确保电源管理优化：请求忽略电池优化 + 申请唤醒锁。
  /// 首次播放时调用，不阻塞音频启动。
  Future<void> _ensurePowerManagement() async {
    if (!Platform.isAndroid) return;
    try {
      // 检查并请求电池优化白名单
      final ignoring = await PowerManagementService.isIgnoringBatteryOptimizations();
      if (!ignoring && !PreferencesService.getBatteryOptDismissed()) {
        await PowerManagementService.requestIgnoreBatteryOptimizations();
      }
      // 申请唤醒锁保持 CPU 运行
      await PowerManagementService.acquireWakeLock();
    } catch (e) {
      debugPrint('[ZenFile] power management setup failed: $e');
    }
  }

  void detach() {
    if (_player != null) {
      WebdavDebugLog.log(
        '[bg] detach(#${identityHashCode(_player!)}, videoSession=$videoSession)',
      );
    }
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _player = null;
    // 会话结束：归属标志一并复位，避免下一次会话沿用上一次的归属
    videoSession = false;
    // 视频源路径一并复位（下一次会话由 attach() 重新赋值；不复位会让
    // isPlayingSource 把「上一部视频」误判成仍在播）
    videoSourcePath = null;
    // 队列快照与下标一并复位（下一次会话由 attach() 重新赋值）
    audioSongQueue = null;
    _queueIndex = 0;
    // 通知推送状态一并复位 —— 若不复位，下次 attach 后「playing / position 恰好与
    // 上一次相同」的首次推送会被 _emitPlaybackState 的去重逻辑吞掉 ⇒ 通知栏不出现。
    _lastPositionEmitMs = 0;
    _lastEmittedPlaying = null;
    _lastEmittedPosition = null;
  }

  /// 当用户开始播放视频时调用：立即暂停正在播放的后台音频，避免两路声音混在一起。
  /// 仅暂停不销毁播放器，返回音频播放页时仍可恢复原进度。
  void pauseForVideo() {
    final p = _player;
    if (p != null && p.state.playing) {
      p.pause();
    }
  }

  // ─── AudioHandler overrides ─────────────────────────────────────────────

  @override
  Future<void> play() async {
    await _player?.play();
  }

  @override
  Future<void> pause() async {
    await _player?.pause();
  }

  @override
  Future<void> stop() async {
    _positionSaveTimer?.cancel();
    _positionSaveTimer = null;
    playbackState.add(PlaybackState(
      controls: [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));

    // 只有「彻底停止」才回收；前台页面仍持有 player 时（视频后台播放且播放页
    // 未退出）只清通知，否则会把页面正在用的对象销毁 ⇒ use-after-free。
    // 回收同样走 [_retirePlayer]（先 stop 再 dispose），绝不裸 dispose。
    final playerToDispose = _player;
    if (playerToDispose != null && !isForegroundHeld(playerToDispose)) {
      // ⚠️ 必须 await：只有旧实例真正 stop + dispose 完，新实例才能安全 open。
      // 「两个 mpv 实例同时活着」（各自持有 AudioTrack、独立音频会话号、
      // `demuxer-max-bytes=300M` 缓冲）正是反复进出播放页的崩溃现场
      // （2026-09-28 真机日志：第 3-4 次进出时 3-4 个实例并存）。
      await _retirePlayer(playerToDispose, reason: 'stop');
    }

    detach();
    await super.stop();
  }

  /// Clears and dismisses the background media notification completely,
  /// but keeps the active player alive for foreground playback.
  void stopNotification() {
    playbackState.add(PlaybackState(
      controls: [],
      playing: false,
      processingState: AudioProcessingState.idle,
    ));
    detach();
  }

  /// 接管后台会话：先把当前后台 player 解绑通知栏，再**优雅退役**，然后返回。
  ///
  /// ## 为什么必须有（2026-09-28 真机崩溃的现场结论）
  ///
  /// 视频后台播放开着时，用户「退出播放页 → 重新进入」会新建一个 mpv 实例。上一版
  /// 修法是让重进时**静默跳过 attach**（为了不换绑退役），结果后台会话被第一个实例
  /// **永久霸占**：既不退役、也没有页面再引用它，于是每进出一次就多一个存活的 mpv
  /// 实例（各自 AudioTrack + 音频会话号 + `demuxer-max-bytes=300M` 缓冲），真机日志
  /// 里第 3-4 次进出即原生崩溃（`CRASH_NATIVE`、无 trace，与硬解/软解无关）。
  ///
  /// 正解是**接管**：新页面进场时把旧会话显式退役，保证任一时刻只有一个实例。
  /// 退役走 [_retirePlayer]（abandon → stop → dispose，串行去重）并且**可 await**，
  /// 所以新实例不会与旧实例的销毁并发。
  ///
  /// ⚠️ 旧 player 仍被某个前台页面持有时（[isForegroundHeld]）**只解绑通知栏、不退役**
  /// —— 那个页面还要继续用它解码，由它负责释放（见 `_foregroundPlayer` 注释）。
  Future<void> takeOverBackgroundSession({required String reason}) async {
    final p = _player;
    if (p == null) return;
    final held = isForegroundHeld(p);
    WebdavDebugLog.log(
      '[bg] takeOver($reason, #${identityHashCode(p)}) 仍被前台持有=$held',
    );
    // 先摘通知栏（只 emit idle + detach，不 dispose），再退役旧实例。
    stopNotification();
    if (held) return;
    await _retirePlayer(p, reason: reason);
  }

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
    // 拖动后立刻把新进度反映到通知栏，不受 position 节流影响。
    _lastPositionEmitMs = 0;
  }

  @override
  Future<void> skipToNext() async {
    final q = queue.value;
    if (q.isEmpty) return;
    final nextIdx = _advanceIndex(q, 1);
    final nextItem = q[nextIdx];
    _queueIndex = nextIdx;
    mediaItem.add(nextItem);
    _persistCurrentMediaItem();

    if (_onSkipCallback != null) {
      _onSkipCallback?.call(nextIdx);
    } else {
      if (_player != null) {
        await _player!.open(Media(nextItem.id), play: true);
      }
    }
  }

  @override
  Future<void> skipToPrevious() async {
    final q = queue.value;
    if (q.isEmpty) return;
    final prevIdx = _advanceIndex(q, -1);
    final prevItem = q[prevIdx];
    _queueIndex = prevIdx;
    mediaItem.add(prevItem);
    _persistCurrentMediaItem();

    if (_onSkipCallback != null) {
      _onSkipCallback?.call(prevIdx);
    } else {
      if (_player != null) {
        await _player!.open(Media(prevItem.id), play: true);
      }
    }
  }

  /// 计算「下一首 / 上一首」在队列中的下标（[step] 为 +1 / -1，循环取模）。
  ///
  /// 优先用 [updateCurrentItem] 同步进来的 [_queueIndex]；只有当它越界、或它指向的
  /// 媒体项与当前播放项对不上（播放页刚重建、还没同步）时，才退回**按 id 匹配**定位。
  ///
  /// ⚠️ **绝不能**用 `q.indexOf(mediaItem.value)`：播放页拿到封面后会用一个带
  /// `artUri` 的新 `MediaItem` 覆盖当前项，而队列里存的是无 `artUri` 的旧实例，
  /// `MediaItem` 相等性包含 artUri ⇒ `indexOf` 恒为 -1 ⇒ 每次都跳第一首（issue #34）。
  int _advanceIndex(List<MediaItem> q, int step) {
    final curId = mediaItem.value?.id;
    var idx = _queueIndex;
    if (idx < 0 || idx >= q.length || (curId != null && q[idx].id != curId)) {
      final found = curId == null ? -1 : q.indexWhere((m) => m.id == curId);
      idx = found >= 0 ? found : 0;
    }
    return (idx + step + q.length) % q.length;
  }

  // ─── Callback for skip (screen must update player) ──────────────────────

  void Function(int index)? _onSkipCallback;

  void setSkipCallback(void Function(int index)? cb) {
    _onSkipCallback = cb;
  }

  /// Update the current media item displayed in the notification.
  ///
  /// [index] 是该曲目在队列中的下标 —— **务必传**，它是后台自动切歌时唯一可靠的
  /// 位置依据（见 [_queueIndex]：不能靠 `indexOf`，封面更新会让 `MediaItem` 实例不等）。
  void updateCurrentItem(MediaItem item, {int? index}) {
    if (index != null && index >= 0) {
      _queueIndex = index;
    }
    mediaItem.add(item);
    _persistCurrentMediaItem();
  }

  /// Re-emit the current playback state without re-attaching the player.
  /// Used as a safety net when the first emit may have failed to create
  /// the foreground notification (e.g. startForeground race / permission delay).
  void reattachState() {
    final player = _player;
    if (player != null) {
      _emitPlaybackState(playing: player.state.playing);
    }
  }

  // ─── Private helpers ─────────────────────────────────────────────────────

  void _emitPlaybackState({
    required bool playing,
    Duration? position,
  }) {
    final currentPos = position ?? _player?.state.position ?? Duration.zero;
    // 去重：playing 与 position 都没变时不再推送 —— 每次 playbackState.add 都会经
    // MethodChannel 到原生主线程重建通知，冗余推送正是 ANR（无响应）的直接来源。
    if (_lastEmittedPlaying == playing && _lastEmittedPosition == currentPos) {
      return;
    }
    _lastEmittedPlaying = playing;
    _lastEmittedPosition = currentPos;
    // 通知「停止」按钮的无障碍文案随应用语言变化；拿不到 context 时回落中文，
    // 避免在 runApp 之前/无 Navigator 的场景抛异常。
    final stopLabelCtx = navigatorKey.currentContext;
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl(
            androidIcon: 'drawable/audio_service_stop',
            label: stopLabelCtx == null
                ? '关闭'
                : L10n.of(stopLabelCtx).ui_close,
            action: MediaAction.stop,
          ),
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: playing,
        updatePosition: currentPos,
        bufferedPosition: currentPos,
        speed: _player?.state.rate ?? 1.0,
      ),
    );
  }
}
