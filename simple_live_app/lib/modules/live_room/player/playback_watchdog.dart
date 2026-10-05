import 'dart:async';

/// 播放缓冲看门狗：进入缓冲后若超过 [timeout] 仍未播放，
/// 且没有任何 error/completed 事件（libmpv 对部分死流只停在 buffering），
/// 触发 [onTimeout]，由调用方走播放失败重试/切线路逻辑。
class PlaybackWatchdog {
  PlaybackWatchdog({
    required this.onTimeout,
    required this.isPlaying,
    required this.isActive,
    this.timeout = const Duration(seconds: 15),
  });

  final void Function() onTimeout;
  final bool Function() isPlaying;

  /// 看门狗是否应生效：前台且直播中
  final bool Function() isActive;

  Duration timeout;

  Timer? _timer;

  void onBufferingChanged(bool buffering) {
    if (buffering && isActive()) {
      arm();
    } else {
      cancel();
    }
  }

  void onPlayingChanged(bool playing) {
    if (playing) cancel();
  }

  void arm() {
    _timer?.cancel();
    _timer = Timer(timeout, () {
      _timer = null;
      if (!isActive() || isPlaying()) return;
      onTimeout();
    });
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
  }
}
