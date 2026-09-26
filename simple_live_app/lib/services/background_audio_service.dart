import 'dart:async';

import 'package:flutter/services.dart';

class BackgroundAudioService {
  BackgroundAudioService._();
  static final BackgroundAudioService instance = BackgroundAudioService._();

  static const _channel =
      MethodChannel('com.xycz.simple_live/audio_playback');

  bool _running = false;
  bool get isRunning => _running;

  Future<void> start({
    required String title,
    required String subtitle,
  }) async {
    if (_running) {
      return;
    }
    _running = true;
    await _channel.invokeMethod('start', {
      'title': title,
      'subtitle': subtitle,
    });
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    await _channel.invokeMethod('stop');
  }

  /// 原生侧已自行结束（通知「停止」）时同步状态，不再回调 stop
  void markStopped() {
    _running = false;
  }

  /// Android 13+ 请求通知权限；权限被拒不影响前台服务运行
  Future<void> ensurePermission() async {
    await _channel.invokeMethod('requestNotificationPermission');
  }

  void setStopRequestedHandler(FutureOr<void> Function()? handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') {
        await handler?.call();
      }
    });
  }
}
