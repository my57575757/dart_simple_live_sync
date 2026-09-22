import 'dart:async';

import 'package:simple_live_core/src/model/live_message.dart';

class DanmakuSendResult {
  final bool success;
  final String errorCode;
  final String errorMessage;

  /// 服务器不回环自身消息时为 true（Twitch），由本地插入消息
  final bool needLocalEcho;

  DanmakuSendResult({
    required this.success,
    this.errorCode = "",
    this.errorMessage = "",
    this.needLocalEcho = false,
  });
}

class LiveDanmaku {
  Function(LiveMessage msg)? onMessage;
  Function(String msg)? onClose;
  Function()? onReady;

  /// 心跳时间
  int heartbeatTime = 0;

  /// 发生心跳
  void heartbeat() {}

  /// 开始接收信息
  Future start(dynamic args) {
    return Future.value();
  }

  /// 停止接收信息
  Future stop() {
    return Future.value();
  }

  /// 发送弹幕
  Future<DanmakuSendResult> sendMessage(String message) {
    return Future.value(
      DanmakuSendResult(success: false, errorCode: "not_supported"),
    );
  }
}
