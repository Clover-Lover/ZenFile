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

/// 夸克网盘远程客户端。
///
/// 通过夸克网盘网页版接口实现：登录态为网页登录后取得的 Cookie
/// （经 [NetdiskAuthStore] 加密保存），文件列表 / 下载直链接口均携带该 Cookie。
/// 目录采用「友好路径 + 目录 id 缓存」两层表示：外部一律使用 `/a/b` 路径，
/// 客户端在每次列目录时记录子目录 id，需要时按路径逐级解析出目录 id。
///
/// 网络层说明：默认走 dart:io；若连接被掐断（Connection closed / 重置 / 超时），
/// 自动切到 Cronet（Chrome 网络栈）并重试一次，详见 [NetdiskHttp]。
///
/// 说明：
/// - 下载为网页版普通直链下载，不包含任何加速能力；
/// - 流式播放走 Range 区间读取（每次取流前重新申请直链并携带 Cookie）。
class QuarkRemoteClient extends RemoteClient {
  final NetworkConnectionModel connection;
  QuarkRemoteClient({required this.connection});

  /// 诊断日志标签（日志里显示为 `[netdisk:quark]`）。
  static const String _tag = 'quark';

  static const String _rootFid = '0';
  static const String _apiBase = 'https://drive-pc.quark.cn';
  static const String _webOrigin = 'https://pan.quark.cn';
  /// 接口请求 UA（客户端 UA，见 [NetdiskUserAgent.quarkClient]）。
  /// ⚠️ 不要再写死字符串：登录与请求的 UA 分工见该文件说明。
  static const String _userAgent = NetdiskUserAgent.quarkClient;

  String _cookie = '';

  /// 路径 -> 目录 id 缓存（根路径 '/' -> '0'）。
  final Map<String, String> _fidByPath = {'/': _rootFid};

  bool _connected = false;

  @override
  Future<void> connect() async {
    final auth = await NetdiskAuthStore.readAuth(connection.id);
    final cookie = auth?['cookie'] as String?;
    NetdiskLog.event(
        _tag,
        'connect: auth={${auth == null ? 'null' : auth.keys.join(',')}} '
            'cookie=${cookie == null ? 'null' : '${cookie.length}字'}');
    if (cookie == null || cookie.isEmpty) {
      NetdiskLog.error(
          _tag, 'connect', Exception('netdisk_auth_expired：本地无 cookie'));
      throw Exception('netdisk_auth_expired');
    }
    _cookie = cookie;
    NetdiskLog.event(_tag, '请求 UA = $_userAgent');
    // 连接即验证：列根目录失败视为登录态失效
    await listDirectory('/');
    _connected = true;
    NetdiskLog.event(_tag, 'connect 成功');
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
        NetdiskLog.error(_tag, '_resolveFidByWalking',
            Exception('目录不存在: $part（当前 $currentPath）'));
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
        'User-Agent': _userAgent,
        // Sec-CH-UA 系列必须与 UA 自称的 Chromium 版本一致，否则指纹自相矛盾
        // （比不带这些头更容易被风控标记）。quarkClient UA 自称 Chromium/100。
        'Sec-Ch-Ua':
            '"Chromium";v="100", "Not:A-Brand";v="24", "Google Chrome";v="100"',
        'Sec-Ch-Ua-Mobile': '?0',
        'Sec-Ch-Ua-Platform': '"Windows"',
        'Accept': 'application/json, text/plain, */*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Sec-Fetch-Site': 'same-site',
        'Sec-Fetch-Mode': 'cors',
        'Sec-Fetch-Dest': 'empty',
        // 注意：**不设置** Connection —— dart:io 自行管理连接复用
        // （HTTP/1.1 默认 keep-alive），手动再塞一个会和它内部逻辑打架。
      };

