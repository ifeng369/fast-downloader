import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../utils/app_logger.dart';

/// 清理「应用内网页登录」留下的 WebView 登录态（cookie / localStorage）。
///
/// 网页登录会把账号会话写进 WebView 的 cookie 存储；App 侧“退出”只清了 token 的话，
/// 下次打开网页登录页会自动回到已登录状态，表现为账号退不出去。
class WebCookies {
  WebCookies._();

  static const _channel = MethodChannel('com.quarklite.quarklite/sys');

  /// Windows 的 WebView2 cookie 只能通过 controller 清；
  /// 网页登录页关闭时把 controller 交给这里持有，退出登录时清完再释放。
  static WebviewController? _retained;

  static void retain(WebviewController controller) {
    final old = _retained;
    _retained = controller;
    if (old != null && !identical(old, controller)) {
      old.dispose().catchError((Object _) {});
    }
  }

  static Future<void> clear() async {
    if (kIsWeb) return;
    try {
      if (Platform.isAndroid) {
        // 原生侧：CookieManager.removeAllCookies + WebStorage.deleteAllData
        await _channel.invokeMethod('clearCookies');
      } else if (Platform.isWindows) {
        final controller = _retained;
        if (controller == null) return;
        _retained = null;
        try {
          await controller.clearCookies();
        } catch (_) {}
        try {
          await controller.clearCache();
        } catch (_) {}
        await controller.dispose().catchError((Object _) {});
      }
    } catch (e) {
      AppLogger.I.w('web', '清理 WebView 登录态失败: $e');
    }
  }
}
