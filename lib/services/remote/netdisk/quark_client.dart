import 'dart:convert';
import 'dart:io';

import '../remote_client.dart';
import '../../netdisk_auth_store.dart';
import '../../../models/network_connection_model.dart';

/// 夸克网盘远程客户端。
///
/// 通过夸克网盘网页版接口实现：登录态为网页登录后取得的 Cookie
/// （经 [NetdiskAuthStore] 加密保存），文件列表 / 下载直链接口均携带该 Cookie。
/// 目录采用「友好路径 + 目录 id 缓存」两层表示：外部一律使用 `/a/b` 路径，
/// 客户端在每次列目录时记录子目录 id，需要时按路径逐级解析出目录 id。
///
/// 说明：
/// - 下载为网页版普通直链下载，不包含任何加速能力；
/// - 流式播放走 Range 区间读取（每次取流前重新申请直链并携带 Cookie）。
class QuarkRemoteClient extends RemoteClient {
  final NetworkConnectionModel connection;
  QuarkRemoteClient({required this.connection});

  static const String _rootFid = '0';
  static const String _apiBase = 'https://drive-pc.quark.cn';
  static const String _webOrigin = 'https://pan.quark.cn';

  String _cookie = '';

  /// 路径 -> 目录 id 缓存（根路径 '/' -> '0'）。
  final Map<String, String> _fidByPath = {'/': _rootFid};

  bool _connected = false;

  @override
  Future<void> connect() async {
    final auth = await NetdiskAuthStore.readAuth(connection.id);
    final cookie = auth?['cookie'] as String?;
    if (cookie == null || cookie.isEmpty) {
      throw Exception('netdisk_auth_expired');
    }
    _cookie = cookie;
    // 连接即验证：列根目录失败视为登录态失效
    await listDirectory('/');
    _connected = true;
  }

  @override
  Future<void> disconnect() async {
    _connected = false;
  }

  @override
  Future<bool> checkAlive() async {
    if (!_connected || _cookie.isEmpty) return false;
    try {
      await listDirectory('/');
      return true;
    } catch (_) {
      return false;
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

  Map<String, String> _defaultHeaders() => {
        'Cookie': _cookie,
        'Origin': _webOrigin,
        'Referer': '$_webOrigin/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
        // 浏览器指纹头：夸克风控要求完整的 Sec-CH-UA 系列，缺失会被断开连接
        'Sec-Ch-Ua':
            '"Chromium";v="134", "Not:A-Brand";v="24", "Google Chrome";v="134"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"Windows"',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Sec-Fetch-Site': 'same-site',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
        'Connection': 'keep-alive',
      };

  Future<HttpClientResponse> _apiGet(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      _defaultHeaders().forEach(req.headers.set);
      return await req.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<HttpClientResponse> _apiPost(String url, Map<String, dynamic> body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(Uri.parse(url));
      _defaultHeaders().forEach(req.headers.set);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(json.encode(body)));
      return await req.close();
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, dynamic>> _decodeBody(HttpClientResponse resp) async {
    final raw = await utf8.decoder.bind(resp).join();
    if (resp.statusCode != 200) {
      throw Exception('接口请求失败(${resp.statusCode})');
    }
    final decoded = json.decode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('接口返回异常');
    }
    final status = decoded['status'];
    if (status != 200) {
      throw Exception('接口返回异常(status: $status)');
    }
    return decoded;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
      {bool forceRefresh = false}) async {
    final fid = await _resolveFid(path);
    final url =
        '$_apiBase/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=$fid'
        '&_page=1&_size=200&_sort=file_type:asc,updated_at:desc';
    final resp = await _apiGet(url);
    final body = await _decodeBody(resp);
    final data = body['data'];
    if (data is! Map<String, dynamic>) return [];
    final list = data['list'];
    if (list is! List) return [];
    final items = <RemoteFileItem>[];
    for (final e in list) {
      if (e is! Map<String, dynamic>) continue;
      final name = (e['file_name'] as String?) ?? '';
      if (name.isEmpty) continue;
      final fidValue = (e['fid'] as String?) ?? '';
      final isDir = (e['file_type'] as int?) == 0;
      final childPath =
          path == '/' ? '/$name' : (path.endsWith('/') ? '$path$name' : '$path/$name');
      _fidByPath[childPath] = fidValue;
      items.add(RemoteFileItem(
        name: name,
        path: childPath,
        isDirectory: isDir,
        size: (e['size'] as int?) ?? 0,
        modified: _parseTime(e['updated_at']),
      ));
    }
    return items;
  }

  DateTime _parseTime(dynamic v) {
    if (v is int && v > 0) {
      // 秒级时间戳；个别字段为毫秒级，按量级区分
      final millis = v > 1000000000000 ? v : v * 1000;
      return DateTime.fromMillisecondsSinceEpoch(millis);
    }
    if (v is String) {
      final t = DateTime.tryParse(v);
      if (t != null) return t;
    }
    return DateTime.fromMillisecondsSinceEpoch(0);
  }

  /// 申请文件下载直链（每次申请新链接）。
  Future<String> _getDownloadUrl(String fid) async {
    final resp = await _apiPost(
      '$_apiBase/1/clouddrive/file/download?pr=ucpro&fr=pc',
      {'fids': [fid]},
    );
    final body = await _decodeBody(resp);
    final data = body['data'];
    if (data is! List || data.isEmpty) {
      throw Exception('获取下载链接失败');
    }
    final first = data.first;
    final url = first is Map<String, dynamic> ? first['download_url'] as String? : null;
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
    await _downloadFromUrl(url, localPath, 'bytes=$startByte-${startByte + length - 1}',
        null);
  }

  Future<void> _downloadFromUrl(String url, String localPath,
      String? rangeHeader, Function(double progress)? onProgress) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Cookie', _cookie);
      req.headers.set('Referer', '$_webOrigin/');
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36');
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
    // 直链必须携带 Cookie，播放器无法附加请求头，统一走 Range 区间读取播放
    return null;
  }

  @override
  bool get supportsRangeRead => true;

  @override
  Future<int> getFileSize(String remotePath) async {
    final items = await listDirectory(
      remotePath.substring(0, remotePath.lastIndexOf('/') == 0
          ? 1
          : remotePath.lastIndexOf('/')),
    );
    final name = remotePath.split('/').last;
    for (final i in items) {
      if (!i.isDirectory && i.name == name) return i.size;
    }
    return -1;
  }

  @override
  Future<void> delete(String path, bool isDir) async {
    final fid = await _resolveFid(path);
    final resp = await _apiPost(
      '$_apiBase/1/clouddrive/file/delete?pr=ucpro&fr=pc',
      {'fids': [fid]},
    );
    await _decodeBody(resp);
  }

  @override
  Future<void> rename(String oldPath, String newPath) async {
    final fid = await _resolveFid(oldPath);
    final newName = newPath.split('/').last;
    final resp = await _apiPost(
      '$_apiBase/1/clouddrive/file/update?pr=ucpro&fr=pc',
      {'fid': fid, 'file_name': newName},
    );
    await _decodeBody(resp);
  }

  @override
  Future<void> createDirectory(String path) {
    throw UnsupportedError('netdisk_unsupported');
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
