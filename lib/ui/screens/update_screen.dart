import 'dart:async';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import '../../core/icon_fonts/broken_icons.dart';
import '../../services/apk_installer_service.dart';
import '../../services/net_proxy_service.dart';
import '../../services/preferences_service.dart';
import '../../services/update_check_service.dart';
import '../../services/webdav_debug_log.dart';

/// 「版本更新」全屏页面（入口在左抽屉：设置 与 关于ZenFile 之间）。
///
/// 结构：
/// ① GitHub 版本检测卡片 —— 打开页面自动检测一次，失败/想重查可手动重试；
///    发现新版本后按设备 ABI 匹配 Release 资产，应用内下载并走统一安装链路
///    [ApkInstallerService.installApk]（含 VirusTotal 扫描等既有逻辑）；
///    同时展示该 Release 的**更新日志**（可滚动查看 + 一键复制，方便用户自行翻译）。
/// ② 网盘下载链接（自「关于」页迁移）。
/// ③ 当前版本更新日志（自「关于」页迁移，硬编码中英双语）。
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

enum _CheckState { checking, latest, hasUpdate, failed }

class _UpdateScreenState extends State<UpdateScreen> {
  static const String _releasePageUrl =
      'https://github.com/l930203811/ZenFile/releases/latest';

  _CheckState _state = _CheckState.checking;
  String _currentVersion = '';

  /// 远端最新 tag（如 `v2.1.7`）。**「已是最新」时也展示它** ——
  /// 用户据此分辨「真的联网查到了」还是「失败被静默吞掉」。
  String _remoteVersion = '';
  String _pageUrl = _releasePageUrl;
  List<UpdateAsset> _assets = const <UpdateAsset>[];

  /// 远端 Release 的更新日志正文（Markdown 原文）。
  /// 只有 API 通道拿得到；网页降级通道为空 ⇒ 界面显示 [update_changelog_empty]。
  String _releaseNotes = '';

  /// 失败原因与 HTTP 状态码（决定提示文案；旧实现所有失败共用一句通用文案）。
  UpdateCheckError? _error;
  int? _httpStatus;

  /// 是否用过降级通道（网页 302）。用过 ⇒ 界面标注「无法应用内下载」。
  bool _usedFallback = false;

  /// 最近一次检测完成的时间。
  DateTime? _checkedAt;

  /// 自定义更新源（镜像 / 自建接口）地址；空 = GitHub 官方源。
  String _apiUrlOverride = '';

