import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../api/quark_client.dart';
import '../../api/uc_client.dart';
import '../../core/web_cookies.dart';
import '../../state/app_state.dart';
import '../../state/netdisk123_state.dart';
import '../../state/uc_state.dart';
import '../../state/xunlei_state.dart';

enum WebLoginProvider { quark, uc, netdisk123 }

const _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 应用内打开网盘 PC 登录页，登录成功后自动读取 Cookie 并校验、保存。
///
/// - Android：`webview_flutter` + `AndroidWebViewCookieManager.getCookies`
/// - Windows：`webview_flutter_windows`（WebView2）+ `WebviewController.getCookies`
/// - iOS：WebView 拿不到 Cookie，只保留粘贴方式
class WebLoginPage extends StatefulWidget {
  final WebLoginProvider provider;

  const WebLoginPage({super.key, required this.provider});

  @override
  State<WebLoginPage> createState() => _WebLoginPageState();
}

class _WebLoginPageState extends State<WebLoginPage> {
  WebViewController? _androidController;
  WebviewController? _winController;
  Timer? _poll;
  String _status = '正在打开登录页…';
  bool _submitting = false;
  bool _done = false;
  String _lastTried = '';

  /// 页面缩放（登录页是桌面版，手机上偏小）
  double _zoom = 1.0;
  static const double _zoomMin = 0.6;
  static const double _zoomMax = 3.0;
  static const double _zoomStep = 0.2;

  bool get _isUc => widget.provider == WebLoginProvider.uc;
  bool get _isPan123 => widget.provider == WebLoginProvider.netdisk123;

  /// 夸克/UC 走 cookie；123 的网页登录态是 localStorage/cookie 里的 token
  bool get _useCookie => !_isPan123;

  String get _title => switch (widget.provider) {
    WebLoginProvider.quark => '登录夸克网盘',
    WebLoginProvider.uc => '登录 UC 网盘',
    WebLoginProvider.netdisk123 => '登录 123 网盘',
  };

  String get _ua => switch (widget.provider) {
    WebLoginProvider.quark => QuarkClient.uaPc,
    WebLoginProvider.uc => UcClient.uaPc,
    WebLoginProvider.netdisk123 => _desktopUa,
  };

  String get _loginUrl => switch (widget.provider) {
    WebLoginProvider.quark => 'https://pan.quark.cn/',
    WebLoginProvider.uc => 'https://drive.uc.cn/',
    // 123 的账号中心登录页（登录成功后写 cookie sso-token，等价于 authorToken）
    WebLoginProvider.netdisk123 => 'https://user.123pan.cn/centerlogin',
  };

  /// 登录态 cookie 名（夸克/UC 都是 Alibaba 系，均用 __pus）
  String get _sessionCookie => '__pus';

  List<String> get _cookieHosts => switch (widget.provider) {
    WebLoginProvider.uc => ['https://drive.uc.cn', 'https://pc-api.uc.cn'],
    WebLoginProvider.quark => [
      'https://pan.quark.cn',
      'https://drive.quark.cn',
      'https://pc-api.quark.cn',
    ],
    WebLoginProvider.netdisk123 => [
      'https://user.123pan.cn',
      'https://www.123pan.com',
      'https://api.123278.com',
    ],
  };

  List<String> get _domainSuffixes => switch (widget.provider) {
    WebLoginProvider.uc => ['uc.cn'],
    WebLoginProvider.quark => ['quark.cn'],
    WebLoginProvider.netdisk123 => ['123pan.cn', '123pan.com', '123278.com'],
  };

