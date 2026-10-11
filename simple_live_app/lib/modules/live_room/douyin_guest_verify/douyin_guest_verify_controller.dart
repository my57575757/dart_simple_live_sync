import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

/// 远程滑块验证：guard 在它自己的 anonymous Chrome（与取房同一持久 profile、
/// 同一 cookie jar、同一 IP）里打开真实房间页，本页只显示 JPEG 截图并把指针
/// 轨迹回传。滑块通过后 trust 天然落在取房浏览器内，由 guard 自验取房成功
/// 才置 verified——不再有「本地浏览器滑、guard 换指纹重放 cookie」的错配。
class DouyinGuestVerifyController extends GetxController {
  DouyinGuestVerifyController({GuardServerService? guard})
      : _guard = guard ?? GuardServerService.instance;

  final GuardServerService _guard;

  late final String webRid;

  String _sessionId = "";
  int _viewWidth = 1280;
  int _viewHeight = 800;

  final Rx<Uint8List?> frame = Rx<Uint8List?>(null);
  final RxString state = "starting".obs;
  final RxString phase = "loading".obs;
  final RxString reason = "".obs;
  final RxInt remainingMs = 0.obs;

  /// 启动会话/首帧前的加载态
  final RxBool starting = true.obs;
  /// 会话打开失败 / expired / 浏览器断连等终态，展示「重新开始 / 取消」
  final RxString fatalMessage = "".obs;
  /// 连续拉帧失败：画面中断但会话可能仍在，展示重试入口
  final RxBool frameBroken = false.obs;
  /// 拖动时本地跟手圆点（缓解 ~300ms 画面延迟）
  final Rx<OffsetLite?> finger = Rx<OffsetLite?>(null);

  Timer? _frameTimer;
  Timer? _statusTimer;
  Timer? _moveFlushTimer;
  bool _frameInFlight = false;
  bool _statusInFlight = false;
  bool _closed = false;
  bool _succeeded = false;
  int _lastSeq = 0;
  int _frameFailures = 0;
  int _sessionEpoch = 0;

  static const Duration _frameInterval = Duration(milliseconds: 160);
  static const Duration _statusInterval = Duration(seconds: 1);
  static const Duration _moveFlushInterval = Duration(milliseconds: 66);
  static const int _maxFrameFailures = 8;
  static const int _moveCap = 40;
  static const int _serverEventCap = 60;

  final List<VerifyPointerEvent> _moves = [];
  Future<void> _sendChain = Future.value();

  String get sessionId => _sessionId;
  int get viewWidth => _viewWidth;
  int get viewHeight => _viewHeight;
  bool get isVerifying => state.value == "verifying";
  bool get hasFrame => frame.value != null && frame.value!.isNotEmpty;

  @override
  void onInit() {
    super.onInit();
    webRid = Get.arguments.toString();
    startSession();
  }

  Future<void> startSession() async {
    final epoch = ++_sessionEpoch;
    starting.value = true;
    fatalMessage.value = "";
    frameBroken.value = false;
    frame.value = null;
    state.value = "starting";
    phase.value = "loading";
    reason.value = "";
    _lastSeq = 0;
    _frameFailures = 0;
    _moves.clear();
    _stopLoops();

    DouyinVerifySession session;
    try {
      session = await _guard.startVerifySession(webRid);
    } catch (e) {
      if (epoch != _sessionEpoch || _closed) return;
      Log.logPrint("打开远程验证会话失败：$e");
      state.value = "closed";
      reason.value = "load_failed";
      fatalMessage.value = _friendlyError(e);
      starting.value = false;
      return;
    }
    if (epoch != _sessionEpoch || _closed) return;

    _sessionId = session.sessionId;
    _viewWidth = session.viewWidth;
    _viewHeight = session.viewHeight;
    state.value = "active";
    starting.value = false;

    _frameTimer = Timer.periodic(_frameInterval, (_) => _pullFrame(epoch));
    _statusTimer = Timer.periodic(_statusInterval, (_) => _pullStatus(epoch));
    _moveFlushTimer = Timer.periodic(_moveFlushInterval, (_) => _flushMoves());
    // 立刻拉首帧，不必等第一个周期
    unawaited(_pullFrame(epoch));
    unawaited(_pullStatus(epoch));
  }

