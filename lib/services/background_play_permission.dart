import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import '../l10n/generated/app_localizations.dart';
import 'audio_background_handler.dart';

/// 后台播放共用的「通知权限申请」与「通知栏是否真的生效」诊断。
///
/// 音频播放器与视频播放器共用同一份实现，保证两端的提示文案与判定口径完全一致。
/// 2026-09-27 用户反馈：视频开启后台播放后不像音频那样提示开启通知权限，
/// 于是把音频侧的这套逻辑抽出来共用。
class BackgroundPlayPermission {
  BackgroundPlayPermission._();

  /// 媒体通知的 audio_service 配置（音频/视频共用同一个通知渠道）。
  static const _audioServiceConfig = AudioServiceConfig(
    androidNotificationChannelId: 'com.sequl.zenfile.audio.v2',
    androidNotificationChannelName: 'ZenFile Audio Player',
    // ⚠️ 同上（`main.dart` 的 AudioService.init）：必须指向已登记在
    // `res/raw/keep.xml` 的通知小图标，否则会被 shrinkResources 裁掉导致 setSmallIcon(0)。
    androidNotificationIcon: 'drawable/ic_stat_zenfile',
    androidShowNotificationBadge: true,
    androidStopForegroundOnPause: false,
    androidNotificationClickStartsActivity: false,
    notificationColor: Color(0xFF6200EE),
  );

  /// 申请通知权限（安卓 13+ 必填，否则系统直接拦掉媒体通知；低版本不会弹框）。
  ///
  /// * 返回 `true` —— 已授予，调用方可以继续把 player 挂到通知栏；
  /// * 返回 `false` —— 未授予，**已经**弹出「需要通知权限…」提示（带「去设置」按钮），
  ///   调用方必须直接 return，否则 attach 完通知栏不会出现任何控件。
  static Future<bool> ensureGranted(BuildContext context) async {
    bool granted = true;
    try {
      final status = await Permission.notification.request();
      granted = status.isGranted;
    } catch (e) {
      debugPrint('[ZenFile] Error requesting notification permission: $e');
      granted = false;
    }
    if (granted) return true;
    if (!context.mounted) return false;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(L10n.of(context).msg_notification_permission_denied),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: L10n.of(context).msg_open_settings,
          textColor: Colors.white,
          onPressed: () async {
            await openAppSettings();
          },
        ),
      ),
    );
    return false;
  }

  /// 诊断通知栏是否真的生效。
  ///
  /// `audio_service` 在部分 ROM 上「不抛错但通知不显示」（前台服务启动失败、
  /// 通知渠道被禁用、电池优化限制等），必须主动检测并提示用户，
  /// 否则用户只会看到「开了后台播放但通知栏什么都没有」。
  ///
  /// 检查顺序：
  /// 1. 媒体通知链路是否初始化成功（失败则通知完全不可能显示，尝试重初始化一次）；
  /// 2. 通知权限是否真的授予（部分 ROM 下 `request()` 不弹窗却直接返回拒绝）；
  /// 3. `playbackState` 是否含控件（为空说明前台服务没注册上）；
  /// 4. 通知渠道是否存在且启用（Android 8+ 渠道被设为 IMPORTANCE_NONE 时不显示）。
  ///
  /// [isActive] 通常传 `() => mounted` —— 诊断延迟 1.5s 执行，期间页面可能已销毁。
  /// [onReattach] 媒体通知链路重初始化成功后重新挂载播放器（传 null 表示跳过）。
  static Future<void> diagnose(
    BuildContext context, {
    required bool Function() isActive,
    Future<void> Function()? onReattach,
  }) async {
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!isActive()) return;

    try {
      // 1. 媒体通知链路是否初始化成功（安卓 13+ 走 Media3 桥接，低版本走 audio_service）
      if (!isAudioServiceInitialized) {
        bool reInitOk = false;
        try {
          await AudioService.init(
            builder: () => getAudioHandler(),
            config: _audioServiceConfig,
          );
          isAudioServiceInitialized = true;
          reInitOk = true;
          debugPrint('[ZenFile] Media notification re-init succeeded');
        } catch (e) {
          debugPrint('[ZenFile] Media notification re-init failed: $e');
        }

        if (!reInitOk) {
          if (!isActive()) return;
          _show(context, L10n.of(context).msg_audio_service_init_failed);
          return;
        }

        // 重初始化成功后需要重新 attach：之前的 attach 可能没注册到 Media3 桥接
        if (onReattach != null && isActive()) {
          await onReattach();
        }
        await Future.delayed(const Duration(milliseconds: 800));
        if (!isActive()) return;
      }

      // 2. 复检通知权限
      final notifStatus = await Permission.notification.status;
      if (!notifStatus.isGranted) {
        if (!isActive()) return;
        _show(
          context,
          L10n.of(context).msg_notification_not_granted,
          openSettings: true,
        );
        return;
      }

      // 3. 检查 playbackState 是否包含控件（空 ⇒ 前台服务注册失败，通常是 ROM 限制）
      if (getAudioHandler().playbackState.value.controls.isEmpty) {
        if (!isActive()) return;
        _show(
          context,
          L10n.of(context).msg_notification_blocked_hint,
          openSettings: true,
        );
        return;
      }

      // 4. 检查通知渠道是否被系统或用户禁用（Android 8+）
      if (Platform.isAndroid) {
        try {
          const channel = MethodChannel('com.sequl.zenfile/notifications');
          final result = await channel.invokeMethod<Map>(
            'checkAudioChannelStatus',
          );
          if (result != null) {
            final exists = result['exists'] as bool? ?? true;
            final enabled = result['enabled'] as bool? ?? true;
            if (!exists) {
              // 渠道不存在 —— audio_service 可能没有正确创建渠道
              if (isActive() && isAudioServiceInitialized) {
                _show(
                  context,
                  L10n.of(context).msg_notification_blocked_hint,
                  openSettings: true,
                );
              }
              return;
            }
            if (!enabled) {
              // 渠道存在但被禁用 —— 用户在系统设置里关掉了通知渠道
              if (!isActive()) return;
              _show(
                context,
                L10n.of(context).msg_notification_channel_disabled,
                openSettings: true,
              );
              return;
            }
          }
        } catch (e) {
          debugPrint('[ZenFile] checkAudioChannelStatus error: $e');
          // 原生方法调用失败，不阻塞诊断流程
        }
      }
    } catch (e) {
      debugPrint('[ZenFile] Notification diagnosis error: $e');
    }
  }

  /// 诊断失败提示：橙底、8 秒、可带「去设置」按钮。
  static void _show(
    BuildContext context,
    String message, {
    bool openSettings = false,
  }) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.deepOrange,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        action: openSettings
            ? SnackBarAction(
                label: L10n.of(context).msg_open_settings,
                textColor: Colors.white,
                onPressed: () async {
                  await openAppSettings();
                },
              )
            : null,
      ),
    );
  }
}
