// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'netdisk_http.dart';
import 'netdisk_log.dart';
import 'netdisk_ua.dart';
import '../remote_client.dart';
import '../../netdisk_auth_store.dart';
import '../../../models/network_connection_model.dart';

/// 阿里云盘远程客户端。
///
/// 走阿里云盘网页版内部接口（openapi.alipan.com，PDS 体系）：
/// 登录阶段在应用内网页完成（网页登录后取得的登录态经 [NetdiskAuthStore]
/// 加密保存）；客户端携带 access_token 访问文件接口，失效时自动刷新。
///
/// 网络层说明：默认走 dart:io；若连接被掐断（复位 / 挂起超时）自动切到
/// Cronet（Chrome 网络栈）并重试一次，详见 [NetdiskHttp]。
///
/// 说明：
/// - 网页登录获取的凭证仅适用于网页版内部接口，开放平台 OAuth 不识别；
/// - 下载 / 播放使用官方直链，不包含任何加速能力；
/// - 直链自带签名与时效，每次下载 / 取流前重新申请。
class AlipanRemoteClient extends RemoteClient {
  final NetworkConnectionModel connection;
  AlipanRemoteClient({required this.connection});

  /// 诊断日志标签（日志里显示为 `[netdisk:alipan]`）。
  static const String _tag = 'alipan';

  static const String _rootFid = 'root';

  /// 网页版刷新端点（阿里云盘网页版登录态刷新，返回含 default_drive_id）。
  static const String _refreshBase = 'https://auth.aliyundrive.com';

  /// 网页版文件接口（网页版已并入 PDS 体系，走 openapi.alipan.com，
  /// 接口路径与开放平台一致；本机网络可能不通，以真机为准）。
  static const String _apiBase = 'https://openapi.alipan.com';

  /// 网页版公共 app_id（阿里云盘网页端固定客户端标识，配置后可更换）。
  static const String _webAppId = 'pJZInNHN2dZWk8qg';

  /// 接口请求 UA（见 [NetdiskUserAgent.desktop]）。
  static const String _userAgent = NetdiskUserAgent.desktop;

  String _accessToken = '';
  String _refreshToken = '';
  String _driveId = '';

  /// 路径 -> 目录 id 缓存（根路径 '/' -> 'root'）。
  final Map<String, String> _fidByPath = {'/': _rootFid};

  bool _connected = false;

