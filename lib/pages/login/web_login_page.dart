import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_windows/webview_flutter_windows.dart';

import '../../api/quark_client.dart';
import '../../api/uc_client.dart';
import '../../state/app_state.dart';
import '../../state/uc_state.dart';

enum WebLoginProvider { quark, uc }

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

  String get _title => _isUc ? '登录 UC 网盘' : '登录夸克网盘';

  String get _ua => _isUc ? UcClient.uaPc : QuarkClient.uaPc;

  String get _loginUrl =>
      _isUc ? 'https://drive.uc.cn/' : 'https://pan.quark.cn/';

  /// 登录态 cookie 名（两家都是 Alibaba 系，均用 __pus）
  String get _sessionCookie => '__pus';

  List<String> get _cookieHosts => _isUc
      ? ['https://drive.uc.cn', 'https://pc-api.uc.cn']
      : ['https://pan.quark.cn', 'https://drive.quark.cn', 'https://pc-api.quark.cn'];

  List<String> get _domainSuffixes => _isUc ? ['uc.cn'] : ['quark.cn'];

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _winController?.dispose();
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
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _applyZoom();
          _checkLogin();
        },
        onWebResourceError: (e) {
          if (e.isForMainFrame ?? true) {
            _setStatus('加载失败：${e.description}');
          }
        },
      ))
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
            "document.body.style.zoom = '${_zoom.toStringAsFixed(2)}';");
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
          byName[part.substring(0, idx).trim()] =
              part.substring(idx + 1).trim();
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
    String header;
    try {
      header = await _readCookieHeader();
    } catch (_) {
      return;
    }
    if (!header.contains('$_sessionCookie=')) return;
    if (header == _lastTried) return; // cookie 没变就不重复校验
    _lastTried = header;
    await _submit(header);
  }

  Future<void> _submit([String? header]) async {
    if (_submitting || _done) return;
    setState(() => _submitting = true);
    try {
      final cookie = header ?? await _readCookieHeader();
      if (cookie.isEmpty) {
        _setStatus('还没有读到 Cookie，请先在页面里完成登录');
        return;
      }
      final err = _isUc
          ? await UcState.I.login(cookie)
          : await AppState.I.login(cookie);
      if (err == null) {
        _done = true;
        _poll?.cancel();
        if (mounted) Navigator.of(context).maybePop(true);
        return;
      }
      _setStatus('已读取 Cookie，但校验失败：$err');
    } catch (e) {
      _setStatus('读取 Cookie 失败：$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
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
              size: 20),
        ),
        actions: [
          MiuixIconButton(
            onPressed: () => _changeZoom(-_zoomStep),
            child: MiuixIcon(icon: Icons.zoom_out_rounded, tint: colors.primary),
          ),
          MiuixText('${(_zoom * 100).round()}%',
              fontSize: 12, color: colors.onSurfaceSecondary),
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
                    top: BorderSide(color: colors.dividerLine, width: 0.5)),
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
