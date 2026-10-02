import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'package:crypto/crypto.dart' as crypto;
import 'package:shared_preferences/shared_preferences.dart';

import 'crypt/scrypt.dart';

/// 保险箱中的一个加密条目（纯 UI 模型，不再持久化）。
///
/// 实际密文由 rclone crypt 落在 `vault_crypt/` 沙盒目录，解密/加解密
/// 全部由 [VaultCryptService] 承担；本类只用于列表渲染与预览/恢复时的
/// 路径传递。
class VaultFileRecord {
  /// 稳定标识（沙盒条目的物理路径拼装，用于列表去重与删除匹配）
  final String id;

  /// 解密后的文件名
  final String originalName;

  /// 加密前的原始路径（来自来源映射；无记录时为沙盒内虚拟路径）
  final String originalPath;

  /// 沙盒中的密文物理路径
  final String scrambledPath;

  /// 解密后的文件大小
  final int size;

  /// 密文最后修改时间（ISO 8601），列表详情用
  final String lockedAt;

  /// 是否为目录
  final bool isFolder;

  VaultFileRecord({
    required this.id,
    required this.originalName,
    required this.originalPath,
    required this.scrambledPath,
    required this.size,
    required this.lockedAt,
    this.isFolder = false,
  });
}

/// 保险箱解锁门禁服务（解锁密码 / 指纹凭据）。
///
/// ## 职责边界（重要）
/// 本服务**只负责「进入保险箱界面」这一步的密码校验**，不参与任何加解密。
/// 沙盒加密与原地加密一律使用「加密设置」中的主密码 + 盐，
/// 见 [VaultCryptService]。因此修改解锁密码是**瞬时操作**，
/// 不会重新加密、也不会影响任何已加密文件。
///
/// ## 与远程守卫 PIN 的关系
/// [RemoteGuardService] 复用本服务的凭据（isPinSet / setPin / verifyPin /
/// changePin 全部委托到这里），故「修改 PIN 码」即修改保险箱解锁密码。
///
/// ## 历史沿革
/// 旧版（V1/V2/V3）把解锁密码同时当作文件加密密钥，改密需逐条重加密；
/// 该格式已彻底移除。门禁凭据沿用 `vault_salt` / `vault_password_hash`
/// 两个键：历史记录为 `sha256(password + salt)`，可无感解锁；校验通过后
/// 自动透明升级为 `scrypt`（见 `vault_password_scheme`），新设密码一律
/// 使用 scrypt，防止 6 位数字 PIN 被快速穷举。
class VaultService {
  static const String _kSalt = 'vault_salt';
  static const String _kHash = 'vault_password_hash';

  /// 旧版 V2/V3 全局校验令牌键（仅用于识别「升级用户」，不再参与校验）
  static const String _kLegacyV2PwCheck = 'vault_v2_pwcheck';

  static final Random _secureRandom = Random.secure();

  /// 本次启动进程内是否已通过保险箱解锁验证（内存态，**重启即失效**）。
  ///
  /// 用途：作为「执行加密相关操作前必须验证一次」的会话闸门。
  /// 用户每次重启应用后，第一次触达加密文件的操作（打开 / 重命名 / 复制 /
  /// 移动 / 删除 / 粘贴等）都会弹窗验证保险箱密码；本次会话内已解锁过的，
  /// 后续操作不再重复弹窗。
  ///
  /// ⚠️ 刻意不持久化：持久化会让「重启也必须验证一次」的诉求失效。
  static bool _sessionUnlocked = false;

  /// 是否已在本次会话（进程启动后）解锁过保险箱。
  static bool get isSessionUnlocked => _sessionUnlocked;

  /// 标记本次会话已解锁（在保险箱解锁成功时调用）。
  static void markSessionUnlocked() => _sessionUnlocked = true;

  /// 重置会话解锁状态（例如应用进入后台锁定 / 锁屏后调用，可选）。
  static void resetSessionUnlock() => _sessionUnlocked = false;