  @override
  Future<void> connect() async {
    final auth = await NetdiskAuthStore.readAuth(connection.id);
    // 新格式：登录页回传完整 token JSON（含 access_token 与 refresh_token）
    final tokenJson = auth?['token_json'] as String?;
    if (tokenJson != null && tokenJson.isNotEmpty) {
      final decoded = json.decode(tokenJson);
      if (decoded is Map<String, dynamic>) {
        _accessToken = (decoded['access_token'] as String?) ?? '';
        _refreshToken = (decoded['refresh_token'] as String?) ?? '';
      }
    }
    // 兼容旧格式：仅保存了 refresh_token
    if (_refreshToken.isEmpty) {
      _refreshToken = (auth?['refresh_token'] as String?) ?? '';
    }
    NetdiskLog.event(
        _tag,
        'connect: auth={${auth == null ? 'null' : auth.keys.join(',')}} '
            'tokenJson=${tokenJson == null ? 'null' : '${tokenJson.length}字'} '
            'access=${_accessToken.length}字 refresh=${_refreshToken.length}字');
    if (_accessToken.isEmpty && _refreshToken.isEmpty) {
      NetdiskLog.error(
          _tag, 'connect', Exception('netdisk_auth_expired：无可用 token'));
      throw Exception('netdisk_auth_expired');
    }
    _driveId = await _getDriveId();
    _connected = true;
    NetdiskLog.event(_tag, 'connect 成功 driveId=$_driveId UA=$_userAgent');
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<bool> checkAlive() async {
    if (!_connected || _accessToken.isEmpty) return false;
    try {
      await _getDriveId();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 用 refresh_token 换取 access_token；返回的新 refresh_token 回写加密存储，
  /// 并顺带读取 default_drive_id（网页版刷新响应直接携带）。
  Future<void> _refreshAccessToken() async {
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _refreshAccessTokenOnce();
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _refreshAccessTokenOnce 里打过
      }
    }
  }

  Future<void> _refreshAccessTokenOnce() async {
    final client = NetdiskHttp.create(_tag);
    try {
      final req = http.Request('POST',
          Uri.parse('$_refreshBase/v2/account/token'));
      req.headers.addAll({
        'User-Agent': _userAgent,
        'Referer': 'https://www.aliyundrive.com/',
        'Origin': 'https://www.aliyundrive.com',
        'Content-Type': 'application/json',
      });
      req.body = json.encode({
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken,
        'app_id': _webAppId,
      });
      NetdiskLog.request(_tag, 'POST', req.url,
          headers: req.headers, body: req.body);
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 20));
      final resp = await http.Response.fromStream(streamed);
      NetdiskLog.response(_tag, resp.statusCode, resp.body);
      if (resp.statusCode != 200) {
        NetdiskLog.error(
            _tag,
            '_refreshAccessToken',
            Exception('HTTP ${resp.statusCode}: '
                '${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('刷新登录态失败(${resp.statusCode})');
      }
      final decoded = json.decode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        NetdiskLog.error(_tag, '_refreshAccessToken',
            Exception('非 JSON 对象: ${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('刷新登录态失败');
      }
      _accessToken = (decoded['access_token'] as String?) ?? '';
      final newRefresh = (decoded['refresh_token'] as String?) ?? '';
      NetdiskLog.event(
          _tag,
          '刷新 ok: access=${_accessToken.length}字 newRefresh=${newRefresh.length}字 '
              'driveId=${decoded['default_drive_id'] ?? '-'}');
      if (_accessToken.isEmpty) {
        throw Exception('刷新登录态失败');
      }
      // 刷新响应直接携带 default_drive_id，可避免单独调用取盘接口
      final driveId = (decoded['default_drive_id'] as String?) ?? '';
      if (driveId.isNotEmpty) _driveId = driveId;
      if (newRefresh.isNotEmpty && newRefresh != _refreshToken) {
        _refreshToken = newRefresh;
        await NetdiskAuthStore.saveAuth(connection.id, {
          'refresh_token': newRefresh,
        });
      }
    } catch (e) {
      NetdiskLog.error(_tag, '_refreshAccessToken', e);
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<String> _getDriveId() async {
    if (_driveId.isNotEmpty) return _driveId;
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _getDriveIdOnce();
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _getDriveIdOnce 里打过
      }
    }
  }

  Future<String> _getDriveIdOnce() async {
    final client = NetdiskHttp.create(_tag);
    try {
      final req = http.Request('POST',
          Uri.parse('$_apiBase/adrive/v1.0/user/getDriveInfo'));
      req.headers.addAll({
        'Authorization': 'Bearer $_accessToken',
        'User-Agent': _userAgent,
        'Referer': 'https://www.aliyundrive.com/',
        'Origin': 'https://www.aliyundrive.com',
        'Content-Type': 'application/json',
      });
      req.body = '{}';
      NetdiskLog.request(_tag, 'POST', req.url, headers: req.headers);
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 20));
      final resp = await http.Response.fromStream(streamed);
      NetdiskLog.response(_tag, resp.statusCode, resp.body);
      if (resp.statusCode == 401) {
        // access_token 失效：刷新一次后重试
        NetdiskLog.event(_tag, '_getDriveId 收到 401 → 刷新后重试');
        await _refreshAccessToken();
        return await _getDriveId();
      }
      if (resp.statusCode != 200) {
        NetdiskLog.error(
            _tag,
            '_getDriveId',
            Exception('HTTP ${resp.statusCode}: '
                '${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('获取网盘信息失败(${resp.statusCode})');
      }
      final decoded = json.decode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        NetdiskLog.error(_tag, '_getDriveId',
            Exception('非 JSON 对象: ${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('获取网盘信息失败');
      }
      final driveId = (decoded['default_drive_id'] as String?) ?? '';
      if (driveId.isEmpty) {
        NetdiskLog.error(_tag, '_getDriveId',
            Exception('default_drive_id 缺失: ${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('获取网盘信息失败');
      }
      _driveId = driveId;
      return driveId;
    } catch (e) {
      NetdiskLog.error(_tag, '_getDriveId', e);
      rethrow;
    } finally {
      client.close();
    }
  }

  /// 按路径解析目录 id；缓存未命中时从根目录逐级查找。
  Future<String> _resolveFid(String path) {
    if (path == '/' || path.isEmpty) return Future.value(_rootFid);
    final cached = _fidByPath[path];
    if (cached != null) return Future.value(cached);
    return _resolveFidByWalking(path);
  }

  Future<String> _resolveFidByWalking(String path) async {
    final parts = path.split('/').where((s) => s.isNotEmpty).toList();
    var currentPath = '/';
    var currentFid = _rootFid;
    for (final part in parts) {
      final items = await listDirectory(currentPath); // 顺带填充 _fidByPath
      final match =
          items.where((i) => i.isDirectory && i.name == part).firstOrNull;
      if (match == null) {
        NetdiskLog.error(_tag, '_resolveFidByWalking',
            Exception('目录不存在: $part（当前 $currentPath）'));
        throw Exception('目录不存在: $part');
      }
      currentPath = currentPath == '/' ? '/$part' : '$currentPath/$part';
      currentFid = _fidByPath[currentPath] ?? currentFid;
    }
    return currentFid;
  }

  Future<Map<String, dynamic>> _apiPost(String path,
      Map<String, dynamic> body) async {
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _apiPostOnce(path, body);
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _apiPostOnce 里打过
      }
    }
  }

  Future<Map<String, dynamic>> _apiPostOnce(String path,
      Map<String, dynamic> body) async {
    final client = NetdiskHttp.create(_tag);
    try {
      final req = http.Request('POST', Uri.parse('$_apiBase$path'));
      req.headers.addAll({
        'Authorization': 'Bearer $_accessToken',
        'User-Agent': _userAgent,
        'Referer': 'https://www.aliyundrive.com/',
        'Origin': 'https://www.aliyundrive.com',
        'Content-Type': 'application/json',
      });
      req.body = json.encode(body);
      NetdiskLog.request(_tag, 'POST', req.url,
          headers: req.headers, body: body);
      final sw = Stopwatch()..start();
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 20));
      final resp = await http.Response.fromStream(streamed);
      NetdiskLog.response(_tag, resp.statusCode, resp.body, elapsed: sw.elapsed);
      if (resp.statusCode == 401) {
        NetdiskLog.event(_tag, '$path 收到 401 → 刷新后重试');
        await _refreshAccessToken();
        return await _apiPost(path, body);
      }
      if (resp.statusCode != 200) {
        NetdiskLog.error(
            _tag,
            'POST $path',
            Exception('HTTP ${resp.statusCode}: '
                '${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('接口请求失败(${resp.statusCode})');
      }
      final decoded = json.decode(resp.body);
      if (decoded is! Map<String, dynamic>) {
        NetdiskLog.error(_tag, 'POST $path',
            Exception('非 JSON 对象: ${NetdiskLog.snippet(resp.body, 240)}'));
        throw Exception('接口返回异常');
      }
      return decoded;
    } catch (e) {
      NetdiskLog.error(_tag, 'POST $path', e);
      rethrow;
    } finally {
      client.close();
    }
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
      {bool forceRefresh = false}) async {
    final fid = await _resolveFid(path);
    NetdiskLog.event(_tag, 'listDirectory($path) parent_file_id=$fid');
    final items = <RemoteFileItem>[];
    var marker = '';
    while (true) {
      final body = await _apiPost('/adrive/v1.0/openFile/list', {
        'drive_id': _driveId,
        'parent_file_id': fid,
        'limit': 200,
        'marker': marker,
        'order_by': 'name',
        'order_direction': 'ASC',
      });
      final list = body['items'];
      if (list is List) {
        for (final e in list) {
          if (e is! Map<String, dynamic>) continue;
          final name = (e['name'] as String?) ?? '';
          if (name.isEmpty) continue;
          final fileId = (e['file_id'] as String?) ?? '';
          final isDir = (e['type'] as String?) == 'folder';
          final childPath = path == '/'
              ? '/$name'
              : (path.endsWith('/') ? '$path$name' : '$path/$name');
          _fidByPath[childPath] = fileId;
          items.add(RemoteFileItem(
            name: name,
            path: childPath,
            isDirectory: isDir,
            size: (e['size'] as int?) ?? 0,
            modified: _parseTime(e['updated_at']),
          ));
        }
      }
      final nextMarker = body['next_marker'] as String?;
      if (nextMarker == null || nextMarker.isEmpty) break;
      marker = nextMarker;
    }
    NetdiskLog.event(_tag, 'listDirectory($path) → ${items.length} 项');
    return items;
  }

  DateTime _parseTime(dynamic v) {
    if (v is String) {
      final t = DateTime.tryParse(v);
      if (t != null) return t;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 申请文件下载直链（带签名与时效，每次重新申请）。
  Future<String> _getDownloadUrl(String fid) async {
    NetdiskLog.event(_tag, '_getDownloadUrl file_id=$fid');
    final body = await _apiPost('/adrive/v1.0/openFile/getDownloadUrl', {
      'drive_id': _driveId,
      'file_id': fid,
    });
    final url = body['url'] as String?;
    if (url == null || url.isEmpty) {
      NetdiskLog.error(_tag, '_getDownloadUrl',
          Exception('url 缺失: ${NetdiskLog.jsonEncodeSafe(body)}'));
      throw Exception('获取下载链接失败');
    }
    NetdiskLog.event(_tag, '直链 ok: ${NetdiskLog.redactUrl(url)}');
    return url;
  }

  @override
  Future<void> downloadFile(String remotePath, String localPath,
      Function(double progress) onProgress) async {
    final fid = await _resolveFid(remotePath);
    final url = await _getDownloadUrl(fid);
    await _downloadFromUrl(url, localPath, null, onProgress);
  }

  @override
  Future<void> downloadRange(String remotePath, String localPath,
      int startByte, int length) async {
    final fid = await _resolveFid(remotePath);
    final url = await _getDownloadUrl(fid);
    await _downloadFromUrl(url, localPath,
        'bytes=$startByte-${startByte + length - 1}', null);
  }

  Future<void> _downloadFromUrl(String url, String localPath,
      String? rangeHeader, Function(double progress)? onProgress) async {
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _downloadFromUrlOnce(
            url, localPath, rangeHeader, onProgress);
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _downloadFromUrlOnce 里打过
      }
    }
  }

  Future<void> _downloadFromUrlOnce(String url, String localPath,
      String? rangeHeader, Function(double progress)? onProgress) async {
    final client = NetdiskHttp.create(_tag);
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll({
        'User-Agent': _userAgent,
        'Referer': 'https://www.aliyundrive.com/',
      });
      if (rangeHeader != null) {
        req.headers['Range'] = rangeHeader;
      }
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 20));
      NetdiskLog.event(
          _tag,
          '下载响应 ${streamed.statusCode} range=${rangeHeader ?? 'null'} '
              'len=${streamed.contentLength}');
      if (streamed.statusCode != HttpStatus.ok &&
          streamed.statusCode != HttpStatus.partialContent) {
        NetdiskLog.error(
            _tag,
            '下载直链',
            Exception('HTTP ${streamed.statusCode} '
                '${NetdiskLog.redactUrl(url)}'));
        throw Exception('下载失败(${streamed.statusCode})');
      }
      final file = File(localPath);
      if (file.existsSync()) file.deleteSync();
      final sink = file.openWrite();
      final total = streamed.contentLength;
      var received = 0;
      await for (final chunk in streamed.stream) {
        if (isCancelled) {
          await sink.close();
          file.deleteSync();
          throw Exception('下载已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && total != null && total > 0) {
          onProgress(received / total);
        }
      }
      await sink.close();
      NetdiskLog.event(_tag, '下载完成 $localPath ← $received 字节');
    } finally {
      client.close();
    }
  }

  @override
  Future<String?> getStreamUrl(String remotePath) async {
    // 官方直链可直接供播放器使用（无需附加请求头）
    try {
      final fid = await _resolveFid(remotePath);
      return await _getDownloadUrl(fid);
    } catch (e) {
      // 原本是 catch(_) 完全静默：取直链失败会被上层当成「不支持流式」，
      // 排查时看到的现象与真实原因（登录态/风控）完全脱节，必须留痕。
      NetdiskLog.error(_tag, 'getStreamUrl($remotePath)', e);
      return null;
    }
  }

  @override
  bool get supportsRangeRead => true;

  @override
  Future<int> getFileSize(String remotePath) async {
    final parent = remotePath.substring(0, remotePath.lastIndexOf('/') == 0
        ? 1
        : remotePath.lastIndexOf('/'));
    final items = await listDirectory(parent);
    final name = remotePath.split('/').last;
    for (final i in items) {
      if (!i.isDirectory && i.name == name) return i.size;
    }
    return -1;
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    final fid = await _resolveFid(path);
    await _apiPost('/adrive/v1.0/openFile/delete', {
      'drive_id': _driveId,
      'file_id': fid,
    });
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final fid = await _resolveFid(oldPath);
    final newName = newPath.split('/').last;
    await _apiPost('/adrive/v1.0/openFile/update', {
      'drive_id': _driveId,
      'file_id': fid,
      'name': newName,
    });
  }

  @override
  Future<void> createDirectory(String path) async {
    final parent = path.substring(0, path.lastIndexOf('/') == 0
        ? 1
        : path.lastIndexOf('/'));
    final name = path.split('/').last;
    final parentFid = await _resolveFid(parent);
    await _apiPost('/adrive/v1.0/openFile/create', {
      'drive_id': _driveId,
      'parent_file_id': parentFid,
      'name': name,
      'type': 'folder',
      'check_name_mode': 'refuse',
    });
  }

  @override
  Future<void> createFile(String path) {
    throw UnsupportedError('netdisk_unsupported');
  }

  @override
  Future<void> uploadFile(String localPath, String remotePath,
      Function(double progress) onProgress) {
    throw UnsupportedError('netdisk_unsupported');
  }
}
