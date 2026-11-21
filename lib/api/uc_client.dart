import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../utils/types.dart';
import 'uc_models.dart';

class UcException implements Exception {
  final int code;
  final String message;

  UcException(this.code, this.message);

  @override
  String toString() => message;
}

/// UC 网盘接口客户端。
///
/// 契约来自对 `drive.uc.cn` 网页端的实测（与夸克同一套 clouddrive 协议，
/// 只是 host / `pr` 参数不同）：
/// - 列表：`GET  {api}/file/sort?pdir_fid=&_page=&_size=&_fetch_total=1&_fetch_sub_dirs=0&_sort=`
/// - 直链：`POST {api}/file/download` body `{fids:[...]}`（支持批量）
/// - 账号：`GET  {api}/member`
///
/// 直链 CDN（dl-pc-*.drive.uc.cn）不带 Cookie 会返回 412，下载时必须把
/// [downloadCookieSnapshot] 一起交给下载引擎，并带 `Referer: https://drive.uc.cn/`。
class UcClient {
  static const api = 'https://pc-api.uc.cn/1/clouddrive';
  static const referer = 'https://drive.uc.cn/';
  static const rootFid = '0';

  static const uaPc =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

  static const _params = {'pr': 'UCBrowser', 'fr': 'pc'};

  final Dio _dio;
  String cookie = '';

  UcClient()
      : _dio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
        ));

  bool get hasLogin => cookie.isNotEmpty;

  void setCookie(String c) {
    cookie = c.trim();
  }

  String get downloadCookieSnapshot => cookie;

  /// 登录态失效类错误码（需要重新登录，重试无意义）
  static bool isAuthError(int code) => code == 31001 || code == 401;

  // ---------------- HTTP 基础设施 ----------------

  Future<Response<dynamic>> _request(
    String method,
    String url, {
    Map<String, dynamic>? params,
    Object? data,
    String? userAgent,
  }) async {
    final headers = <String, dynamic>{
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/json',
      'Origin': referer,
      'Referer': referer,
      'User-Agent': userAgent ?? uaPc,
      if (cookie.isNotEmpty) 'Cookie': cookie,
    };
    final resp = await _dio.request(
      url,
      data: data,
      queryParameters: {..._params, ...?params},
      options: Options(
        method: method,
        headers: headers,
        validateStatus: (_) => true,
      ),
    );
    _mergeSetCookie(resp);
    return resp;
  }

  /// 合并服务端下发的 Set-Cookie（UC 会在会话刷新时续期 __sdid 等）
  void _mergeSetCookie(Response<dynamic> resp) {
    final setCookies = resp.headers['set-cookie'];
    if (setCookies == null || setCookies.isEmpty) return;
    final entries = <String, String>{};
    for (final raw in setCookies) {
      final seg = raw.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      entries[seg.substring(0, eq).trim()] = seg.substring(eq + 1).trim();
    }
    if (entries.isEmpty) return;
    final kept = <String>[];
    for (final part in cookie.split(';')) {
      final t = part.trim();
      if (t.isEmpty) continue;
      if (entries.containsKey(t.split('=').first)) continue;
      kept.add(t);
    }
    for (final e in entries.entries) {
      kept.add('${e.key}=${e.value}');
    }
    cookie = kept.join('; ');
  }

  Map<String, dynamic> _parseBody(Response<dynamic> resp) {
    final body = resp.data;
    if (body is String) {
      if (body.isEmpty) return {};
      final decoded = jsonDecode(body);
      return decoded is Map ? decoded.cast<String, dynamic>() : {};
    }
    if (body is Map) return body.cast<String, dynamic>();
    return {};
  }

  dynamic _check(Map<String, dynamic> body) {
    final raw = body['code'];
    final code = raw == null ? 0 : toInt(raw, fallback: -1);
    if (code != 0) {
      final msg = body['message']?.toString() ?? '';
      if (isAuthError(code)) {
        throw UcException(
            code, msg.isEmpty ? '登录已失效，请重新登录' : '登录已失效，请重新登录（$msg）');
      }
      throw UcException(code, msg.isEmpty ? '请求失败（$code）' : msg);
    }
    return body['data'];
  }

  Future<dynamic> _get(
    String url, {
    Map<String, dynamic>? params,
    String? userAgent,
  }) async {
    final resp = await _request('GET', url, params: params, userAgent: userAgent);
    return _check(_parseBody(resp));
  }

  Future<dynamic> _post(
    String url, {
    Map<String, dynamic>? params,
    Object? data,
    String? userAgent,
  }) async {
    final resp = await _request('POST', url,
        params: params, data: data, userAgent: userAgent);
    return _check(_parseBody(resp));
  }

  // ---------------- 账号 ----------------

  Future<UcUserInfo> getUserInfo() async {
    final data = await _get('$api/member');
    if (data is! Map) {
      throw UcException(31001, '登录状态无效，请重新登录');
    }
    return UcUserInfo.fromJson({'data': data});
  }

  // ---------------- 我的网盘 ----------------

  /// 列出目录内容（自动翻页拉取全部；根目录 [rootFid] = '0'）
  Future<List<UcFile>> listFiles(String pdirFid,
      {int page = 1, int size = 100}) async {
    final files = <UcFile>[];
    var total = -1;
    while (total < 0 || files.length < total) {
      final resp = await _request('GET', '$api/file/sort', params: {
        'pdir_fid': pdirFid,
        '_page': page,
        '_size': size,
        '_fetch_total': 1,
        '_fetch_sub_dirs': 0,
        '_sort': 'file_type:asc,updated_at:desc',
      });
      final body = _parseBody(resp);
      final data = _check(body);
      if (data is! Map) break;
      final list = data['list'];
      if (list is! List) break;
      files.addAll(list
          .whereType<Map>()
          .map((e) => UcFile.fromJson(e.cast<String, dynamic>())));
      final meta = body['metadata'];
      total = meta is Map ? toInt(meta['_total'], fallback: -1) : -1;
      if (list.isEmpty) break;
      if (total < 0 && list.length < size) break;
      page++;
      if (page > 500) break;
    }
    return files;
  }

  /// 批量获取下载直链。返回 (直链列表, 请求时的 cookie 快照)。
  ///
  /// UC 该接口偶发瞬时 `21001 file not found`（网页端同样带 retry:4），
  /// 这里对非登录类错误重试两次。
  Future<(List<UcDownloadInfo>, String)> getDownloadInfo(
      List<String> fids) async {
    final snapshot = downloadCookieSnapshot;
    if (fids.isEmpty) return (<UcDownloadInfo>[], snapshot);
    UcException? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final data = await _post('$api/file/download', data: {'fids': fids});
        final raw = data is List ? data : (data is Map ? [data] : const []);
        final infos = raw
            .whereType<Map>()
            .map((e) => UcDownloadInfo.fromJson(e.cast<String, dynamic>()))
            .where((e) => e.url.isNotEmpty)
            .toList();
        if (infos.isNotEmpty) return (infos, snapshot);
        lastError = UcException(-1, '未获取到下载直链（文件可能正在打包）');
      } on UcException catch (e) {
        if (isAuthError(e.code)) rethrow;
        lastError = e;
      }
      if (attempt < 2) {
        await Future<void>.delayed(const Duration(milliseconds: 400));
      }
    }
    throw lastError ?? UcException(-1, '获取下载直链失败');
  }
}
