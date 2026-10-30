/// 前台标签观看会话的幂等编排。
///
/// 直播间控制器只负责上报「此刻是否应给本房间计时」（登录、直播中、
/// 播放器播放中、且本标签为激活标签四个条件的与），本类把状态翻转
/// 转成一次 start / stop 调用：同态不重复发，避免每次播放器状态抖动
/// 都重新 E。
///
/// stop 由 BiliWatchTracker 的 10–60s 防抖接管：切走标签后在防抖窗口
/// 内回来仍延续同一会话（start 命中防抖直接取消补发，不重发 E）。
class BiliWatchSession {
  BiliWatchSession({
    required this.roomId,
    required this.onStart,
    required this.onStop,
  });

  final int roomId;
  final void Function(int roomId) onStart;
  final void Function(int roomId) onStop;

  bool _running = false;
  bool _disposed = false;

  bool get isRunning => _running;

  /// true 表示当前应计时（前台 + 播放中 + 直播中 + 已登录）
  void evaluate(bool shouldRun) {
    if (_disposed || shouldRun == _running) return;
    _running = shouldRun;
    if (shouldRun) {
      onStart(roomId);
    } else {
      onStop(roomId);
    }
  }

  /// 控制器销毁：运行中则补 stop，让 tracker 发出最后一个 X
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_running) {
      _running = false;
      onStop(roomId);
    }
  }
}
