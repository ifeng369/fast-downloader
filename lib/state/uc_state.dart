import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/uc_client.dart';
import '../api/uc_models.dart';
import '../utils/app_logger.dart';

/// UC 网盘登录态管理（Cookie 持久化 + 启动校验）。
///
/// UC 的登录态完全由 Cookie 表达，服务端不会返回可续期的 token，
/// 失效后需要用户重新粘贴 Cookie（网盘页/接口会返回 31001）。
class UcState extends ChangeNotifier {
  static const _kCookie = 'uc_cookie';
  static const _kCookieBackup = 'uc_cookie_backup';
  static const _kMemberType = 'uc_member_type';
  static const _kNickname = 'uc_nickname';

  static UcState? _instance;
  static UcState get I => _instance ??= UcState._();

  final UcClient client = UcClient();
  final _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  UcUserInfo? user;
  String? loginError;
  bool _ready = false;

  UcState._();

  bool get isLoggedIn => user != null;

  /// 启动时恢复登录态：读 Cookie → 先用缓存展示 → 后台校验。
  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    try {
      final cookie = await _loadCookie();
      if (cookie.isEmpty) return;
      client.setCookie(cookie);
      final cached = await _readCachedUser();
      if (cached != null) {
        user = cached;
        notifyListeners();
      }
      unawaited(refreshUser());
      AppLogger.I.i('uc', '恢复登录态 有Cookie=true');
    } catch (e) {
      AppLogger.I.e('uc', '恢复登录态失败: $e');
    }
  }

  /// 校验 Cookie 是否仍有效；登录态失效时自动登出。
  Future<void> refreshUser() async {
    if (!client.hasLogin) return;
    try {
      final info = await client.getUserInfo();
      user = info;
      loginError = null;
      await _cacheUser(info);
      await _saveCookie();
      notifyListeners();
    } on UcException catch (e) {
      AppLogger.I.w('uc', '校验登录态失败: $e');
      if (UcClient.isAuthError(e.code)) {
        await logout();
      } else if (user == null) {
        loginError = e.message;
        notifyListeners();
      }
    } catch (e) {
      if (user == null) {
        loginError = e.toString();
        notifyListeners();
      }
    }
  }

  /// Cookie 登录：先验证再落盘。
  Future<String?> login(String cookie) async {
    final text = cookie.trim();
    if (text.isEmpty) return '请先粘贴 Cookie';
    client.setCookie(text);
    try {
      final info = await client.getUserInfo();
      user = info;
      loginError = null;
      await _saveCookie();
      await _cacheUser(info);
      notifyListeners();
      AppLogger.I.i('uc', '登录成功 member=${info.memberType}');
      return null;
    } catch (e) {
      client.setCookie('');
      final msg = e is UcException ? e.message : e.toString();
      AppLogger.I.e('uc', '登录失败: $msg');
      return msg;
    }
  }

  Future<void> logout() async {
    client.setCookie('');
    user = null;
    loginError = null;
    await _clearCookie();
    for (final k in [_kMemberType, _kNickname]) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(k);
      } catch (_) {}
    }
    AppLogger.I.i('uc', '已退出登录');
    notifyListeners();
  }

  // ---------------- 持久化 ----------------

  Future<String> _loadCookie() async {
    try {
      final v = await _secure.read(key: _kCookie);
      if (v != null && v.isNotEmpty) {
        AppLogger.I.i('uc', 'Cookie 来源=安全存储');
        return v;
      }
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getString(_kCookieBackup);
      if (v != null && v.isNotEmpty) {
        AppLogger.I.i('uc', 'Cookie 来源=本地备份');
        return v;
      }
    } catch (_) {}
    return '';
  }

  Future<void> _saveCookie() async {
    final c = client.cookie;
    if (c.isEmpty) return;
    try {
      await _secure.write(key: _kCookie, value: c);
    } catch (e) {
      AppLogger.I.w('uc', '安全存储写入失败（回退到普通存储）: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kCookieBackup, c);
    } catch (_) {}
  }

  Future<void> _clearCookie() async {
    try {
      await _secure.delete(key: _kCookie);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kCookieBackup);
    } catch (_) {}
  }

  Future<void> _cacheUser(UcUserInfo info) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kMemberType, info.memberType);
      await prefs.setString(_kNickname, info.nickname);
    } catch (_) {}
  }

  Future<UcUserInfo?> _readCachedUser() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final member = prefs.getString(_kMemberType) ?? '';
      final nick = prefs.getString(_kNickname) ?? '';
      if (member.isEmpty && nick.isEmpty) return null;
      return UcUserInfo(memberType: member, nickname: nick);
    } catch (_) {
      return null;
    }
  }
}