  /// 是否已设置解锁密码
  static Future<bool> isPasswordSet() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.containsKey(_kHash);
  }

  /// 是否为「从旧版升级、尚未重设解锁密码」的状态。
  ///
  /// 旧版可能只有 V2/V3 校验令牌而没有门禁凭据（V2 起密码只写
  /// `vault_v2_*`）。此时需要引导用户重新设置一个解锁密码 ——
  /// 由于门禁与加密已完全解耦，重设**不会**影响任何加密文件。
  static Future<bool> needsUnlockPasswordReset() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(_kHash)) return false;
    return prefs.containsKey(_kLegacyV2PwCheck);
  }

  /// 设置解锁密码（首次设置或重设）
  static Future<void> setPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = base64Encode(_randomBytes(16));
    final hash = await _scryptHash(password, salt);
    await prefs.setString(_kSalt, salt);
    await prefs.setString(_kHash, hash);
    await prefs.setString(_kScheme, _kSchemeScrypt);
  }

  /// 校验解锁密码
  ///
  /// 旧版门禁哈希是单轮 sha256（可被快速穷举），这里对新密码统一使用
  /// scrypt（内存困难）派生；发现存量 sha256 记录且密码验证通过时，
  /// 透明升级为 scrypt，用户无感知。
  static Future<bool> verifyPassword(String password) async {
    final prefs = await SharedPreferences.getInstance();
    final salt = prefs.getString(_kSalt);
    final hash = prefs.getString(_kHash);
    if (salt == null || hash == null) return false;
    final scheme = prefs.getString(_kScheme) ?? _kSchemeLegacySha256;
    if (scheme == _kSchemeScrypt) {
      return hash == await _scryptHash(password, salt);
    }
    final legacyOk = hash == _legacyHash(password, salt);
    if (legacyOk) {
      // 静默升级：旧 sha256 记录 → scrypt
      try {
        await setPassword(password);
      } catch (_) {
        // 升级失败不影响本次解锁结果
      }
    }
    return legacyOk;
  }

  /// 修改解锁密码。
  ///
  /// ⚠️ 与旧版不同：**不再**重新加密任何文件（旧版每条记录都要用新密码
  /// 重加密，是大文件卡顿与「改密失败即丢数据」的根源）。现在只是一次
  /// SharedPreferences 写入，瞬时完成。
  ///
  /// 返回 false 表示旧密码校验失败。
  static Future<bool> changePassword(String oldPassword, String newPassword) async {
    if (!await verifyPassword(oldPassword)) return false;
    await setPassword(newPassword);
    return true;
  }

  /// 门禁哈希方案标识
  static const String _kScheme = 'vault_password_scheme';
  static const String _kSchemeLegacySha256 = 'sha256';
  static const String _kSchemeScrypt = 'scrypt-v1';

  /// 旧版门禁哈希：sha256(password + salt)
  ///
  /// 仅用于校验存量记录（历史 `vault_salt` / `vault_password_hash`），
  /// 新写入一律走 [_scryptHash]。
  static String _legacyHash(String password, String salt) =>
      crypto.sha256.convert(utf8.encode(password + salt)).toString();

  /// scrypt 门禁哈希（N=16384, r=8, p=1，内存困难，6 位数字 PIN 无法秒级穷举）。
  ///
  /// scrypt 在主 isolate 执行会卡 UI（约需 16MB 内存 + 数十毫秒），
  /// 因此放入独立 isolate 计算。
  static Future<String> _scryptHash(String password, String salt) async {
    return Isolate.run(() {
      final derived = scrypt(
        utf8.encode(password),
        utf8.encode(salt),
        N: 16384,
        r: 8,
        p: 1,
        keyLength: 32,
      );
      return base64Encode(derived);
    });
  }

  static List<int> _randomBytes(int n) =>
      List<int>.generate(n, (_) => _secureRandom.nextInt(256));
}