  Future<void> _pullFrame(int epoch) async {
    if (_frameInFlight || _closed || _sessionId.isEmpty) return;
    _frameInFlight = true;
    try {
      final f = await _guard.verifySessionFrame(_sessionId);
      if (epoch != _sessionEpoch || _closed) return;
      if (!f.isEmpty && f.seq != _lastSeq) {
        _lastSeq = f.seq;
        frame.value = f.bytes;
      }
      _frameFailures = 0;
      frameBroken.value = false;
      if (f.state.isNotEmpty && f.state != state.value) {
        state.value = f.state;
      }
    } catch (e) {
      if (epoch != _sessionEpoch || _closed) return;
      if (e is VerifySessionHttpException && e.isClosed) {
        // 终态交给 status 循环收口，帧循环静默
        return;
      }
      _frameFailures++;
      if (_frameFailures >= _maxFrameFailures) {
        frameBroken.value = true;
      }
    } finally {
      _frameInFlight = false;
    }
  }

  Future<void> _pullStatus(int epoch) async {
    if (_statusInFlight || _closed || _sessionId.isEmpty) return;
    _statusInFlight = true;
    try {
      final s = await _guard.verifySessionStatus(_sessionId);
      if (epoch != _sessionEpoch || _closed) return;
      phase.value = s.phase;
      remainingMs.value = s.remainingMs;
      if (s.reason.isNotEmpty) reason.value = s.reason;
      state.value = s.state;
      switch (reduceStatus(s)) {
        case VerifyUiAction.succeed:
          _finishSuccess();
          break;
        case VerifyUiAction.closeCanceled:
          _finishCanceled();
          break;
        case VerifyUiAction.showRetry:
          _enterFatal(_terminalReasonText(s.reason));
          break;
        case VerifyUiAction.stay:
          break;
      }
    } catch (_) {
      // 状态轮询偶发失败不致命：帧通道仍在就继续，连续失败由帧侧兜底
    } finally {
      _statusInFlight = false;
    }
  }

  void _enterFatal(String message) {
    fatalMessage.value = message;
    _stopLoops();
  }

  void _finishSuccess() {
    if (_succeeded || _closed) return;
    _succeeded = true;
    _closed = true;
    _stopLoops();
    Get.back(result: true);
  }

