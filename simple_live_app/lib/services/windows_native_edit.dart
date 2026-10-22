import 'dart:async';

import 'package:flutter/services.dart';
import 'package:simple_live_app/app/log.dart';

/// 全局逻辑坐标（相对 Flutter 视图客户区原点）与逻辑尺寸 → 物理像素矩形。
/// 引擎子窗口铺满客户区、原点 0,0，故逻辑坐标乘 devicePixelRatio 即可。
Rect nativeEditPhysicalRect({
  required Offset globalLogicalOrigin,
  required Size logicalSize,
  required double devicePixelRatio,
}) {
  return Rect.fromLTWH(
    globalLogicalOrigin.dx * devicePixelRatio,
    globalLogicalOrigin.dy * devicePixelRatio,
    logicalSize.width * devicePixelRatio,
    logicalSize.height * devicePixelRatio,
  );
}

/// Windows 弹幕原生 EDIT 的 MethodChannel 单例。
/// 横竖屏两个 SendDanmakuBar 可能同时挂载，频道同名，单例避免回调互相覆盖。
class WindowsNativeEdit {
  WindowsNativeEdit._();
  static final WindowsNativeEdit instance = WindowsNativeEdit._();

  static const MethodChannel _channel =
      MethodChannel('simple_live/native_edit');
  bool _handlerInstalled = false;

  /// EDIT 中按 Enter（非组字状态）时回调，参数为当前文本。
  void Function(String text)? onSubmit;

  /// EDIT 被 Esc 隐藏时回调。
  void Function()? onClosed;

  Future<dynamic> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'submit':
        onSubmit?.call(call.arguments as String);
        break;
      case 'closed':
        onClosed?.call();
        break;
    }
    return null;
  }

  // 通道失败只记日志：最坏退化为弹幕框点了无反应，绝不让异常冒出 GestureDetector。
  Future<void> _silent(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      Log.w('WindowsNativeEdit channel call failed: $e');
    }
  }

  Future<void> show({
    required Rect rect,
    required double fontSizePx,
    required int bgColor,
    required int textColor,
    required int hintColor,
    required int radiusPx,
    required int padXPx,
    required String hintText,
    required String text,
  }) {
    if (!_handlerInstalled) {
      _channel.setMethodCallHandler(_handleCall);
      _handlerInstalled = true;
    }
    return _silent(() => _channel.invokeMethod<void>('show', <String, dynamic>{
          'x': rect.left.round(),
          'y': rect.top.round(),
          'w': rect.width.round(),
          'h': rect.height.round(),
          'fontSize': fontSizePx,
          'bg': bgColor,
          'textColor': textColor,
          'hintColor': hintColor,
          'radius': radiusPx,
          'padX': padXPx,
          'hint': hintText,
          'text': text,
        }));
  }

  Future<void> hide() => _silent(() => _channel.invokeMethod<void>('hide'));

  /// 多标签/首页切换时挂起当前输入会话：隐藏常驻 popup、把键盘焦点还给引擎窗口、
  /// 释放全局回调，并经 closed 通知持有会话的输入框同步草稿、回到未激活态。
  ///
  /// 本服务是进程单例、只有一组回调，而壳内 IndexedStack 使所有房间/搜索输入框
  /// 常驻挂载；切标签时旧房间 popup 只被 Offstage 遮挡仍持键盘焦点，不挂起则
  /// 回车会经旧 EDIT → 单例回调送进已切走的房间（弹幕串房）。
  void suspendSession() {
    final closed = onClosed;
    if (onSubmit == null && closed == null) {
      return;
    }
    onSubmit = null;
    onClosed = null;
    unawaited(hide());
    closed?.call();
  }

  Future<void> setText(String text) =>
      _silent(() => _channel.invokeMethod<void>('setText', text));

  Future<String> commit() async {
    try {
      return (await _channel.invokeMethod<String>('commit')) ?? '';
    } catch (e) {
      Log.w('WindowsNativeEdit commit failed: $e');
      return '';
    }
  }
}
