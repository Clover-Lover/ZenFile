import 'dart:async';
import 'dart:io';
import 'package:audio_service/audio_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import '../ui/screens/audio_player/audio_artwork_widget.dart';
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
  /// 调用方无需 await（fire-and-forget，不阻塞当前操作）。
  void _retirePlayer(Player p, {required String reason}) {
    if (_retiring.contains(p)) {
      WebdavDebugLog.log('[bg] retire($reason, #${identityHashCode(p)}) 已在队列，跳过');
      return;
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

  /// 当前播放的媒体项
  MediaItem? get currentMediaItem => mediaItem.value;

  /// 当前播放路径（来自 MediaItem.id）
  String? get currentPath => mediaItem.value?.id;

  /// 是否有活跃的播放器实例
  bool get hasActivePlayer => _player != null;

  /// 判断指定路径是否正在当前播放器中播放
  bool isPlayingPath(String path) => _player != null && mediaItem.value?.id == path;

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

    // Mirror position
    _subs.add(player.stream.position.listen((pos) {
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
      _retirePlayer(playerToDispose, reason: 'stop');
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

  @override
  Future<void> seek(Duration position) async {
    await _player?.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    final q = queue.value;
    final current = mediaItem.value;
    if (q.isEmpty || current == null) return;
    final idx = q.indexOf(current);
    final nextIdx = (idx + 1) % q.length;
    final nextItem = q[nextIdx];
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
    final current = mediaItem.value;
    if (q.isEmpty || current == null) return;
    final idx = q.indexOf(current);
    final prevIdx = (idx - 1 + q.length) % q.length;
    final prevItem = q[prevIdx];
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

  // ─── Callback for skip (screen must update player) ──────────────────────

  void Function(int index)? _onSkipCallback;

  void setSkipCallback(void Function(int index)? cb) {
    _onSkipCallback = cb;
  }

  /// Update the current media item displayed in the notification.
  void updateCurrentItem(MediaItem item) {
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
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          const MediaControl(
            androidIcon: 'drawable/audio_service_stop',
            label: '关闭',
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
