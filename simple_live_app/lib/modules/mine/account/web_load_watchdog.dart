/// WebView 白屏看门狗（纯状态机，时间由调用方注入，每秒 poll 一次）。
///
/// 2026-10-13 事故：Windows 上 WebView2 环境一次性创建失败，原生侧不发
/// onWebViewCreated 也不发任何 error 事件，页面只能纯白、用户只能盲目重启。
/// 此状态机不依赖任何 WebView 回调必然到达：超时等不到关键信号即判失败。
enum WebLoadPhase { starting, loading, ready, failed }

class WebLoadWatchdog {
  WebLoadWatchdog({
    this.initTimeoutMs = 8000,
    this.navTimeoutMs = 15000,
    this.readyOnFirstStart = false,
  });

  /// 等 onWebViewCreated 的最长时间（WebView2 环境创建）
  final int initTimeoutMs;

  /// created/loadStart 后等首个加载结果的最长时间
  final int navTimeoutMs;

  /// redirect 提取模式（Twitch）：onLoadStop 不保证触发，首个 loadStart 即成功
  final bool readyOnFirstStart;

  static const int maxAttempts = 3;

  WebLoadPhase phase = WebLoadPhase.starting;
  String? failReason;
  int attempt = 0;

  int? _sinceMs;

  void start(int nowMs) {
    phase = WebLoadPhase.starting;
    failReason = null;
    _sinceMs = nowMs;
  }

  void markCreated(int nowMs) {
    if (phase != WebLoadPhase.starting) return;
    phase = WebLoadPhase.loading;
    _sinceMs = nowMs;
  }

  void markLoadStart(int nowMs) {
    if (phase == WebLoadPhase.ready || phase == WebLoadPhase.failed) return;
    if (readyOnFirstStart) {
      phase = WebLoadPhase.ready;
      _sinceMs = null;
      return;
    }
    phase = WebLoadPhase.loading;
    _sinceMs = nowMs;
  }

  void markLoadStop() {
    if (phase == WebLoadPhase.ready || phase == WebLoadPhase.failed) return;
    if (readyOnFirstStart) return;
    phase = WebLoadPhase.ready;
    _sinceMs = null;
  }

  void markFatal([String reason = 'network']) {
    if (phase == WebLoadPhase.ready || phase == WebLoadPhase.failed) return;
    phase = WebLoadPhase.failed;
    failReason = reason;
    _sinceMs = null;
  }

  /// 发生 starting/loading → failed 转换的那一次返回 true
  bool poll(int nowMs) {
    if (phase != WebLoadPhase.starting && phase != WebLoadPhase.loading) {
      return false;
    }
    final since = _sinceMs;
    if (since == null) return false;
    final wasStarting = phase == WebLoadPhase.starting;
    final timeout = wasStarting ? initTimeoutMs : navTimeoutMs;
    if (nowMs - since < timeout) return false;
    phase = WebLoadPhase.failed;
    failReason = wasStarting ? 'init' : 'nav';
    _sinceMs = null;
    return true;
  }

  bool get canRetry => attempt < maxAttempts - 1;

  /// 仅首次失败自动重建（事故中重开 App 即恢复，页内重建先低成本试一次）
  bool get shouldAutoRetry => phase == WebLoadPhase.failed && attempt == 0;

  void retry(int nowMs) {
    if (phase != WebLoadPhase.failed || !canRetry) return;
    attempt++;
    start(nowMs);
  }
}
