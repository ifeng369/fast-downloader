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

  /// 刷新短期会话 cookie `__puus`。
  ///
  /// 实测：任何已登录请求（`/config`、`/member`、`/file/sort`）都会在响应头
  /// 下发新的 `__puus`（Max-Age=86400，24 小时滑动续期），[mergeSetCookie]
  /// 已自动并入 [cookie]。这里主动打一次轻量 `/config` 做保活。
  /// 只有长期凭据 `__pus` 过期才需要用户重新粘贴 Cookie。
  Future<void> refreshSession() async {
    if (cookie.isEmpty) return;
    try {
      await _request('GET', '$api/config');
    } catch (_) {
      // 刷新失败保留旧 Cookie，下次再试
    }
  }

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

  /// 批量获取下载直链。返回 (直链列表, 含最新 `__puus` 的 cookie)。
  Future<(List<UcDownloadInfo>, String)> getDownloadInfo(
      List<String> fids) async {
    if (fids.isEmpty) return (<UcDownloadInfo>[], downloadCookieSnapshot);
    return _downloadWithRetry({
      'fids': fids,
      'pwd_id': '',
      'stoken': '',
      'fids_token': List<String>.filled(fids.length, ''),
    });
  }

  // ---------------- 分享 ----------------

  static final _shareUrlRe =
      RegExp(r'(?:drive|fast)\.uc\.cn/s/([0-9A-Za-z]+)', caseSensitive: false);
  static final _pwdQueryRe = RegExp(
      r'[?&#](?:pwd|passcode|password|code)=([0-9A-Za-z_-]{2,12})',
      caseSensitive: false);
  static final _pwdCnRe = RegExp(
      r'(?:提取码|提取碼|访问码|訪問碼|密码|密碼|口令)\s*[:：=]?\s*([0-9A-Za-z_-]{2,12})');

  /// 从分享链接/文本里取 (pwdId, passcode)。
  /// 支持 `?pwd=xxxx`、「提取码:xxxx」以及纯 pwd_id（8 位以上字母数字）。
  static ({String pwdId, String passcode}) parseShareUrl(String text) {
    final t = text.trim();
    var pwdId = _shareUrlRe.firstMatch(t)?.group(1) ?? '';
    if (pwdId.isEmpty && RegExp(r'^[0-9A-Za-z]{8,}$').hasMatch(t)) {
      pwdId = t;
    }
    var passcode = '';
    for (final re in [_pwdQueryRe, _pwdCnRe]) {
      final m = re.firstMatch(t);
      if (m != null) {
        passcode = m.group(1) ?? '';
        break;
      }
    }
    return (pwdId: pwdId, passcode: passcode);
  }

  /// 分享令牌（游客/登录都可用；登录态直链速度更快）
  Future<UcShareSession> getShareToken(String pwdId, String passcode) async {
    try {
      final data = await _post('$api/share/sharepage/token',
          data: {'pwd_id': pwdId, 'passcode': passcode});
      final stoken = data is Map ? (data['stoken']?.toString() ?? '') : '';
      if (stoken.isEmpty) throw UcException(-1, '取不到分享令牌');
      return UcShareSession(
          pwdId: pwdId, passcode: passcode, stoken: stoken);
    } on UcException catch (e) {
      throw UcException(e.code, _shareMessage(e));
    }
  }

  /// 列出分享内的目录内容（自动翻页）
  Future<List<UcShareFile>> listShare(UcShareSession session,
      String pdirFid) async {
    final files = <UcShareFile>[];
    var page = 1;
    var total = -1;
    const size = 100;
    while (total < 0 || files.length < total) {
      final resp =
          await _request('GET', '$api/share/sharepage/detail', params: {
        'pwd_id': session.pwdId,
        'stoken': session.stoken,
        'pdir_fid': pdirFid,
        'force': 0,
        '_page': page,
        '_size': size,
        '_fetch_banner': 1,
        '_fetch_share': 1,
        '_fetch_total': 1,
        '_sort': 'file_type:asc,updated_at:desc',
      });
      final body = _parseBody(resp);
      final data = _check(body);
      if (data is! Map) break;
      final list = data['list'];
      if (list is! List) break;
      files.addAll(list
          .whereType<Map>()
          .map((e) => UcShareFile.fromJson(e.cast<String, dynamic>())));
      final meta = body['metadata'];
      total = meta is Map ? toInt(meta['_total'], fallback: -1) : -1;
      if (list.isEmpty) break;
      if (total < 0 && list.length < size) break;
      page++;
      if (page > 500) break;
    }
    return files;
  }

  /// 取分享文件的直链（**无需转存**，与网页端"直接下载"同一路径）。
  /// 需要把每个文件的 [UcShareFile.fidToken] 一并回传。
  Future<(List<UcDownloadInfo>, String)> getShareDownloadInfo(
      UcShareSession session, List<UcShareFile> files) async {
    if (files.isEmpty) return (<UcDownloadInfo>[], downloadCookieSnapshot);
    return _downloadWithRetry({
      'fids': files.map((e) => e.fid).toList(),
      'pwd_id': session.pwdId,
      'stoken': session.stoken,
      'fids_token': files.map((e) => e.fidToken).toList(),
    });
  }

  static String _shareMessage(UcException e) {
    switch (e.code) {
      case 41008:
        return '这个分享需要提取码，请在「提取码」里填上';
      case 41007:
        return '提取码不对，改一下再试';
      case 41006:
        return '分享不存在或已经失效';
      default:
        return e.message;
    }
  }

  /// 统一的直链请求：UC 该接口偶发瞬时 `21001 file not found`
  /// （网页端同样带 retry:4），对非登录类错误重试两次。
  Future<(List<UcDownloadInfo>, String)> _downloadWithRetry(
      Map<String, dynamic> body) async {
    UcException? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final data = await _post('$api/file/download', data: body);
        final raw = data is List ? data : (data is Map ? [data] : const []);
        final infos = raw
            .whereType<Map>()
            .map((e) => UcDownloadInfo.fromJson(e.cast<String, dynamic>()))
            .where((e) => e.url.isNotEmpty)
            .toList();
        // 响应头里的 Set-Cookie 已并入 cookie，这里取续期后的快照交给下载引擎
        if (infos.isNotEmpty) return (infos, downloadCookieSnapshot);
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
