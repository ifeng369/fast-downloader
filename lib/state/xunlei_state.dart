import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/xunlei_client.dart';
import '../core/web_cookies.dart';
import '../utils/app_logger.dart';

/// 迅雷云盘登录态管理（token 持久化 + refresh 续期）
class XunleiState extends ChangeNotifier {
  static const _kAccess = 'xunlei_access_token';
  static const _kRefresh = 'xunlei_refresh_token';
  static const _kUser = 'xunlei_user_id';
  static const _kUsername = 'xunlei_username';

  /// 网页登录态（pan.xunlei.com）相关
  static const _kWeb = 'xunlei_web_mode';
  static const _kDevice = 'xunlei_device_id';
  static const _kCaptcha = 'xunlei_web_captcha_token';
  static const _kSpace = 'xunlei_root_space';

  static XunleiState? _instance;
  static XunleiState get I => _instance ??= XunleiState._();

  final XunleiClient client = XunleiClient();
  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  String? username; // 登录账号（手机号/邮箱），仅本机展示
  bool _ready = false;
  Timer? _refreshTimer;

  /// 当前账号容量信息（-1 表示未拉取/不可用）
  int _totalSize = -1;
  int _usedSize = -1;

  XunleiState._();

  int get totalSize => _totalSize;
  int get usedSize => _usedSize;

  /// 是否已拿到有效容量数据
  bool get hasQuota => _totalSize > 0 && _usedSize >= 0;

  bool get isLoggedIn => client.hasLogin;