  void _finishCanceled() {
    if (_closed) return;
    _closed = true;
    _stopLoops();
    Get.back(result: false);
  }

  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    _stopLoops();
    if (_sessionId.isNotEmpty) {
      try {
        await _guard.cancelVerifySession(_sessionId);
      } catch (_) {
        // 退出不依赖服务端确认
      }
    }
    if (!_succeeded) Get.back(result: false);
  }

  /// expired / 浏览器断连 / 页面崩溃后由用户点「重新开始」开新会话
  Future<void> retry() => startSession();

  Future<void> reload() async {
    if (_sessionId.isEmpty) return;
    try {
      await _guard.reloadVerifySession(_sessionId);
      frame.value = null;
      _frameFailures = 0;
      frameBroken.value = false;
      unawaited(_pullFrame(_sessionEpoch));
    } catch (e) {
      Log.logPrint("重新加载验证页失败：$e");
    }
  }

  void _stopLoops() {
    _frameTimer?.cancel();
    _statusTimer?.cancel();
    _moveFlushTimer?.cancel();
    _frameTimer = null;
    _statusTimer = null;
    _moveFlushTimer = null;
  }

  @override
  void onClose() {
    _stopLoops();
    // 路由被系统返回等路径关掉而非 success/cancel：best-effort 通知服务端
    if (!_succeeded && !_closed && _sessionId.isNotEmpty) {
      _guard.cancelVerifySession(_sessionId).catchError((_) {});
    }
    super.onClose();
  }

  // ===== 指针轨迹 =====

  void onPointerDown(OffsetLite local, SizeLite box) {
    if (!_inputOpen) return;
    finger.value = local;
    _chainSend([
      mapPoint("down", local, box, _viewWidth, _viewHeight),
    ]);
  }

  void onPointerMove(OffsetLite local, SizeLite box, {required bool down}) {
    if (!_inputOpen) return;
    if (!down) return; // 鼠标悬停轨迹不转发
    finger.value = local;
    _moves.add(mapPoint("move", local, box, _viewWidth, _viewHeight));
    if (_moves.length > _moveCap) {
      final compressed = compressEvents(_moves, _moveCap);
      _moves
        ..clear()
        ..addAll(compressed);
    }
  }

  void onPointerUp(OffsetLite local, SizeLite box) {
    if (!_inputOpen) return;
    finger.value = null;
    final batch = _drainMoves();
    batch.add(mapPoint("up", local, box, _viewWidth, _viewHeight));
    _chainSend(batch);
  }

  void onPointerScroll(
    OffsetLite local,
    SizeLite box, {
    required double dx,
    required double dy,
  }) {
    if (!_inputOpen) return;
    final ev = mapPoint(
      "wheel",
      local,
      box,
      _viewWidth,
      _viewHeight,
      dx: dx,
      dy: dy,
    );
    _chainSend([ev]);
  }

  bool get _inputOpen =>
      !_closed && state.value == "active" && _sessionId.isNotEmpty;

  List<VerifyPointerEvent> _drainMoves() {
    final out = List<VerifyPointerEvent>.from(_moves);
    _moves.clear();
    return out;
  }

  void _flushMoves() {
    if (_closed || _moves.isEmpty) return;
    // 单批硬上限 60：网络堆积时只发最新一批
    final batch = compressEvents(_drainMoves(), _serverEventCap);
    _chainSend(batch);
  }

  void _chainSend(List<VerifyPointerEvent> events) {
    if (events.isEmpty || _sessionId.isEmpty) return;
    final id = _sessionId;
    // 串行链：down/moves/up 严格按产生顺序到达，不互相超车
    _sendChain = _sendChain.then((_) async {
      try {
        await _guard.sendVerifyEvents(id, events);
      } catch (e) {
        Log.logPrint("验证指针事件发送失败：$e");
      }
    });
  }

  /// 本地显示坐标 → guard 视口像素的线性换算并截断到视口内
  @visibleForTesting
  static VerifyPointerEvent mapPoint(
    String type,
    OffsetLite local,
    SizeLite box,
    int viewWidth,
    int viewHeight, {
    double dx = 0,
    double dy = 0,
  }) {
    final sx = box.width <= 0 ? 0.0 : local.x / box.width;
    final sy = box.height <= 0 ? 0.0 : local.y / box.height;
    final x = clampDouble(sx * viewWidth, 0, viewWidth.toDouble());
    final y = clampDouble(sy * viewHeight, 0, viewHeight.toDouble());
    return VerifyPointerEvent(type, x: x, y: y, dx: dx, dy: dy);
  }

  /// 轨迹压缩：超 max 时保留最早的 1/4（轨迹起点对滑块识别关键）+ 最新的 3/4
  @visibleForTesting
  static List<VerifyPointerEvent> compressEvents(
    List<VerifyPointerEvent> events,
    int max,
  ) {
    if (events.length <= max) return events;
    final head = math.max(1, max ~/ 4);
    final tail = max - head;
    return <VerifyPointerEvent>[
      ...events.take(head),
      ...events.skip(events.length - tail),
    ];
  }

  @visibleForTesting
  static VerifyUiAction reduceStatus(DouyinVerifyStatus s) {
    if (s.isVerified) return VerifyUiAction.succeed;
    if (s.isClosed) {
      if (s.reason == "canceled") return VerifyUiAction.closeCanceled;
      return VerifyUiAction.showRetry;
    }
    return VerifyUiAction.stay;
  }

  static String _terminalReasonText(String reason) {
    switch (reason) {
      case "expired":
        return "验证超时（5 分钟），请重新开始";
      case "browser_disconnected":
        return "guard 浏览器连接中断，请重新开始";
      case "page_crashed":
        return "验证页崩溃，请重新开始";
      case "load_failed":
        return "验证页打开失败，请检查 guard 服务后重试";
      default:
        return "验证已结束，请重新开始";
    }
  }

  static String _friendlyError(Object e) {
    final raw = e.toString();
    final msg = raw.startsWith("Exception: ") ? raw.substring(11) : raw;
    return msg.isEmpty ? "验证页打开失败" : msg;
  }

  static double clampDouble(double v, double min, double max) =>
      v < min ? min : (v > max ? max : v);
}

enum VerifyUiAction { succeed, closeCanceled, showRetry, stay }

/// 不依赖 dart:ui 的轻量几何类型，便于纯单测
class OffsetLite {
  final double x;
  final double y;
  const OffsetLite(this.x, this.y);
}

class SizeLite {
  final double width;
  final double height;
  const SizeLite(this.width, this.height);
}
