// ─────────────────────────────────────────────────────────────────────────────
// 本地文件 / 文件夹「创建时间」的统一解析入口（issue #39）
//
// 为什么必须自己调 libc —— Android 上想拿到「真正的创建时间」，公开 Java / Kotlin
// API 是没有的，以下候选均已逐一核验（compileSdk 37 的 android.jar + NDK 28）：
//   · android.system.Os          → 只有 stat / lstat / fstat，没有 statx
//   · android.system.StructStat   → 只有 st_atim / st_mtim / st_ctim，没有 birthtime
//   · android.system.StructStatx  → 不存在；OsConstants 里也没有任何 STATX_* 常量
//   · java.nio BasicFileAttributes.creationTime()
//        → 在 Android 上等于 mtime，这正是预发行版「创建时间 = 修改时间」的原因
//   · MediaStore 的 DATE_ADDED
//        → 只索引「文件」、不索引「文件夹」⇒ v3.4.0 里文件夹那一行整行消失（本次回归）
//
// 唯一可靠来源是文件系统的 birth time，只能走 libc 的 statx(2) + STATX_BTIME。
// bionic 自 API 30（Android 11）起导出 statx：NDK 的 sys/stat.h 明确标注
// __INTRODUCED_IN(30)，API30 的 libc.so 符号表里也确认有该符号（NDK 28 实证）。
// 本工程 minSdk = 24 ⇒ API 24–29 上本模块整体静默失效，由调用方回退到 MediaStore。
//
// ⚠️ struct statx 布局按 NDK linux/stat.h 逐字段算出（偏移见下方常量注释），
// 并在运行时用 stx_mtime 与 Dart 侧 stat 出来的修改时间做**交叉自校验**：
// 对不上即说明布局与内核 ABI 不符 ⇒ 直接放弃，宁可没有也不显示可疑值。
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'webdav_debug_log.dart';

/// 「创建时间」实际取自哪一路（仅供诊断 / 日志）。
enum BirthTimeSource { filesystem, mediaStore, none }

/// 本地文件 / 文件夹「创建时间」解析。详见文件头注释。
class FileBirthTimeService {
  FileBirthTimeService._();

  // ── statx(2) ABI 常量（取自 NDK sysroot 的 linux/stat.h） ─────────────
  static const int _atFdcwd = -100; // AT_FDCWD
  static const int _statxBtime = 0x800; // STATX_BTIME
  static const int _statxAll = 0xfff; // STATX_ALL = BASIC_STATS | BTIME

  // struct statx 的字节偏移（按 linux/stat.h 字段顺序累加，LP64）：
  //   stx_mask u32 @0     stx_blksize u32 @4    stx_attributes u64 @8
  //   stx_nlink u32 @16   stx_uid u32 @20       stx_gid u32 @24
  //   stx_mode u16 @28    __spare0 u16 @30
  //   stx_ino u64 @32     stx_size u64 @40      stx_blocks u64 @48
  //   stx_attributes_mask u64 @56
  //   四个 statx_timestamp，各 16B（s64 tv_sec + u32 tv_nsec + s32 __reserved）：
  //   stx_atime @64   stx_btime @80   stx_ctime @96   stx_mtime @112
  //   其余字段补齐到 256B
  static const int _stxMaskOff = 0;
  static const int _stxBtimeSecOff = 80;
  static const int _stxBtimeNsecOff = 88;
  static const int _stxMtimeSecOff = 112;
  static const int _stxMtimeNsecOff = 120;
  static const int _statxSize = 256;

  /// 布局自校验容差：stx_mtime 与 Dart 侧 stat 的修改时间差异超过它就判定布局不符。
  static const Duration _layoutTolerance = Duration(seconds: 3);

  static bool _probed = false;
  static _StatxFn? _statx;
  static _MallocFn? _malloc;
  static _FreeFn? _free;

  /// 最近一次 [resolve] 实际命中的来源（诊断用）。
  static BirthTimeSource lastSource = BirthTimeSource.none;

  /// 解析「创建时间」：文件系统 birth time 优先，取不到再回退 MediaStore DATE_ADDED。
  /// 两路都拿不到时返回 null（调用方据此隐藏该行）。
  static Future<DateTime?> resolve(
    String path, {
    DateTime? knownModified,
  }) async {
    if (path.isEmpty) {
      lastSource = BirthTimeSource.none;
      return null;
    }
    final DateTime? fromFs = birthTime(path, expectModified: knownModified);
    DateTime? fromStore;
    if (fromFs == null) {
      fromStore = await _mediaStoreDateAdded(path);
    }
    final DateTime? result = fromFs ?? fromStore;
    if (fromFs != null) {
      lastSource = BirthTimeSource.filesystem;
    } else if (result != null) {
      lastSource = BirthTimeSource.mediaStore;
    } else {
      lastSource = BirthTimeSource.none;
    }
    // 真机取证用：一眼看出这次「创建时间」走的哪一路（enabled=false 时为 no-op）
    WebdavDebugLog.log('[created] source=${lastSource.name} path=$path');
    return result;
  }