  Future<http.Response> _apiGet(String url) async {
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _apiGetOnce(url);
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _apiGetOnce 里打过
      }
    }
  }

  Future<http.Response> _apiGetOnce(String url) async {
    final client = NetdiskHttp.create(_tag);
    final sw = Stopwatch()..start();
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(_defaultHeaders());
      NetdiskLog.request(_tag, 'GET', req.url, headers: req.headers);
      final streamed = await client.send(req)
          .timeout(const Duration(seconds: 20));
      final resp = await http.Response.fromStream(streamed);
      NetdiskLog.response(_tag, resp.statusCode, resp.body, elapsed: sw.elapsed);
      return resp;
    } catch (e) {
      NetdiskLog.error(_tag, 'GET ${NetdiskLog.redactUrl(url)}', e);
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<http.Response> _apiPost(String url, Map<String, dynamic> body) async {
    // 连接级失败自动换栈重试一次（详见 netdisk_http.dart）；业务错误不重试。
    for (var attempt = 0;; attempt++) {
      try {
        return await _apiPostOnce(url, body);
      } catch (e) {
        if (attempt == 0 && NetdiskHttp.escalateIfStackFailure(_tag, e)) {
          continue;
        }
        rethrow; // 详细日志已在 _apiPostOnce 里打过
      }
    }
  }

  Future<http.Response> _apiPostOnce(
      String url, Map<String, dynamic> body) async {
    final client = NetdiskHttp.create(_tag);
    final sw = Stopwatch()..start();
    try {
      final req = http.Request('POST', Uri.parse(url));
      req.headers.addAll(_defaultHeaders());
      req.headers['Content-Type'] = 'application/json';
      req.body = json.encode(body);
      NetdiskLog.request(_tag, 'POST', req.url,
          headers: req.headers, body: body);
      final streamed = await client.send(req)
          .timeout(const Duration(seconds: 20));
      final resp = await http.Response.fromStream(streamed);
      NetdiskLog.response(_tag, resp.statusCode, resp.body, elapsed: sw.elapsed);
      return resp;
    } catch (e) {
      NetdiskLog.error(_tag, 'POST ${NetdiskLog.redactUrl(url)}', e);
      rethrow;
    } finally {
      client.close();
    }
  }

  Future<Map<String, dynamic>> _decodeBody(http.Response resp) async {
    if (resp.statusCode != 200) {
      NetdiskLog.error(
          _tag,
          '_decodeBody',
          Exception(
              'HTTP ${resp.statusCode}: ${NetdiskLog.snippet(resp.body, 240)}'));
      throw Exception('接口请求失败(${resp.statusCode})');
    }
    final decoded = json.decode(resp.body);
    if (decoded is! Map<String, dynamic>) {
      NetdiskLog.error(_tag, '_decodeBody',
          Exception('非 JSON 对象: ${NetdiskLog.snippet(resp.body, 240)}'));
      throw Exception('接口返回异常');
    }
    final status = decoded['status'];
    if (status != 200) {
      NetdiskLog.error(
          _tag,
          '_decodeBody',
          Exception('业务 status=$status code=${decoded['code']} '
              'message=${decoded['message']}'));
      throw Exception('接口返回异常(status: $status)');
    }
    return decoded;
  }

  @override
  Future<List<RemoteFileItem>> listDirectory(String path,
      {bool forceRefresh = false}) async {
    final fid = await _resolveFid(path);
    NetdiskLog.event(_tag, 'listDirectory($path) pdir_fid=$fid');
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
    NetdiskLog.event(_tag, 'listDirectory($path) → ${items.length} 项');
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
    NetdiskLog.event(_tag, '_getDownloadUrl fid=$fid');
    final resp = await _apiPost(
      '$_apiBase/1/clouddrive/file/download?pr=ucpro&fr=pc',
      {'fids': [fid]},
    );
    final body = await _decodeBody(resp);
    final data = body['data'];
    if (data is! List || data.isEmpty) {
      NetdiskLog.error(
          _tag,
          '_getDownloadUrl',
          Exception('data 为空: ${NetdiskLog.snippet(resp.body, 240)}'));
      throw Exception('获取下载链接失败');
    }
    final first = data.first;
    final url = first is Map<String, dynamic> ? first['download_url'] as String? : null;
    if (url == null || url.isEmpty) {
      NetdiskLog.error(
          _tag,
          '_getDownloadUrl',
          Exception('download_url 缺失: ${NetdiskLog.snippet(resp.body, 240)}'));
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
    await _downloadFromUrl(url, localPath, 'bytes=$startByte-${startByte + length - 1}',
        null);
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
        'Cookie': _cookie,
        'Referer': '$_webOrigin/',
        'User-Agent': _userAgent,
      });
      if (rangeHeader != null) {
        req.headers['Range'] = rangeHeader;
      }
      final streamed = await client.send(req)
          .timeout(const Duration(seconds: 20));
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
