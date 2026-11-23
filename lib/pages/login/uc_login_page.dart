import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../state/uc_state.dart';
import '../../widgets/miuix_common.dart';
import 'web_login_page.dart';

/// UC 网盘登录页（与夸克登录页同款布局）：网页登录（默认）+ Cookie 登录。
class UcLoginPage extends StatefulWidget {
  const UcLoginPage({super.key});

  @override
  State<UcLoginPage> createState() => _UcLoginPageState();
}

class _UcLoginPageState extends State<UcLoginPage> {
  /// 默认选中「网页登录」（第 2 个 Tab）
  int _tabIndex = 1;

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return MiuixScaffold(
      topBar: MiuixTopAppBar(
        title: '登录 UC 网盘',
        navigationIcon: MiuixIconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: MiuixIcon(
              icon: Icons.arrow_back_ios_new_rounded,
              tint: colors.onSurfaceContainer,
              size: 20),
        ),
      ),
      content: (padding) => Padding(
        padding: padding,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: MiuixTabRow(
                tabs: const ['Cookie 登录', '网页登录'],
                selectedTabIndex: _tabIndex,
                onTabSelected: (i) => setState(() => _tabIndex = i),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _tabIndex,
                children: const [
                  _CookieLoginView(),
                  _WebLoginEntry(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CookieLoginView extends StatefulWidget {
  const _CookieLoginView();

  @override
  State<_CookieLoginView> createState() => _CookieLoginViewState();
}

class _CookieLoginViewState extends State<_CookieLoginView> {
  final _controller = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MiuixText(
            '从电脑浏览器登录 drive.uc.cn，按 F12 → Application → Cookies '
            '复制全部 Cookie 粘贴到这里（网页登录失败时的备用方式）',
            color: colors.onSurfaceSecondary,
            fontSize: 12,
          ),
          const SizedBox(height: 14),
          Expanded(
            child: MiuixLabelField(
              controller: _controller,
              maxLines: null,
              minLines: 6,
              label: '粘贴 Cookie，形如 __pus=xxx; __puus=xxx; ...',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            MiuixText(
              _error!,
              color: Colors.redAccent,
              fontSize: 12,
            ),
          ],
          const SizedBox(height: 16),
          MiuixButton(
            onPressed: _submitting ? null : _submit,
            colors: MiuixButtonColors(
              color: colors.primary,
              disabledColor: colors.primary,
              contentColor: Colors.white,
              disabledContentColor: Colors.white,
            ),
            child: _submitting
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: MiuixCircularProgressIndicator(
                        size: 16,
                        colors: MiuixProgressIndicatorColors(
                          foregroundColor: Colors.white,
                          disabledForegroundColor: Colors.white,
                          backgroundColor: Colors.white24,
                        )),
                  )
                : MiuixText('登录', color: Colors.white, fontSize: 15),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty) {
      setState(() => _error = '请先粘贴 Cookie');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final err = await UcState.I.login(raw);
      if (!mounted) return;
      if (err == null) {
        Navigator.of(context).pop(true);
        return;
      }
      setState(() => _error = err);
      _toast('登录失败: $err');
    } catch (e) {
      // 兜底：任何异常都就地显示，避免"点了没反应"
      if (mounted) setState(() => _error = '登录异常: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    MiuixToast.show(msg);
  }
}

/// 「网页登录」入口：在应用内打开 UC 网盘电脑版登录页，登录后自动读取 Cookie。
class _WebLoginEntry extends StatelessWidget {
  const _WebLoginEntry();

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final supported = !kIsWeb && (Platform.isAndroid || Platform.isWindows);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixText(
              supported
                  ? '在应用内打开 UC 网盘电脑版登录页，登录成功后自动读取 Cookie。\n'
                      '比手动粘贴更稳：电脑退出账号也不影响应用里的登录态。'
                  : '当前平台不支持自动读取 Cookie，请使用「Cookie 登录」。',
              color: colors.onSurfaceSecondary,
              fontSize: 12,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 18),
            if (supported)
              MiuixButton(
                onPressed: () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                        builder: (_) =>
                            const WebLoginPage(provider: WebLoginProvider.uc)),
                  );
                  if (ok == true && context.mounted) {
                    Navigator.of(context).pop(true);
                  }
                },
                colors: MiuixButtonColors(
                  color: colors.primary,
                  disabledColor: colors.primary,
                  contentColor: Colors.white,
                  disabledContentColor: Colors.white,
                ),
                child: MiuixText('打开网页登录', color: Colors.white, fontSize: 15),
              ),
          ],
        ),
      ),
    );
  }
}