  /// 在页面里读 token：
  /// - 迅雷：SSO SDK 把凭据存成 localStorage['credentials_<clientId>'] = {access_token, refresh_token, ...}
  /// - 123：localStorage['authorToken']
  String get _storageScript =>
      "(function(){try{var t='';"
      "for(var i=0;i<localStorage.length;i++){var k=localStorage.key(i);"
      "if(k&&k.toLowerCase()==='authortoken')t=String(localStorage.getItem(k)||'')}"
      "return JSON.stringify({token:t})}catch(e){return '{}'}})()";

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _poll?.cancel();
    // Windows：把 controller 交给 WebCookies 持有，退出登录时用它清 cookie
    final win = _winController;
    if (win != null) {
      WebCookies.retain(win);
    }
    super.dispose();
  }

  Future<void> _init() async {
    if (kIsWeb) {
      _setStatus('当前平台不支持自动读取 Cookie，请返回使用「Cookie 登录」');
      return;
    }
    if (Platform.isWindows) {
      await _initWindows();
    } else if (Platform.isAndroid) {
      _initAndroid();
    } else {
      _setStatus('当前平台不支持自动读取 Cookie，请返回使用「Cookie 登录」');
      return;
    }
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _checkLogin());
  }

  void _initAndroid() {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_ua)
      // 允许双指缩放
      ..enableZoom(true)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            _applyZoom();
            _checkLogin();
          },
          onWebResourceError: (e) {
            if (e.isForMainFrame ?? true) {
              _setStatus('加载失败：${e.description}');
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(_loginUrl));
    if (!mounted) return;
    setState(() {
      _androidController = controller;
      _status = '请在页面中完成登录，成功后会自动返回';
    });
  }

  Future<void> _initWindows() async {
    final controller = WebviewController();
    try {
      await controller.initialize();
      await controller.setUserAgent(_ua);
      await controller.setZoomFactor(_zoom);
      await controller.loadUrl(_loginUrl);
      // 页面跳转后 WebView2 会重置缩放，这里跟随 url 变化重新应用
      controller.url.listen((_) {
        Future<void>.delayed(const Duration(milliseconds: 300), _applyZoom);
      });
      if (!mounted) return;
      setState(() {
        _winController = controller;
        _status = '请在页面中完成登录，成功后会自动返回';
      });
    } catch (e) {
      _setStatus('打开登录页失败：$e');
    }
  }

  /// 应用当前缩放到页面
  Future<void> _applyZoom() async {
    if (kIsWeb) return;
    try {
      if (Platform.isWindows) {
        await _winController?.setZoomFactor(_zoom);
      } else if (Platform.isAndroid) {
        // Android WebView 没有统一 zoomFactor，用 CSS zoom 控制（Chromium 支持）
        await _androidController?.runJavaScript(
          "document.body.style.zoom = '${_zoom.toStringAsFixed(2)}';",
        );
      }
    } catch (_) {}
  }

  void _changeZoom(double delta) {
    final next = (_zoom + delta).clamp(_zoomMin, _zoomMax);
    if ((next - _zoom).abs() < 0.001) return;
    setState(() => _zoom = next);
    _applyZoom();
  }

  void _setStatus(String msg) {
    if (!mounted) return;
    setState(() => _status = msg);
  }

  /// 读当前页面可用的登录凭据（JSON 字符串）；没有可用凭据时返回空串。
  /// 123：localStorage `authorToken`，登录中心(user.123pan.cn)回退到 cookie `sso-token`
  Future<String> _readCredential() async {
    final map = <String, dynamic>{..._decode(await _readStorage())};
    if (_isPan123) {
      if ((map['token'] ?? '').toString().isEmpty) {
        // 登录中心只把 token 写进 cookie；www 页面才会回填 localStorage.authorToken
        final sso = _cookieValue(await _readCookieHeader(), 'sso-token');
        if (sso.isNotEmpty) map['token'] = sso;
      }
      if ((map['token'] ?? '').toString().isEmpty) return '';
      return jsonEncode(map);
    }
    return '';
  }

  /// 在页面里读 token（迅雷/123），返回页面脚本给出的 JSON 字符串
  Future<String> _readStorage() async {
    if (_useCookie) return '';
    try {
      if (!kIsWeb && Platform.isWindows) {
        final value = await _winController?.executeScript(_storageScript);
        return _unwrap(value);
      }
      final value = await _androidController?.runJavaScriptReturningResult(
        _storageScript,
      );
      return _unwrap(value);
    } catch (_) {
      return '';
    }
  }

  /// Android 的 runJavaScriptReturningResult 可能把字符串再包一层引号
  String _unwrap(Object? raw) {
    var text = raw?.toString() ?? '';
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
      try {
        text = jsonDecode(text) as String;
      } catch (_) {}
    }
    return text;
  }

  Map<String, dynamic> _decode(String raw) {
    if (raw.isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map ? value.cast<String, dynamic>() : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 读取并拼接 Cookie 请求头（只保留目标网盘域名下的 cookie）
  Future<String> _readCookieHeader() async {
    final byName = <String, String>{};
    if (!kIsWeb && Platform.isAndroid) {
      // 通过原生通道读 CookieManager（与 WebView 共享同一 cookie 存储）
      for (final host in _cookieHosts) {
        final header = await AppState.I.webViewCookies(host);
        if (header == null || header.isEmpty) continue;
        for (final part in header.split(';')) {
          final idx = part.indexOf('=');
          if (idx <= 0) continue;
          byName[part.substring(0, idx).trim()] = part
              .substring(idx + 1)
              .trim();
        }
      }
    } else if (!kIsWeb && Platform.isWindows) {
      final controller = _winController;
      if (controller == null) return '';
      // 空 uri = 返回整个 profile 的 cookie
      final list = await controller.getCookies();
      for (final c in list) {
        final domain = c.domain.replaceFirst(RegExp(r'^\.'), '');
        if (!_domainSuffixes.any(domain.endsWith)) continue;
        if (c.name.isNotEmpty) byName[c.name] = c.value;
      }
    }
    return byName.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  Future<void> _checkLogin() async {
    if (_done || _submitting) return;
    try {
      if (_useCookie) {
        final header = await _readCookieHeader();
        if (!header.contains('$_sessionCookie=')) return;
        if (header == _lastTried) return; // cookie 没变就不重复校验
        _lastTried = header;
        await _submit(header);
      } else {
        final cred = await _readCredential();
        if (cred.isEmpty || cred == _lastTried) return;
        _lastTried = cred;
        await _submit(cred);
      }
    } catch (_) {}
  }

  Future<void> _submit([String? credential]) async {
    if (_submitting || _done) return;
    setState(() => _submitting = true);
    try {
      String? err;
      if (_useCookie) {
        final cookie = credential ?? await _readCookieHeader();
        if (cookie.isEmpty) {
          _setStatus('还没有读到 Cookie，请先在页面里完成登录');
          return;
        }
        err = _isUc
            ? await UcState.I.login(cookie)
            : await AppState.I.login(cookie);
      } else {
        final raw = credential ?? await _readStorage();
        final token = (_decode(raw)['token'] ?? '').toString();
        if (token.isEmpty) {
          _setStatus('还没有读到 123 网盘登录凭据，请先在页面里完成登录');
          return;
        }
        err = await Netdisk123State.I.loginByWebToken(token);
      }
      if (err == null) {
        _done = true;
        _poll?.cancel();
        if (mounted) Navigator.of(context).maybePop(true);
        return;
      }
      _setStatus('已读取登录凭据，但校验失败：$err');
    } catch (e) {
      _setStatus('读取登录凭据失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  static String _cookieValue(String header, String name) {
    for (final part in header.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      if (part.substring(0, idx).trim() == name) {
        return part.substring(idx + 1).trim();
      }
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: _title,
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: MiuixIcon(
            icon: Icons.arrow_back_ios_new_rounded,
            tint: colors.onSurfaceContainer,
            size: 20,
          ),
        ),
        actions: [
          MiuixIconButton(
            onPressed: () => _changeZoom(-_zoomStep),
            child: MiuixIcon(
              icon: Icons.zoom_out_rounded,
              tint: colors.primary,
            ),
          ),
          MiuixText(
            '${(_zoom * 100).round()}%',
            fontSize: 12,
            color: colors.onSurfaceSecondary,
          ),
          MiuixIconButton(
            onPressed: () => _changeZoom(_zoomStep),
            child: MiuixIcon(icon: Icons.zoom_in_rounded, tint: colors.primary),
          ),
        ],
      ),
      content: (padding) => Padding(
        padding: padding,
        child: Column(
          children: [
            Expanded(child: _buildWebView()),
            Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: colors.dividerLine, width: 0.5),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Row(
                  children: [
                    Expanded(
                      child: MiuixText(
                        _status,
                        fontSize: 12,
                        color: colors.onSurfaceSecondary,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_submitting)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      MiuixTextButton(
                        '完成登录',
                        onPressed: () => _submit(),
                        colors: MiuixButtonColors(
                          color: colors.primary,
                          disabledColor: colors.primary,
                          contentColor: Colors.white,
                          disabledContentColor: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWebView() {
    if (!kIsWeb && Platform.isWindows) {
      final controller = _winController;
      if (controller == null) {
        return const Center(child: MiuixCircularProgressIndicator());
      }
      return Webview(controller);
    }
    final controller = _androidController;
    if (controller == null) {
      return const Center(child: MiuixCircularProgressIndicator());
    }
    return WebViewWidget(controller: controller);
  }
}
