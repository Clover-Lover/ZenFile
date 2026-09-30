import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../../l10n/generated/app_localizations.dart';

/// 网盘网页登录页。
///
/// 应用内打开网盘官方登录页，用户完成登录后，通过注入脚本抓取登录态：
/// - 夸克：读取 document.cookie（登录成功后 Cookie 中包含登录标识）；
/// - 阿里云盘：读取 localStorage.refresh_token（网页登录成功后写入）。
///
/// 抓取到有效登录态后立即回传并关闭页面；轮询注入避免错过登录瞬间。
class NetdiskLoginScreen extends StatefulWidget {
  /// 'quark' 或 'alipan'。
  final String provider;

  const NetdiskLoginScreen({super.key, required this.provider});

  @override
  State<NetdiskLoginScreen> createState() => _NetdiskLoginScreenState();
}

class _NetdiskLoginScreenState extends State<NetdiskLoginScreen> {
  late final WebViewController _controller;
  Timer? _pollTimer;
  bool _done = false;

  /// 桌面版 UA：夸克/阿里网页版会按 UA 区分展示「网页版登录界面」与
  /// 「App 推广引导页」，移动端 UA 下会命中推广页（无法登录），因此统一模拟桌面浏览器。
  static const _desktopUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  static const _pollScriptQuark = '''
(function () {
  try {
    var c = document.cookie || '';
    var m = c.match(/(?:^|;\\s*)__pus=([^;]+)/);
    if (m && m[1] && m[1].length > 10 && m[1] !== 'undefined') {
      window.ZenFileBridge.postMessage('OK:' + c);
    }
  } catch (e) {}
})();
''';

  static const _pollScriptAlipan = '''
(function () {
  try {
    var raw = localStorage.getItem('token') || localStorage.getItem('refresh_token') || '';
    var t = '';
    if (raw.indexOf('{') === 0) {
      try { t = JSON.parse(raw).refresh_token || ''; } catch (e) { t = ''; }
    } else {
      t = raw;
    }
    if (t && t.length > 10 && t.indexOf('null') !== 0) {
      window.ZenFileBridge.postMessage('OK:' + t);
    }
  } catch (e) {}
})();
''';

  Uri get _startUrl => widget.provider == 'quark'
      ? Uri.parse('https://pan.quark.cn/')
      : Uri.parse('https://www.aliyundrive.com/sign/in');

  String get _pollScript => widget.provider == 'quark'
      ? _pollScriptQuark
      : _pollScriptAlipan;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_desktopUA)
      ..setBackgroundColor(Colors.white)
      ..addJavaScriptChannel('ZenFileBridge',
          onMessageReceived: (message) {
        final body = message.message;
        if (_done || !body.startsWith('OK:')) return;
        _done = true;
        _pollTimer?.cancel();
        final payload = body.substring(3);
        if (widget.provider == 'quark') {
          Navigator.pop(context, {'cookie': payload});
        } else {
          Navigator.pop(context, {'refresh_token': payload});
        }
      })
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (url) {
          // 页面加载完成后立即尝试一次，再进入轮询
          _controller.runJavaScript(_pollScript);
          _startPolling();
        },
      ))
      ..loadRequest(_startUrl);
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      if (_done || !mounted) return;
      _controller.runJavaScript(_pollScript);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = L10n.of(context);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          widget.provider == 'quark'
              ? l10n.netdisk_quark
              : l10n.netdisk_alipan,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: theme.colorScheme.primary.withOpacity(0.06),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.netdisk_login_hint,
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface.withOpacity(0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}
