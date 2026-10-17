/// 控制器对抖音 presence 的唯一依赖面：主引擎内由 LocalPresenceClient
/// 直接函数调用实现，子引擎由 IPC proxy 实现，控制器调用点无分支。
library;

/// claim 失败原因。ipcFailed 仅子端本地产生（invoke 抛错/主窗无响应），
/// 主端永远不会回它；其余四值由主引擎网关产生、经 IPC 下行。
enum PresenceFailureReason {
  notLoggedIn,
  notConfigured,
  detailFailed,
  enterFailed,
  ipcFailed,
}

/// claim 结果：granted=true 时 reason 为 null；失败必带 reason。
class PresenceClaimResult {
  const PresenceClaimResult._(this.granted, this.reason);

  const PresenceClaimResult.granted() : this._(true, null);

  const PresenceClaimResult.failure({required PresenceFailureReason reason})
      : this._(false, reason);

  final bool granted;
  final PresenceFailureReason? reason;
}

/// pr_guard_send / 网关写动作回执码。
const String kPresenceCodeNotHolder = 'not_holder';
const String kPresenceCodeNotLogin = 'not_login';

/// 弹幕/互动写动作结果。not_holder 表示本标签已不是仲裁持有者，
/// 控制器据此让位给一次重新 claim + 重发。
class PresenceSendResult {
  const PresenceSendResult({
    required this.success,
    this.code,
    this.message,
  });

  final bool success;
  final String? code;
  final String? message;

  static const PresenceSendResult notHolder = PresenceSendResult(
    success: false,
    code: kPresenceCodeNotHolder,
  );
}

abstract class PresenceClient {
  Future<PresenceClaimResult> claim();
  Future<void> release();
  Future<void> detach();

  /// 本标签当前是否仍在仲裁意图栈中（承接旧 gateway.hasClaim 判定）。
  bool get isClaimed;

  Future<PresenceSendResult> sendDanmaku(String content);
  Future<PresenceSendResult> sendAction(String action);
}
