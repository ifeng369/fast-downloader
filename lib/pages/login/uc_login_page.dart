import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../state/uc_state.dart';
import '../../widgets/miuix_common.dart';

/// UC 网盘登录页：Cookie 登录（UC 没有公开的扫码登录接口）。
class UcLoginPage extends StatefulWidget {
  const UcLoginPage({super.key});

  @override
  State<UcLoginPage> createState() => _UcLoginPageState();
}

class _UcLoginPageState extends State<UcLoginPage> {
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: MiuixText(
                'UC 网盘只支持 Cookie 登录。获取方法：\n'
                '1. 电脑浏览器打开 drive.uc.cn 并登录\n'
                '2. 按 F12 → Application → Cookies → https://drive.uc.cn\n'
                '3. 全选所有 Cookie（形如 __pus=xxx; __puus=xxx; ...）复制\n'
                '4. 粘贴到下方输入框（换行会自动清理，直接粘贴即可）\n\n'
                '提示：手机浏览器打开网盘会跳「下载 App」页，请在电脑上获取。\n'
                'Cookie 等同账号登录态，请勿分享给他人。',
                color: colors.onSurfaceSecondary,
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: MiuixTextField(
                  controller: _controller,
                  maxLines: null,
                  minLines: 8,
                  label: '粘贴 Cookie，形如 __pus=xxx; __puus=xxx; ...',
                  useLabelAsPlaceholder: true,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: MiuixText(
                  _error!,
                  color: Colors.redAccent,
                  fontSize: 12,
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
              child: MiuixButton(
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
            ),
          ],
        ),
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
