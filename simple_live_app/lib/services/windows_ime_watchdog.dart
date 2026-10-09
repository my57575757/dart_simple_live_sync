import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';

// 仅 Windows：IME 输入上下文的预防性生命周期。
//
// Flutter Windows 引擎存在缺陷（flutter/flutter #190042、#191196）：窗口焦点
// 切换 / 应用内文本客户端切换（如弹出弹幕输入框）后，引擎子窗口的
// IMM32↔TSF 会话会陈旧僵死，Windows 不再发送 WM_IME_COMPOSITION，表现为
// 英文数字正常、中文无反应。实验已证明：会话僵死后再替换 HIMC 无法修复它。
// 因此改为预防性方案——文本输入开始（非文本→文本焦点）时经 MethodChannel
// 通知原生侧关联「已打开、中文模式」的自有上下文，文本输入结束时解关联；
// 窗口失焦的 detach 由原生 WM_ACTIVATE 同步处理。频道 simple_live/ime 在
// windows/runner 注册，实际动作经 PostMessage 在窗口线程执行。

const _textFocusDebounceMs = 500;

const _channel = MethodChannel('simple_live/ime');

/// 检测任意 EditableText 焦点边沿（引擎文本客户端切换）。在非文本↔文本
/// 任一方向翻转时返回 true，并对「进入文本」的短时间反复切换防抖。
class TextFocusTransitionMachine {
  bool? _textFocused;
  int? _lastEdgeAt;

  bool poll({required bool textFocused, required int nowMs}) {
    final previous = _textFocused;
    _textFocused = textFocused;
    if (previous == null || previous == textFocused) return false;
    if (textFocused &&
        _lastEdgeAt != null &&
        nowMs - _lastEdgeAt! < _textFocusDebounceMs) {
      _lastEdgeAt = nowMs;
      return false;
    }
    _lastEdgeAt = nowMs;
    return true;
  }
}

class WindowsImeWatchdog extends GetxService {
  final TextFocusTransitionMachine _textFocusMachine =
      TextFocusTransitionMachine();

  Future<void> start() async {
    WidgetsBinding.instance.focusManager.addListener(_onTextFocusChanged);
    // 建立文本焦点基线，否则首次点击输入框因 previous==null 被吞掉
    _textFocusMachine.poll(
      textFocused: _currentFocusIsText(),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  bool _currentFocusIsText() {
    final context =
        WidgetsBinding.instance.focusManager.primaryFocus?.context;
    if (context == null) return false;
    // EditableText 内部用 Focus 承载外部传入的 focusNode，故需向上找
    return context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _onTextFocusChanged() {
    final textFocused = _currentFocusIsText();
    final edge = _textFocusMachine.poll(
      textFocused: textFocused,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (!edge) return;
    unawaited(_invoke(textFocused ? 'attach' : 'detach'));
  }

  /// App 内切换直播间等导航时调用：先解关联，下一次文本焦点会重新 attach。
  /// 组字进行中时原生侧自动跳过，不丢弃在途输入。
  void cycleSession() {
    unawaited(_invoke('detach'));
  }

  Future<void> _invoke(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (e) {
      Log.w('WindowsImeWatchdog invoke $method failed: $e');
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.focusManager.removeListener(_onTextFocusChanged);
    super.onClose();
  }
}
