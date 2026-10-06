import 'dart:async';

/// 播放卡死看门狗。
///
/// libmpv 对部分死流（如 CDN 已关闭 TCP 但播放器未感知）状态机仍停在
/// playing、不发 buffering、也不抛 error/completed，仅靠状态事件无法发现。
/// 唯一可靠信号是播放位置是否持续推进：[isActive] 期间，[position] 在
/// [timeout] 内没有增长即判定卡死，触发 [onTimeout]，由调用方走播放
/// 失败重试 / 重新签发流地址逻辑。
class PlaybackWatchdog {
  PlaybackWatchdog({
    required this.onTimeout,
    required this.isActive,
    required this.position,
    this.timeout = const Duration(seconds: 15),
    this.pollInterval = const Duration(seconds: 5),
  });

  final void Function() onTimeout;

  /// 看门狗是否应生效：前台、直播中且未被用户暂停。
  final bool Function() isActive;

  /// 当前播放位置（mpv time-pos，随流时间戳推进）。
  final Duration Function() position;

  Duration timeout;
  Duration pollInterval;

  Timer? _timer;
  Duration _lastPosition = Duration.zero;
  Duration _stalledFor = Duration.zero;

  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
  }

  void _poll() {
    if (!isActive()) {
      _reset();
      return;
    }

    final pos = position();
    // 尚未起播（首帧前 pos 为 0），不累计。
    if (pos == Duration.zero || pos > _lastPosition) {
      _lastPosition = pos;
      _stalledFor = Duration.zero;
      return;
    }

    _stalledFor += pollInterval;
    if (_stalledFor >= timeout) {
      // 一次性触发后自行停止，由恢复流程在新流打开后重新 start。
      cancel();
      onTimeout();
    }
  }

  void _reset() {
    _lastPosition = Duration.zero;
    _stalledFor = Duration.zero;
  }

  void cancel() {
    _timer?.cancel();
    _timer = null;
    _reset();
  }
}
