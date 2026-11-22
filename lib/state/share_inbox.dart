import 'package:flutter/foundation.dart';

/// 系统分享 / 外部链接进入 App 的待处理文本（如 UC 分享链接 + 提取码）。
///
/// 原生侧把文本暂存，Dart 启动/回到前台时取出并 push 到这里；
/// 解析页监听 [pending]，拿到后填入输入框；[tabRequest] 用来把底部导航切到「解析」。
class ShareInbox {
  ShareInbox._();

  static final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  /// 请求切换底部页签（0 = 解析）
  static final ValueNotifier<int> tabRequest = ValueNotifier<int>(0);

  static void push(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return;
    pending.value = text;
    tabRequest.value = 0;
  }

  /// 由解析页调用：取走文本（取走后清空，避免重复填充）
  static String? take() {
    final v = pending.value;
    pending.value = null;
    return v;
  }
}
