import 'dart:convert';
import 'dart:io';

import '../remote_client.dart';
import '../../netdisk_auth_store.dart';
import '../../../models/network_connection_model.dart';

/// 阿里云盘远程客户端。
///
/// 走网盘开放平台官方接口（openapi.alipan.com）：
/// 登录阶段在应用内网页完成（网页登录后取得 refresh_token，经
/// [NetdiskAuthStore] 加密保存）；客户端用 refresh_token 换取短期
/// access_token 访问文件接口。access_token 失效时自动用 refresh_token 刷新。
///
/// 说明：
/// - 下载 / 播放使用官方直链，不包含任何加速能力；
/// - 直链自带签名与时效，每次下载 / 取流前重新申请。
class AlipanRemoteClient extends RemoteClient {
  final NetworkConnectionModel connection;
  AlipanRemoteClient({required this.connection});

  static const String _rootFid = 'root';
  static const String _apiBase = 'https://openapi.alipan.com';

  /// 开放平台公共 OAuth 客户端标识（公开应用标识，配置后可更换）。
  static const String clientId = '25dzX3vbYqktVxXy';

  String _accessToken = '';
  String _refreshToken = '';
  String _driveId = '';

  /// 路径 -> 目录 id 缓存（根路径 '/' -> 'root'）。
  final Map<String, String> _fidByPath = {'/': _rootFid};

  bool _connected = false;

  @override
  Future<void> connect() async {
    final auth = await NetdiskAuthStore.readAuth(connection.id);
    final refresh = auth?['refresh_token'] as String?;
    if (refresh == null || refresh.isEmpty) {
      throw Exception('netdisk_auth_expired');
    }
    _refreshToken = refresh;
    await _refreshAccessToken();
    _driveId = await _getDriveId();
    _connected = true;
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

  /// 用 refresh_token 换取 access_token；返回的新 refresh_token 回写加密存储。
  Future<void> _refreshAccessToken() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(Uri.parse('$_apiBase/oauth/access_token'));
      req.headers.contentType = ContentType.json;
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36');
      req.add(utf8.encode(json.encode({
        'grant_type': 'refresh_token',
        'refresh_token': _refreshToken,
        'client_id': clientId,
      })));
      final resp = await req.close();
      final raw = await utf8.decoder.bind(resp).join();
      if (resp.statusCode != 200) {
        throw Exception('刷新登录态失败(${resp.statusCode})');
      }
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('刷新登录态失败');
      }
      _accessToken = (decoded['access_token'] as String?) ?? '';
      final newRefresh = (decoded['refresh_token'] as String?) ?? '';
      if (_accessToken.isEmpty) {
        throw Exception('刷新登录态失败');
      }
      if (newRefresh.isNotEmpty && newRefresh != _refreshToken) {
        _refreshToken = newRefresh;
        await NetdiskAuthStore.saveAuth(connection.id, {
          'refresh_token': newRefresh,
        });
      }
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _getDriveId() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(
          Uri.parse('$_apiBase/adrive/v1.0/user/getDriveInfo'));
      req.headers.set('Authorization', 'Bearer $_accessToken');
      final resp = await req.close();
      final raw = await utf8.decoder.bind(resp).join();
      if (resp.statusCode == 401) {
        // access_token 失效：刷新一次后重试
        await _refreshAccessToken();
        return await _getDriveId();
      }
      if (resp.statusCode != 200) {
        throw Exception('获取网盘信息失败(${resp.statusCode})');
      }
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('获取网盘信息失败');
      }
      final driveId = (decoded['default_drive_id'] as String?) ?? '';
      if (driveId.isEmpty) {
        throw Exception('获取网盘信息失败');
      }
      return driveId;
    } finally {
      client.close(force: true);
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
        throw Exception('目录不存在: $part');
      }
      currentPath = currentPath == '/' ? '/$part' : '$currentPath/$part';
      currentFid = _fidByPath[currentPath] ?? currentFid;
    }
    return currentFid;
  }

  Future<Map<String, dynamic>> _apiPost(String path,
      Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(Uri.parse('$_apiBase$path'));
      req.headers.contentType = ContentType.json;
      req.headers.set('Authorization', 'Bearer $_accessToken');
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36');
      req.add(utf8.encode(json.encode(body)));
      final resp = await req.close();
      final raw = await utf8.decoder.bind(resp).join();
      if (resp.statusCode == 401) {
        await _refreshAccessToken();
        return await _apiPost(path, body);
      }
      if (resp.statusCode != 200) {
        throw Exception('接口请求失败(${resp.statusCode})');
      }
      final decoded = json.decode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw Exception('接口返回异常');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
      {bool forceRefresh = false}) async {
    final fid = await _resolveFid(path);
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
    final body = await _apiPost('/adrive/v1.0/openFile/getDownloadUrl', {
      'drive_id': _driveId,
      'file_id': fid,
    });
    final url = body['url'] as String?;
    if (url == null || url.isEmpty) {
      throw Exception('获取下载链接失败');
    }
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
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/120.0 Safari/537.36');
      if (rangeHeader != null) {
        req.headers.set('Range', rangeHeader);
      }
      final resp = await req.close();
      if (resp.statusCode != HttpStatus.ok &&
          resp.statusCode != HttpStatus.partialContent) {
        throw Exception('下载失败(${resp.statusCode})');
      }
      final file = File(localPath);
      if (file.existsSync()) file.deleteSync();
      final sink = file.openWrite();
      final total = resp.contentLength;
      var received = 0;
      await for (final chunk in resp) {
        if (isCancelled) {
          await sink.close();
          file.deleteSync();
          throw Exception('下载已取消');
        }
        sink.add(chunk);
        received += chunk.length;
        if (onProgress != null && total > 0) {
          onProgress(received / total);
        }
      }
      await sink.close();
    } finally {
      client.close(force: true);
    }
  }

  @override
  Future<String?> getStreamUrl(String remotePath) async {
    // 官方直链可直接供播放器使用（无需附加请求头）
    try {
      final fid = await _resolveFid(remotePath);
      return await _getDownloadUrl(fid);
    } catch (_) {
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