  /// 应用启动时恢复登录态；refresh_token 有效时自动续期
  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      final access = await _read(_kAccess);
      final refresh = await _read(_kRefresh);
      final user = await _read(_kUser);
      username = await _read(_kUsername);
      final web = await _read(_kWeb);
      final device = await _read(_kDevice);
      final space = await _read(_kSpace);
      client.webMode = web == '1';
      client.webCaptchaToken = await _read(_kCaptcha);
      if (space.isNotEmpty) client.rootSpace = space;
      // 设备 ID 与登录凭据绑定：网页登录态用网页端绑定的 device_id，App 身份按凭据派生
      client.setTokens(
        access: access,
        refresh: refresh,
        user: user,
        device: device.isNotEmpty
            ? device
            : refresh.isNotEmpty
            ? XunleiClient.deviceIdFor(refresh)
            : XunleiClient.deviceIdFor('$access$user'),
      );
      AppLogger.I.i(
        'xunlei',
        '恢复登录态 access=${access.isNotEmpty} refresh=${refresh.isNotEmpty} '
            'web=${client.webMode} space=${client.rootSpace}',
      );
      if (access.isNotEmpty && refresh.isNotEmpty) {
        // 后台续期验证
        unawaited(_autoRefresh());
      } else if (refresh.isNotEmpty) {
        final err = await client.refresh();
        if (err == null) {
          await _persist();
          notifyListeners();
        }
      }
      if (client.webMode) {
        // 网页登录态：根 space 由服务端决定，启动时重新探测一次
        unawaited(_probeWebSpace());
      }
      if (client.hasLogin) await refreshQuota();
    } catch (e) {
      AppLogger.I.e('xunlei', '恢复登录态失败: $e');
    }
  }

  /// 重新探测网页登录态的根 space（探测成功后落盘）
  Future<void> _probeWebSpace() async {
    final err = await client.probeRootSpace();
    if (err == null) await _persist();
  }

  Future<String?> _autoRefresh() async {
    final err = await client.refresh();
    if (err != null) {
      AppLogger.I.w('xunlei', '自动续期失败: $err');
      return err;
    }
    await _persist();
    await refreshQuota();
    notifyListeners();
    return null;
  }

  /// 账号密码登录
  Future<String?> login(String account, String password) async {
    // 账号规范化（去掉 +86/空格等），设备 ID 与登录凭据绑定（md5(账号+密码)）
    final normalized = XunleiClient.normalizeAccount(account);
    client.webMode = false;
    client.webCaptchaToken = '';
    client.rootSpace = XunleiClient.appRootSpace;
    client.deviceId = XunleiClient.deviceIdFor('$normalized$password');
    final err = await client.signin(normalized, password);
    if (err != null) {
      AppLogger.I.e('xunlei', '登录失败: $err (device=${client.deviceId})');
      return err;
    }
    username = normalized;
    await _persist();
    _startRefresher();
    AppLogger.I.i('xunlei', '登录成功 user=${client.userId}');
    await refreshQuota();
    notifyListeners();
    return null;
  }

  /// 网页登录：用应用内网页登录页拿到的凭据直接接管登录态
  /// （access/refresh token 来自 pan.xunlei.com 的 localStorage）
  Future<String?> loginWithWebSession({
    required String accessToken,
    required String refreshToken,
    required String userId,
    required String deviceId,
    String captchaToken = '',
  }) async {
    final err = await client.initWebSession(
      access: accessToken,
      refresh: refreshToken,
      user: userId,
      device: deviceId.isNotEmpty
          ? deviceId
          : XunleiClient.deviceIdFor(refreshToken.isNotEmpty ? refreshToken : accessToken),
      captcha: captchaToken,
    );
    if (err != null) {
      AppLogger.I.e('xunlei', '网页登录态校验失败: $err');
      // 探测失败时不要留下半登录态：清空凭据，返回失败原因
      client.setTokens();
      client.webMode = false;
      client.rootSpace = XunleiClient.appRootSpace;
      return err;
    }
    // 续期一次，确认 refresh_token 可用（失败不阻塞，access_token 仍有效）
    final renew = await client.refresh();
    if (renew != null) {
      AppLogger.I.w('xunlei', '网页登录态续期失败: $renew');
    }
    username = null;
    await _persist();
    _startRefresher();
    AppLogger.I.i('xunlei', '网页登录成功 user=${client.userId} space=${client.rootSpace}');
    await refreshQuota();
    notifyListeners();
    return null;
  }

  /// 风控验证完成后，用新的 creditkey 重试登录
  Future<String?> loginWithCreditKey(
    String account,
    String password,
    String key,
  ) async {
    client.creditKey = key.trim();
    client.reviewUrl = '';
    final err = await login(account, password);
    if (err != null) {
      client.creditKey = '';
    }
    return err;
  }

  Future<void> logout() async {
    client.setTokens();
    client.webMode = false;
    client.webCaptchaToken = '';
    client.rootSpace = XunleiClient.appRootSpace;
    username = null;
    _totalSize = -1;
    _usedSize = -1;
    _refreshTimer?.cancel();
    _refreshTimer = null;
    for (final k in [
      _kAccess,
      _kRefresh,
      _kUser,
      _kUsername,
      _kWeb,
      _kDevice,
      _kCaptcha,
      _kSpace,
    ]) {
      try {
        await _secure.delete(key: k);
      } catch (_) {}
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(k);
      } catch (_) {}
    }
    await WebCookies.clear();
    AppLogger.I.i('xunlei', '已退出登录');
    notifyListeners();
  }

  /// 拉取当前账号容量信息并缓存（供网盘页/我的页展示）
  Future<void> refreshQuota() async {
    if (!client.hasLogin) {
      _totalSize = -1;
      _usedSize = -1;
      notifyListeners();
      return;
    }
    try {
      final q = await client.fetchQuota();
      _totalSize = q.totalSize;
      _usedSize = q.usedSize;
    } catch (_) {
      // 失败保留旧值，不提示
    }
    notifyListeners();
  }

  /// access_token 有效期约 7 天，提前续期保持登录态
  void _startRefresher() {
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(hours: 12), (_) {
      unawaited(_autoRefresh());
    });
  }

  Future<void> _persist() async {
    await _write(_kAccess, client.accessToken);
    await _write(_kRefresh, client.refreshToken);
    await _write(_kUser, client.userId);
    await _write(_kWeb, client.webMode ? '1' : '0');
    await _write(_kDevice, client.deviceId);
    await _write(_kSpace, client.rootSpace);
    if (client.webCaptchaToken.isEmpty) {
      await _delete(_kCaptcha);
    } else {
      await _write(_kCaptcha, client.webCaptchaToken);
    }
    if (username != null) {
      await _write(_kUsername, username!);
    } else {
      await _delete(_kUsername);
    }
  }

  Future<void> _delete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    } catch (_) {}
  }

  Future<String> _read(String key) async {
    try {
      final v = await _secure.read(key: key);
      if (v != null && v.isNotEmpty) return v;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(key) ?? '';
    } catch (_) {}
    return '';
  }

  Future<void> _write(String key, String value) async {
    if (value.isEmpty) return;
    try {
      await _secure.write(key: key, value: value);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {}
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }
}