  bool _downloading = false;
  double? _downloadProgress; // null = 服务器未给 contentLength，用不确定进度条

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _apiUrlOverride = PreferencesService.getUpdateApiUrl();
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
    } catch (_) {
      _currentVersion = '';
    }
    await _check();
  }

  Future<void> _check() async {
    setState(() {
      _state = _CheckState.checking;
      _assets = const <UpdateAsset>[];
    });

    // 检测逻辑已抽到 [UpdateCheckService]（可注入、可单测）。旧实现写在 State 里，
    // 于是「没有真实新版本就永远测不了」「失败原因分不出来」两件事无解。
    // 关键修复（都在 service 里）：读响应体带超时、整次检测有总上限、
    // 拿不到本机版本号不再谎报「已是最新」、失败按原因分类、多通道自动降级。
    final result = await UpdateCheckService(
      apiUrlOverride: _apiUrlOverride,
      httpProxyProvider: NetProxyService.getHttpProxy,
      logger: WebdavDebugLog.log,
    ).check(_currentVersion);

    if (!mounted) return;
    setState(() {
      _remoteVersion = result.remoteVersion;
      _pageUrl = result.pageUrl.isNotEmpty ? result.pageUrl : _releasePageUrl;
      _assets = result.assets;
      // GitHub 的 release body 是 CRLF 原文，统一成 LF：Flutter 的 Text 对
      // `\r\n` 会多渲染一个空行，正文里每行之间都被拉开。
      _releaseNotes = result.releaseNotes.replaceAll('\r\n', '\n');
      _error = result.error;
      _httpStatus = result.httpStatus;
      _usedFallback = result.usedFallback;
      _checkedAt = DateTime.now();
      if (!result.ok) {
        _state = _CheckState.failed;
      } else {
        _state = result.hasUpdate ? _CheckState.hasUpdate : _CheckState.latest;
      }
    });
  }

  /// 按设备 ABI 选择最匹配的 APK 资产；无匹配则回退到第一个 .apk。
  Future<String?> _pickAssetUrl() async {
    if (_assets.isEmpty) return null;
    final abis = <String>[];
    if (Platform.isAndroid) {
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        abis.addAll(info.supportedAbis);
      } catch (_) {}
    }
    for (final abi in abis) {
      for (final a in _assets) {
        if (a.name.contains(abi)) return a.url;
      }
    }
    for (final a in _assets) {
      if (a.name.endsWith('.apk')) return a.url;
    }
    return null;
  }

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    final url = await _pickAssetUrl();
    if (url == null) {
      // 没有可下载资产（例如降级到了网页通道）→ 退回浏览器打开 Release 页
      await _openUrl(_pageUrl);
      return;
    }
    setState(() {
      _downloading = true;
      _downloadProgress = 0;
    });
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client
          .getUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 15));
      req.headers.set(HttpHeaders.userAgentHeader, 'ZenFile-Update-Checker');
      final resp = await req.close().timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        throw HttpException('HTTP ${resp.statusCode}');
      }
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/ZenFile_update_$_remoteVersion.apk');
      final sink = file.openWrite();
      final total = resp.contentLength; // -1 表示未知
      var received = 0;
      // 下载同样要有超时：半开连接会让 `await for` 永远挂着（与检测同源的问题，
      // 在这里表现为「进度条永远停在某个百分比、也不报错」）。
      await for (final chunk in resp.timeout(
        const Duration(seconds: 30),
        onTimeout: (sink) => sink.addError(TimeoutException('download stalled')),
      )) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0 && mounted) {
          setState(() => _downloadProgress = received / total);
        }
      }
      await sink.flush();
      await sink.close();
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadProgress = null;
      });
      // 走统一安装链路（VirusTotal 扫描开关、系统安装器等逻辑与文件管理器一致）
      await ApkInstallerService.installApk(context, file.path);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloadProgress = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(L10n.of(context).update_download_failed),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      client.close();
    }
  }

  Future<void> _openUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  /// 把更新日志正文整段写进剪贴板 —— 用户常需要拿到原文去翻译 / 转发。
  ///
  /// 只复制正文（不带「发现新版本 vX」之类的界面文案），这样粘出去的就是
  /// 干净的 release notes。
  Future<void> _copyChangelog() async {
    if (_releaseNotes.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final l10n = L10n.of(context);
    await Clipboard.setData(ClipboardData(text: _releaseNotes));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.msg4fb42e6e), // 「已复制到剪贴板」
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 清除「已忽略该版本」标记，让下次启动重新弹窗提示。
  Future<void> _restoreIgnoredPrompt() async {
    await PreferencesService.saveIgnoredUpdateVersion('');
    if (!mounted) return;
    setState(() {});
  }

  /// 当前显示的远端版本是否已被用户「忽略」（即启动弹窗不会再提示它）。
  ///
  /// 判据与 [main.dart] 的启动弹窗**完全一致**（走同一个存储键、同一个比较），
  /// 否则会出现「这里说已忽略、启动却还弹」这种自相矛盾。
  bool _isRemoteIgnored() {
    if (_remoteVersion.isEmpty) return false;
    return UpdateCheckService.isVersionIgnored(
      _remoteVersion,
      PreferencesService.getIgnoredUpdateVersion(),
    );
  }

  /// 失败提示：按原因分类。
  ///
  /// 旧实现所有失败共用一句「检查更新失败，请检查网络连接后重试」——
  /// 用户既分不清是没网、超时，还是被 GitHub 限速（未认证 60 次/小时/IP，
  /// 国内共享出口极易触发），也就无从采取正确的下一步。
  String _errorText(L10n l10n) {
    switch (_error) {
      case UpdateCheckError.network:
        return l10n.update_err_network;
      case UpdateCheckError.timeout:
        return l10n.update_err_timeout;
      case UpdateCheckError.rateLimited:
        return l10n.update_err_rate_limit;
      case UpdateCheckError.http:
        return l10n.update_err_http('${_httpStatus ?? '?'}');
      case UpdateCheckError.malformed:
        return l10n.update_err_malformed;
      case UpdateCheckError.versionUnknown:
        return l10n.update_err_version_unknown;
      case UpdateCheckError.unknown:
      case null:
        return l10n.update_check_failed;
    }
  }

  /// 「已是最新」时的自证信息：远端实际 tag + 本次检查时间。
  String _metaLine(L10n l10n) {
    final parts = <String>[];
    if (_remoteVersion.isNotEmpty) {
      parts.add(l10n.update_remote_version(_remoteVersion));
    }
    final t = _checkedAt;
    if (t != null) {
      final hh = t.hour.toString().padLeft(2, '0');
      final mm = t.minute.toString().padLeft(2, '0');
      parts.add(l10n.update_checked_at('$hh:$mm'));
    }
    return parts.join(' · ');
  }

  /// 自定义更新源（镜像 / 自建接口）。
  ///
  /// 留空 = GitHub 官方接口。校验规则直接复用
  /// [UpdateCheckService.isValidCustomUrl]，不在 UI 里再写一遍。
  Future<void> _openSourceDialog() async {
    final l10n = L10n.of(context);
    final theme = Theme.of(context);
    final controller = TextEditingController(text: _apiUrlOverride);

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (_, value, __) {
          final valid = UpdateCheckService.isValidCustomUrl(value.text);
          return AlertDialog(
            title: Text(l10n.update_source_dialog_title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.update_source_dialog_desc,
                    style: const TextStyle(fontSize: 12.5, height: 1.5)),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  maxLines: 2,
                  minLines: 1,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(
                    hintText: l10n.update_source_hint,
                    hintStyle: const TextStyle(fontSize: 12),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (!valid) ...[
                  const SizedBox(height: 8),
                  Text(l10n.update_source_invalid,
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(MaterialLocalizations.of(ctx).cancelButtonLabel),
              ),
              TextButton(
                // 地址非法时直接禁用「确定」，比让它失败一次再报错更清楚
                onPressed: valid ? () => Navigator.pop(ctx, true) : null,
                child: Text(MaterialLocalizations.of(ctx).okButtonLabel),
              ),
            ],
          );
        },
      ),
    );

    final value = controller.text.trim();
    controller.dispose();
    if (saved != true) return;

    await PreferencesService.saveUpdateApiUrl(value);
    if (!mounted) return;
    setState(() => _apiUrlOverride = value);
    await _check();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.ui_view_update),
        centerTitle: true,
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _buildGitHubCheckCard(theme, l10n),
          const SizedBox(height: 16),
          _buildDownloadLinksCard(theme, l10n),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.msg305734ce,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          _buildChangelogList(theme, l10n),
        ],
      ),
    );
  }

  // ── ① GitHub 版本检测 ──────────────────────────────────────────────

  Widget _buildGitHubCheckCard(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            theme.colorScheme.primary.withOpacity(0.08),
            theme.colorScheme.secondary.withOpacity(0.04),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: theme.colorScheme.primary.withOpacity(0.15)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Broken.refresh,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.update_github_check,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurface.withOpacity(0.9),
                  ),
                ),
              ),
              if (_state != _CheckState.checking && !_downloading)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: l10n.update_retry,
                  icon: Icon(Broken.refresh_2,
                      size: 18, color: theme.colorScheme.primary),
                  onPressed: _check,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            l10n.update_current_version(
                _currentVersion.isEmpty ? '—' : _currentVersion),
            style: TextStyle(
              fontSize: 13,
              color: theme.colorScheme.onSurface.withOpacity(0.6),
              fontFamily: 'LexendDeca',
            ),
          ),
          const SizedBox(height: 4),
          // 更新源：刻意放在本页而不是设置页 —— 它是「版本更新」专属配置，
          // 改完可立刻重试，也让用户一眼看清当前是不是走了镜像。
          GestureDetector(
            onTap: _openSourceDialog,
            behavior: HitTestBehavior.opaque,
            child: Row(
              children: [
                Icon(Icons.cloud_outlined,
                    size: 13, color: theme.colorScheme.onSurface.withOpacity(0.45)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '${l10n.update_source_label} · '
                    '${_apiUrlOverride.isEmpty ? l10n.update_source_default : l10n.update_source_custom}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onSurface.withOpacity(0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _buildCheckStatus(theme, l10n),
        ],
      ),
    );
  }

  Widget _buildCheckStatus(ThemeData theme, L10n l10n) {
    switch (_state) {
      case _CheckState.checking:
        return Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(width: 10),
            Text(l10n.update_checking,
                style: TextStyle(
                    fontSize: 13.5,
                    color: theme.colorScheme.onSurface.withOpacity(0.75))),
          ],
        );
      case _CheckState.latest:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.check_circle_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(l10n.update_latest,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: theme.colorScheme.onSurface.withOpacity(0.85))),
                ),
              ],
            ),
            // 「已是最新」必须能自证：显示远端实际 tag 与检查时间，用户才能分辨
            // 「真的联网查到了」还是「请求失败被静默吞掉」。
            if (_metaLine(l10n).isNotEmpty) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.only(left: 26),
                child: Text(
                  _metaLine(l10n),
                  style: TextStyle(
                      fontSize: 11.5,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                ),
              ),
            ],
          ],
        );
      case _CheckState.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline_rounded,
                    size: 18, color: theme.colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_errorText(l10n),
                      style: TextStyle(
                          fontSize: 13.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.85))),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _check,
                  icon: const Icon(Broken.refresh_2, size: 16),
                  label: Text(l10n.update_retry),
                ),
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: () => _openUrl(_releasePageUrl),
                  icon: Icon(Icons.open_in_new,
                      size: 14,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  label: Text(
                    l10n.update_view_github,
                    style: TextStyle(
                        fontSize: 12.5,
                        color: theme.colorScheme.onSurface.withOpacity(0.6)),
                  ),
                ),
              ],
            ),
          ],
        );
      case _CheckState.hasUpdate:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.new_releases_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.update_new_version(_remoteVersion),
                    style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.primary),
                  ),
                ),
              ],
            ),
            // 降级到网页通道时拿不到 assets ⇒ 只能跳浏览器。
            // 这里如实说明，避免用户以为「下载安装」按钮坏了。
            if (_usedFallback && _assets.isEmpty) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(Icons.info_outline_rounded,
                      size: 14,
                      color: theme.colorScheme.onSurface.withOpacity(0.5)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.update_degraded_hint,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                  ),
                ],
              ),
            ],
            // 用户曾在启动弹窗里点过「忽略」⇒ 给他一个恢复入口
            // （否则「不再弹窗」是个不可逆操作，点错了没法挽回）。
            if (_isRemoteIgnored()) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  Icon(
                    Icons.notifications_off_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      l10n.update_ignored_hint,
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _restoreIgnoredPrompt,
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    child: Text(
                      l10n.ui_restore_default,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            _buildChangelogBlock(theme, l10n),
            const SizedBox(height: 12),
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _downloadProgress,
                borderRadius: BorderRadius.circular(4),
              ),
              const SizedBox(height: 6),
              Text(
                _downloadProgress == null
                    ? l10n.update_downloading
                    : '${l10n.update_downloading} ${(_downloadProgress! * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                    fontSize: 12.5,
                    color: theme.colorScheme.onSurface.withOpacity(0.6)),
              ),
            ] else
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _downloadAndInstall,
                    icon: const Icon(Broken.document_download, size: 16),
                    label: Text(l10n.update_download_install),
                  ),
                  const SizedBox(width: 10),
                  TextButton.icon(
                    onPressed: () => _openUrl(_pageUrl),
                    icon: Icon(Icons.open_in_new,
                        size: 14,
                        color: theme.colorScheme.onSurface.withOpacity(0.5)),
                    label: Text(
                      l10n.update_view_github,
                      style: TextStyle(
                          fontSize: 12.5,
                          color: theme.colorScheme.onSurface.withOpacity(0.6)),
                    ),
                  ),
                ],
              ),
          ],
        );
    }
  }

  // ── ①.5 远端 Release 的更新日志（查看 + 复制） ──────────────────────

  /// 远端 Release 的更新日志：可滚动查看（正文可选中）+ 一键复制。
  ///
  /// 为什么按纯文本呈现而不是渲染 Markdown：**这个功能不值得新增依赖**（pubspec
  /// 是红线）。GitHub 的 release notes 本身就是 Markdown 原文，原样展示既不失真，
  /// 也正好方便用户整段复制出去翻译 —— 那才是本区块的主要用途。
  Widget _buildChangelogBlock(ThemeData theme, L10n l10n) {
    final hasNotes = _releaseNotes.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              Icons.article_outlined,
              size: 15,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l10n.msg305734ce, // 「更新日志」
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (hasNotes)
              TextButton.icon(
                onPressed: _copyChangelog,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                icon: Icon(
                  Broken.copy,
                  size: 14,
                  color: theme.colorScheme.primary,
                ),
                label: Text(
                  l10n.ui_copy,
                  style: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          // ⚠️ 高度必须有界：外层是本页的 ListView，这里再套滚动容器时若不给
          // maxHeight，会直接抛「Vertical viewport was given unbounded height」。
          constraints: const BoxConstraints(maxHeight: 220),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            ),
          ),
          child: hasNotes
              ? Scrollbar(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      _releaseNotes,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.8,
                        ),
                      ),
                    ),
                  ),
                )
              : Text(
                  // 网页降级通道拿不到正文 ⇒ 明确告知，而不是给一块空白。
                  l10n.update_changelog_empty,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
        ),
      ],
    );
  }

  // ── ② 网盘下载链接（自「关于」页迁移） ──────────────────────────────

  Widget _buildDownloadLinksCard(ThemeData theme, L10n l10n) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.download_rounded,
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Text(l10n.zenfilev1041,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface.withOpacity(0.9))),
            ],
          ),
          const SizedBox(height: 12),
          _buildDownloadLink(theme, l10n.msg9d287020, 'https://1820255615.share.123pan.cn/123pan/WrRojv-JHpnA?pwd=hBR2', Icons.cloud_outlined),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msgb2b41b6a, 'https://115cdn.com/s/swsho4j3hc6?password=m490', Icons.cloud_queue),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msg77ee718b, 'https://pan.baidu.com/s/1kYSfzTriRXwQPRL_c5Awig?pwd=xg94', Icons.cloud_circle),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msgbff1432a, 'https://pan.quark.cn/s/e6081a88d463', Icons.cloud),
          const SizedBox(height: 8),
          _buildDownloadLink(theme, l10n.msge03395d0, 'https://mypikpak.com/s/VOxGdQB3fVNO32sq_I3o2Wkmo2', Icons.flight),
        ],
      ),
    );
  }

  Widget _buildDownloadLink(ThemeData theme, String name, String url, IconData icon) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _openUrl(url),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withOpacity(0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.onSurface.withOpacity(0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18, color: theme.colorScheme.primary.withOpacity(0.7)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: theme.colorScheme.onSurface.withOpacity(0.85)),
              ),
            ),
            Icon(Icons.open_in_new, size: 14, color: theme.colorScheme.onSurface.withOpacity(0.35)),
          ],
        ),
      ),
    );
  }

  // ── ③ 更新日志（自「关于」页迁移，硬编码中英双语，不走 l10n） ──────
  //
  // 2026-09-28 改版（用户要求）：
  //   · **不再「只留当前版本一张卡片」** —— 旧版本日志**保留**，只是默认**折叠**；
  //   · 当前版本**始终展开**（用户要求「新版本日志不要折叠」）；
  //   · 每张卡片**各带一个复制按钮**，把该版中英双语全文复制为**纯文本** ——
  //     用户常需要粘到别处（翻译工具 / 聊天 / 论坛）阅读；
  //   · 界面与复制文本**同源**（都自 [_Changelog] 生成）⇒ 不会出现
  //     「界面改了、复制出去的还是旧文案」这种偏移。
  //
  // 换版时只做两件事：① 在 [_changelogs] **最前面**插入新版本的 [_Changelog]；
  // ② 把 [_latestChangelogVersion] 改成新版本号。其余卡片会自动变为折叠态。

  /// 当前版本（那张始终展开、不可折叠的卡片）的版本号。
  static const String _latestChangelogVersion = 'v3.4.0';

  /// 全部版本的更新日志，**最新在最前**。
  static const List<_Changelog> _changelogs = <_Changelog>[_v340, _v330, _v320];

  /// ── 当前版本：v3.4.0 ────────────────────────────────────────────────
  static const _Changelog _v340 = _Changelog(
    version: 'v3.4.0',
    date: '2026-09-30',
    zh: [
      _ChangeSection('✨ 新功能', [
        '文件 / 文件夹「属性」对话框新增「创建时间」一行（类似 MiXplorer）：取自 MediaStore 加入时间（DATE_ADDED），与「修改时间」来源不同、绝大多数文件天然不相等；分类页属性页也已补齐这一行',
        '多任务剪贴板（issue #36）：复制 / 剪切现在累计为多个任务，面板用分割线区分，每个任务可单独粘贴 / 删除；远程（FTP / SMB / WebDAV）任务一并纳入，最多保留 20 个',
        '文件属性新增「计算哈希值」按钮：点击后才流式计算 MD5 / SHA-256（非打开属性即算），本地文件可用，大文件也只占少量内存',
        '分类页属性对话框对文件夹显示「包含 N 子文件夹 / M 文件」（与浏览页一致），并统计其总大小',
        '底部 4-tab 可常驻其他页面（默认开启）：从抽屉、分类、「最近」等入口进入的页面同样保留底部导航栏，随时切换标签；进入视频播放 / 图片查看的沉浸态时自动收起，唤出控制条或操作按钮时恢复（设置 → 常规与行为 → 导航栏中可关闭）',
        '时间与日期格式可自定义（issue #38）：日期支持 DD/MM/YYYY、MM/DD/YYYY、YYYY-MM-DD 三种格式，时间支持 12 / 24 小时制，选择后整个应用统一生效',
        '「显示三点操作按钮」设置方式优化：打开开关即弹出模式选择（全部显示 / 仅单窗口 / 仅双窗口），选完自动收起，不再内联展开占位',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '分类页（视频、音频、图片、文档、下载、截图、压缩包、安装包）的多选操作栏，与浏览页、「最近」页改用同一套按钮组件',
        '开启「隐藏操作栏文字标签」后，上述所有分类页的多选操作栏现在都会同步隐藏文字、只显示图标，与浏览页 /「最近」页习惯一致',
        '「更多」操作（分享、详情、收藏等）在隐藏文字标签时同样只显示图标，不再露出文字',
        '剪贴板面板底部改为「清除（窄）+ 粘贴全部（右侧）」，粘贴全部按每任务勾选状态决定保留 / 清除；面板顶部标题已移除，更紧凑',
        '设置页「时间与日期格式」与「在列表中隐藏时间和日期」合并为「时间与日期显示」单一条目，点开弹出合并面板（日期 / 时间格式选择 + 隐藏开关）',
        '远程添加向导的协议卡片改为单行卡片（图标 + 标题 + 描述 + 右箭头），纵向排列、点选区域更大，整体风格统一',
        '分类页多选时，操作栏改为覆盖并收起底部导航栏，不再叠在它上方',
      ]),
      _ChangeSection('🛠️ 维护优化', [
        '将操作栏按钮渲染逻辑抽离为共用的 ActionBarButton 组件，浏览页与分类页共享同一份隐藏文字 / 配色 / 尺寸规则，后续只改一处',
        '剪贴板面板每个任务拥有独立的「清除」与「粘贴后保留」勾选，粘贴后默认自动清除该任务（复制不勾选则清除、剪切始终清除）',
        '远程添加向导的协议选项改为复用同一套卡片组件，后续调整只需改一处',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复「隐藏操作栏文字标签」设置对分类页（除「最近」外）不生效的问题',
        '修复新增的 4 个备用图标（蓝白 / 渐变蓝 / 深蓝鎏金 / 暮色）在设置中切换不生效的问题',
        '修复时间 / 日期格式选择弹窗点不中：选中状态被反复重置，选项永远停在默认值',
        '修复「时间与日期格式」「显示三点操作按钮」的开关点不动，只能整行点击弹窗',
        '修复远程连接（SMB 等）切到别的页面再回来就连不上、必须重启应用：重连判定补齐 socket 超时类错误，返回目录时自动重建连接',
        '修复远程文件列表的日期不跟随「时间与日期格式」设置',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'The file / folder "Properties" dialog now shows a "Creation Time" row (like MiXplorer): sourced from MediaStore DATE_ADDED, a different clock from "Modified" so they differ for most files; the category-page properties dialog now shows this row too',
        'Multi-task clipboard (issue #36): copy / cut now accumulate into separate tasks, divided by dividers in the panel, each pannable and deletable on its own; remote (FTP / SMB / WebDAV) tasks are included too, up to 20 kept',
        'The file "Properties" dialog now has a "Calculate Hash" button: MD5 / SHA-256 are computed on demand (streaming, not at open) for local files, using little memory even for large files',
        'The category-page properties dialog now shows "N subfolder(s) / M file(s)" for folders (matching the Browse page) and their total size',
        'The bottom 4-tab bar can now stay visible on other pages (on by default): pages opened from the drawer, categories or Recent keep the bottom navigation so tabs are always reachable; it slides away when you enter immersive video playback or image viewing, and returns when the controls are shown (can be turned off in Settings -> General & Behavior -> Navigation bar)',
        'Customizable date & time format (issue #38): pick DD/MM/YYYY, MM/DD/YYYY or YYYY-MM-DD, and 12- or 24-hour time; the choice applies across the whole app',
        '"Show the three-dot action button" is easier to set up now: turning the switch on pops up the mode picker (Always / Single pane only / Dual pane only) and closes itself once chosen',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'The multi-select action bar of category pages (Video, Audio, Image, Document, Downloads, Screenshots, Archives, APK) now shares the same button widget as the Browse and Recent pages',
        'With "Hide action bar text labels" on, those category pages now also hide the text and show icons only, matching the Browse and Recent pages',
        'The "More" overflow (Share, Details, Favorite, etc.) also shows icon only when labels are hidden',
        'Clipboard panel bottom is now "Clear (narrow) + Paste All (right)"; Paste All respects each task keep-after-paste choice; the top title was removed for a more compact panel',
        'In Settings, "Date & Time Format" and "Hide time and date in list" are merged into a single "Date & Time Display" item that opens a combined sheet (date / time format pickers + hide toggle)',
        'Protocol cards in the Add Remote wizard are now single-row cards (icon + title + description + arrow), stacked vertically with a bigger tap area and a consistent look',
        'In category pages, the multi-select action bar now covers and hides the bottom navigation bar instead of stacking above it',
      ]),
      _ChangeSection('🛠️ Maintenance', [
        'Extracted the action bar button into a shared ActionBarButton widget so the Browse and Category pages use one source of truth for label-hiding, color and sizing',
        'In the clipboard panel each task has its own "Clear" and "Keep after paste" toggle; after pasting a task is cleared by default (copy without the toggle is cleared, cut is always cleared)',
        'Protocol options in the Add Remote wizard now reuse one shared card widget, so future changes are made in a single place',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed "Hide action bar text labels" having no effect on category pages (except Recent)',
        'Fixed the 4 newly added alternative icons (Blue-White / Gradient-Blue / Blue-Gold / Sunset) not taking effect when selected in Settings',
        'Fixed the date / time format picker not being selectable: the selection was reset on every rebuild and always fell back to the default',
        'Fixed the "Date & Time Format" and "Show three-dot action button" switches not being tappable - only tapping the whole row worked',
        'Fixed remote connections (SMB etc.) becoming unreachable after switching pages until the app was restarted: the reconnect check now recognizes socket-timeout errors and rebuilds the connection automatically',
        'Fixed remote file lists not following the "Date & Time Format" setting',
      ]),
    ],
  );

  /// ── 上一版：v3.3.0 ─────────────────────────────────────────────────
  static const _Changelog _v330 = _Changelog(
    version: 'v3.3.0',
    date: '2026-09-28',
    zh: [
      _ChangeSection('✨ 新功能', [
        '剪贴板粘贴后可选「保留剪贴板」或「自动清空」，并记住上次的选择',
        '双窗口剪切新增「剪切到另一窗口」与「剪切到剪贴板」',
        '新建文件夹后自动进入该文件夹（设置内可关闭）',
        '存储空间 / 应用管理的扫描结果本地缓存，重开页面秒出，下拉刷新才重新统计',
        '「版本更新」页可查看并一键复制更新日志；启动时发现新版本会弹窗提醒，可忽略该版本',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '底部导航「传输」改名为「连接」，「网络」改名为「远程」，图标同步更新（10 种语言）',
        '剪贴板「粘贴后保留」勾选项改为整行可点，不再只有小方框点得中',
        '多选操作栏不再被底部导航栏遮挡',
        '设置新增「新建文件夹自动打开」开关',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复播放 / 切歌时闪退：通知栏小图标被资源裁剪，导致没有有效图标',
        '修复通知栏进度刷新过于频繁造成的「无响应」（ANR）',
        '修复后台播放：切歌偶尔跳到播放列表之外、断开耳机后音乐不暂停',
        '修复反复进出视频播放页的闪退（后台播放会话改为接管退役，同一时刻只保留一个播放实例）',
        '修复播放器事件订阅未释放，反复进出播放页时监听层层叠加',
        '修复存储分析 / 应用管理点刷新仍是旧数据、必须重启应用才正确',
        '修复已删除的崩溃报告被自动补回',
        '修复双窗口复制 / 剪切后文件列表空白',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Clipboard: after pasting you may keep the clipboard or clear it automatically, and the choice is remembered',
        'Dual-pane cut now offers "Cut to the other pane" and "Cut to clipboard"',
        'New folders open automatically right after creation (can be turned off in Settings)',
        'Storage and Apps scan results are cached, so reopening the page is instant; pull to refresh to re-scan',
        'The Version Update page shows the changelog with one-tap copy, and a dialog appears on startup when a new version is found (the version can be ignored)',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'Bottom navigation: "Transfer" renamed to "Connections" and "Network" renamed to "Remote", with matching new icons (10 languages)',
        'The clipboard "keep after paste" option is now tappable across the whole row, not just the small checkbox',
        'The multi-select action bar is no longer covered by the bottom navigation bar',
        'New "Open new folder automatically" switch in Settings',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed crashes while playing or skipping tracks: the notification small icon was stripped by resource shrinking',
        'Fixed "not responding" (ANR) caused by notification progress being refreshed too often',
        'Fixed background playback: skipping a track could land outside the playlist, and unplugging headphones did not pause playback',
        'Fixed crashes when repeatedly entering and leaving the video player (the background session now takes over and retires the old player, keeping only one instance alive)',
        'Fixed player event subscriptions never being cancelled, which piled up listeners when entering the player repeatedly',
        'Fixed Storage / Apps showing stale numbers after a refresh until the app was restarted',
        'Fixed deleted crash reports being restored automatically',
        'Fixed blank file lists after copy or cut in dual-pane mode',
      ]),
    ],
  );

  /// ── 上一版：v3.2.0（原文案原样保留，不再删除，改为折叠展示）──────────
  static const _Changelog _v320 = _Changelog(
    version: 'v3.2.0',
    date: '2026-09-28',
    zh: [
      _ChangeSection('✨ 新功能', [
        '目录加解密采用多核并行处理，速度提升约 2 倍',
        '视频后台播放支持随时开启与关闭（带提示），首次开启引导通知权限，开启后播放页不再退出',
        '音频播放器进度条常驻显示，支持倍速 / 音量记忆',
        '图片查看器新增宽度 / 高度 / 原始三态显示切换',
        '应用图标新增 4 款：浅灰纸纹、磨砂金属、蓝色文件夹、深蓝鎏金；深蓝鎏金设为默认图标，原默认图标转为备选「经典图标」',
      ]),
      _ChangeSection('🎨 界面与交互', [
        '新增「传输」页面：网络、FTP 共享、Web 共享入口迁入；「我的」页面入口保留',
        '收藏夹改为底部半屏面板，可从底部上滑唤起，附带使用提示',
        '导航栏显示 / 位置整合为统一入口并双向同步，默认显示在底部；分类页与浏览页顶部背景统一',
        '单 / 双窗口切换按钮点击后自动跳转文件浏览页',
      ]),
      _ChangeSection('🐛 问题修复', [
        '修复后台播放、切换软硬解码、退出播放等场景下的偶发闪退',
        '互联网分享链接修复：不再被管理后台地址顶替、不再卡在占位，多节点隧道自动切换',
        '修复「最近」页打开本地文件被误判为远程文件而无法打开的问题',
        '远程缩略图改为按顺序单文件加载并限制带宽，打开远程目录不再卡顿、占用大量流量',
        'SAF 提示与新增界面文案全部支持多语言',
      ]),
    ],
    en: [
      _ChangeSection('✨ New Features', [
        'Directory encryption/decryption now runs on multiple CPU cores in parallel — up to ~2x faster',
        'Video background playback can be toggled on/off anytime (with a toast), guides notification permission on first use, and the player page no longer closes',
        'Audio player: seek bar always visible, playback speed and volume remembered',
        'Image viewer: new fit modes — fit width / fit height / original size',
        '4 new app icons: Light Gray Paper, Frosted Metal, Blue Folder and Blue Gold; Blue Gold is now the default icon, and the original default becomes the "Classic Icon" alternative',
      ]),
      _ChangeSection('🎨 UI & Interaction', [
        'New "Transfer" page hosting Network, FTP Sharing and Web Sharing entries; the "Mine" page entry is kept',
        'Favorites is now a bottom half-screen panel, swipe up from the bottom edge to open, with a usage hint',
        'Navigation bar visibility and position merged into one setting with two-way sync, defaulting to the bottom; unified top backgrounds for Categories and Browse pages',
        'The single/dual-pane toggle now jumps to the file browser first',
      ]),
      _ChangeSection('🐛 Bug Fixes', [
        'Fixed occasional crashes when toggling background playback, switching hardware/software decoding, or leaving the player',
        'Internet sharing link fixed: no longer hijacked by the dashboard address or stuck at the placeholder; auto-fallback between multiple tunnel nodes',
        'Fixed "Recent" page misidentifying local files as remote and failing to open them',
        'Remote thumbnails now load one file at a time with a bandwidth cap, so opening remote folders no longer lags or eats bandwidth',
        'SAF prompts and all new UI copy are now fully translated',
      ]),
    ],
  );

  /// 折叠状态：旧版本卡片默认收起，键为版本号（如 `v3.2.0`）。
  final Set<String> _expandedOldChangelogs = <String>{};

  void _toggleOldChangelog(String version) {
    setState(() {
      if (!_expandedOldChangelogs.remove(version)) {
        _expandedOldChangelogs.add(version);
      }
    });
  }

  /// 把某版本的更新日志（中英双语）复制成**纯文本**。
  ///
  /// 与屏幕展示同源（都从 [_Changelog] 生成）⇒ 粘出去的内容不会跟界面走偏；
  /// 不带任何界面文案，粘出去就是干净的 release notes。
  Future<void> _copyChangelogText(L10n l10n, _Changelog data) async {
    final buffer = StringBuffer()
      ..writeln('ZenFile ${data.version} (${data.date})')
      ..writeln();
    void writeSections(List<_ChangeSection> sections) {
      for (var k = 0; k < sections.length; k++) {
        if (k > 0) buffer.writeln();
        buffer.writeln(sections[k].title);
        for (final it in sections[k].items) {
          buffer.writeln('\u00b7 $it');
        }
      }
    }

    writeSections(data.zh);
    buffer
      ..writeln()
      ..writeln('---------------- English ----------------')
      ..writeln();
    writeSections(data.en);

    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: buffer.toString().trimRight()));
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(l10n.msg4fb42e6e), // 「已复制到剪贴板」
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 全部版本的更新日志列表：最新版展开，其余折叠。
  Widget _buildChangelogList(ThemeData theme, L10n l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final c in _changelogs)
          _buildChangelogCard(
            theme: theme,
            l10n: l10n,
            data: c,
            collapsible: c.version != _latestChangelogVersion,
          ),
      ],
    );
  }

  /// 一张更新日志卡片。
  ///
  /// [collapsible] 为 true = 旧版本（默认收起，点标题行展开）；
  /// false = 当前版本（始终展开，不给折叠入口）。
  Widget _buildChangelogCard({
    required ThemeData theme,
    required L10n l10n,
    required _Changelog data,
    required bool collapsible,
  }) {
    final expanded =
        !collapsible || _expandedOldChangelogs.contains(data.version);
    final textStyle = TextStyle(
      fontSize: 13.5,
      height: 1.6,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
    );
    final dividerColor = theme.colorScheme.onSurface.withValues(alpha: 0.15);

    Widget item(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text('\u00b7 $text', style: textStyle),
        );
    Widget section(String title) => Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 4),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 14,
              height: 1.6,
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
    Widget divider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Container(height: 1, color: dividerColor),
        );
    Widget langDivider() => Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Row(
            children: [
              Expanded(child: Container(height: 1, color: dividerColor)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  'English',
                  style: TextStyle(
                    fontSize: 12,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ),
              Expanded(child: Container(height: 1, color: dividerColor)),
            ],
          ),
        );

    /// 一个语言的全部分区（区间插分隔线）。
    List<Widget> sectionsOf(List<_ChangeSection> sections) {
      final out = <Widget>[];
      for (var k = 0; k < sections.length; k++) {
        if (k > 0) out.add(divider());
        out.add(section(sections[k].title));
        for (final t in sections[k].items) {
          out.add(item(t));
        }
      }
      return out;
    }

    final copyButton = IconButton(
      onPressed: () => _copyChangelogText(l10n, data),
      tooltip: l10n.ui_copy,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(4),
      constraints: const BoxConstraints(),
      icon: Icon(Broken.copy, size: 16, color: theme.colorScheme.primary),
    );

    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text(
            data.version,
            style: TextStyle(
              color: theme.colorScheme.primary,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'LexendDeca',
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          data.date,
          style: TextStyle(
            fontSize: 12,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.06),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!collapsible)
            Row(
              children: [title, const Spacer(), copyButton],
            )
          else
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _toggleOldChangelog(data.version),
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          title,
                          const Spacer(),
                          Icon(
                            expanded
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 20,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.55),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                copyButton,
              ],
            ),
          if (expanded) ...[
            const SizedBox(height: 14),
            ...sectionsOf(data.zh),
            langDivider(),
            ...sectionsOf(data.en),
          ],
        ],
      ),
    );
  }
}

/// 更新日志里的一个分区（标题 + 若干条目）。
class _ChangeSection {
  const _ChangeSection(this.title, this.items);

  final String title;
  final List<String> items;
}

/// 一个版本的完整更新日志（中文 + 英文双语，硬编码，不走 l10n）。
///
/// 界面与「复制按钮」的纯文本**都从这里生成** ⇒ 两处永远一致。
class _Changelog {
  const _Changelog({
    required this.version,
    required this.date,
    required this.zh,
    required this.en,
  });

  /// 形如 `v3.3.0`。同时用作折叠状态表的键。
  final String version;

  /// 形如 `2026-09-28`。
  final String date;

  final List<_ChangeSection> zh;
  final List<_ChangeSection> en;
}
