import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 修复 flutter_miuix 1.4.0 的占位提示 bug：
/// `useLabelAsPlaceholder: true` 时输入文字后 label 不会隐藏
/// （库内 `_onTextChanged` 只驱动动画控制器，文本从空变非空不会触发 rebuild），
/// 导致提示文字与已输入内容重叠。
///
/// 这里监听 controller，文本非空时把 label 置空以强制隐藏，空时恢复显示。
class MiuixLabelField extends StatefulWidget {
  const MiuixLabelField({
    super.key,
    required this.controller,
    required this.label,
    this.singleLine = false,
    this.maxLines,
    this.minLines,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
    this.leadingIcon,
    this.trailingIcon,
    this.textStyle,
    this.insideMargin,
  });

  final TextEditingController controller;
  final String label;
  final bool singleLine;
  final int? maxLines;
  final int? minLines;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Widget? leadingIcon;
  final Widget? trailingIcon;
  final TextStyle? textStyle;
  final EdgeInsets? insideMargin;

  @override
  State<MiuixLabelField> createState() => _MiuixLabelFieldState();
}

class _MiuixLabelFieldState extends State<MiuixLabelField> {
  bool _empty = true;

  @override
  void initState() {
    super.initState();
    _empty = widget.controller.text.isEmpty;
    widget.controller.addListener(_onText);
  }

  @override
  void didUpdateWidget(MiuixLabelField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onText);
      widget.controller.addListener(_onText);
      _empty = widget.controller.text.isEmpty;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onText);
    super.dispose();
  }

  void _onText() {
    final empty = widget.controller.text.isEmpty;
    if (empty != _empty) setState(() => _empty = empty);
  }

  @override
  Widget build(BuildContext context) {
    return MiuixTextField(
      controller: widget.controller,
      label: _empty ? widget.label : '',
      useLabelAsPlaceholder: true,
      singleLine: widget.singleLine,
      maxLines: widget.maxLines,
      minLines: widget.minLines,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      textInputAction: widget.textInputAction,
      autofocus: widget.autofocus,
      onChanged: widget.onChanged,
      onSubmitted: widget.onSubmitted,
      leadingIcon: widget.leadingIcon,
      trailingIcon: widget.trailingIcon,
      textStyle: widget.textStyle,
      insideMargin: widget.insideMargin ?? MiuixTextFieldDefaults.insideMargin,
    );
  }
}