  /// 文件系统的真实创建时间（statx 的 STATX_BTIME）。
  ///
  /// 返回 null 的情形（一律由调用方回退 / 隐藏，绝不猜）：非 Android 平台、
  /// API < 30（bionic 无 statx）、路径不存在或无权访问、文件系统不提供 btime
  /// （`stx_mask` 未置 STATX_BTIME，如部分 FAT32 外置卡）、结构体布局自校验失败。
  static DateTime? birthTime(String path, {DateTime? expectModified}) {
    if (path.isEmpty) return null;
    _probe();
    final _StatxFn? statx = _statx;
    final _MallocFn? malloc = _malloc;
    final _FreeFn? free = _free;
    if (statx == null || malloc == null || free == null) return null;

    final Pointer<Void> buf = malloc(_statxSize);
    final List<int> pathBytes = utf8.encode(path);
    final Pointer<Void> cPath = malloc(pathBytes.length + 1);
    if (buf == nullptr || cPath == nullptr) {
      if (buf != nullptr) free(buf);
      if (cPath != nullptr) free(cPath);
      return null;
    }
    try {
      cPath
          .cast<Uint8>()
          .asTypedList(pathBytes.length + 1)
        ..setRange(0, pathBytes.length, pathBytes)
        ..[pathBytes.length] = 0;

      // flags = 0（AT_STATX_SYNC_AS_STAT）；失败多为路径不存在 / 无权限 / 内核不支持
      if (statx(_atFdcwd, cPath, 0, _statxAll, buf) != 0) return null;

      final ByteData bd =
          ByteData.sublistView(buf.cast<Uint8>().asTypedList(_statxSize));

      // ── 布局自校验：内核填的 stx_mtime 必须与 Dart 侧 stat 的修改时间一致，
      //    否则说明我们对 struct statx 的偏移理解有误 ⇒ 放弃，绝不返回可疑值。
      if (expectModified != null) {
        final int mSec = bd.getInt64(_stxMtimeSecOff, Endian.host);
        final int mNsec = bd.getUint32(_stxMtimeNsecOff, Endian.host);
        if (mSec > 0) {
          final DateTime layoutMtime = DateTime.fromMillisecondsSinceEpoch(
            mSec * 1000 + mNsec ~/ 1000000,
          );
          if (layoutMtime.difference(expectModified).abs() > _layoutTolerance) {
            return null;
          }
        }
      }

      // 文件系统未提供 btime（例如部分 FAT32 外置卡）时该位为 0
      final int mask = bd.getUint32(_stxMaskOff, Endian.host);
      if ((mask & _statxBtime) == 0) return null;

      final int sec = bd.getInt64(_stxBtimeSecOff, Endian.host);
      final int nsec = bd.getUint32(_stxBtimeNsecOff, Endian.host);
      if (sec <= 0) return null;
      final DateTime created =
          DateTime.fromMillisecondsSinceEpoch(sec * 1000 + nsec ~/ 1000000);
      if (created.isAfter(DateTime.now().add(const Duration(days: 1)))) {
        return null;
      }
      return created;
    } catch (_) {
      return null;
    } finally {
      free(buf);
      free(cPath);
    }
  }

  /// 原地解析 libc 的 statx / malloc / free，失败则永久停在回退路径。
  static void _probe() {
    if (_probed) return;
    _probed = true;
    // 桌面 / flutter test 环境下没有这些符号，也不必碰
    if (!Platform.isAndroid) return;
    for (final String? name in const <String?>['libc.so', null]) {
      try {
        final DynamicLibrary lib =
            name == null ? DynamicLibrary.process() : DynamicLibrary.open(name);
        _statx = lib.lookupFunction<_StatxNative, _StatxFn>('statx');
        _malloc = lib.lookupFunction<_MallocNative, _MallocFn>('malloc');
        _free = lib.lookupFunction<_FreeNative, _FreeFn>('free');
        return;
      } catch (_) {
        // API < 30 的 bionic 不导出 statx ⇒ 换下一个来源；都失败就整体失效
      }
    }
    _statx = null;
    _malloc = null;
    _free = null;
  }

  /// 原生 MediaStore 的 DATE_ADDED（毫秒）。只索引文件、**不索引文件夹**，
  /// 因此文件夹必然取不到；通道未注册（旧包）或任何异常同样返回 null。
  static Future<DateTime?> _mediaStoreDateAdded(String path) async {
    try {
      const MethodChannel channel =
          MethodChannel('com.sequl.zenfile/root_shizuku');
      final dynamic raw = await channel.invokeMethod<dynamic>(
        'getFileCreationTime',
        <String, dynamic>{'path': path},
      );
      final int millis = raw is int ? raw : 0;
      final int upper =
          DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch;
      if (millis > 0 && millis <= upper) {
        return DateTime.fromMillisecondsSinceEpoch(millis);
      }
    } catch (_) {
      // 旧包（通道未注册）/ 任何异常 ⇒ 视为取不到
    }
    return null;
  }
}

// ── FFI 函数签名 ─────────────────────────────────────────────────────────
// int statx(int dirfd, const char *path, int flags, unsigned mask,
//           struct statx *buf)
typedef _StatxNative = Int32 Function(
  Int32 dirfd,
  Pointer<Void> path,
  Int32 flags,
  Uint32 mask,
  Pointer<Void> buf,
);
typedef _StatxFn = int Function(
  int dirfd,
  Pointer<Void> path,
  int flags,
  int mask,
  Pointer<Void> buf,
);

typedef _MallocNative = Pointer<Void> Function(IntPtr size);
typedef _MallocFn = Pointer<Void> Function(int size);

typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeFn = void Function(Pointer<Void> ptr);
