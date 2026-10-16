import 'package:simple_live_core/simple_live_core.dart';

/// 网关对单个抖音标签执行账号态动作所需的端口。
///
/// M3 主引擎内由 LiveRoomController 的适配器直接实现（进程内函数调用）；
/// M4 子引擎场景由主引擎侧的 IPC 远端代理实现，控制器侧代码无分支差异。
abstract class DouyinPresenceTab {
  String get tabId;

  /// 控制器是否已销毁（onClose 之后）。网关在 apply* 与启心跳前检查：
  /// 在途进房 HTTP 期间标签被单关（控制器先销毁、release 在串行链上排队）
  /// 时不得再 apply，否则会拉起无人回收的弹幕连接。
  bool get isClosed;

  /// 以账号身份读取房间详情（DouyinSite.getRoomDetail(asAccount:true)）。
  /// 被主播限制等失败由实现方抛出异常，网关据此判定为详情失败。
  Future<LiveRoomDetail> fetchAccountDetail();

  /// guard /api/room/* 所需房间标识，由当前（游客）详情的弹幕参数派生。
  /// 账号详情与游客详情的 roomId/webRid 相同，仅 cookie 不同，
  /// 因此 enterRoom 发生在 applyAccountEnter 之前也能取到正确值。
  String get guardRoomId;
  String get guardWebRid;
  Map<String, dynamic> guardExtraArgs();

  /// 账号进场成功（[reentered]=true 表示关闭新标签后回退接管）：
  /// 停游客弹幕、切换账号详情并重连账号弹幕、应用房间状态位、
  /// 置 presence=account、发系统提示。
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  });

  /// 被更新打开的标签让位：播放不中断，降级游客详情与弹幕（best-effort，
  /// 实现方内部吞异常）并发系统提示。
  Future<void> applyYieldToGuest();

  /// 同账号在外部端进入房间、心跳 inRoom!=true：停止本标签账号态语义，
  /// 不自动抢回；用户后续写动作经 claim 重新进入。
  void applySuspended();
}

/// claim 结果。[detailFailed]=true 表示账号详情读取失败（被限制等），
/// false 表示 guard 未配置 / 进场网络失败；控制器据此选 toast 文案。
class PresenceClaimResult {
  const PresenceClaimResult._(this.granted, this.detailFailed);

  const PresenceClaimResult.granted() : this._(true, false);

  const PresenceClaimResult.failure({required bool detailFailed})
      : this._(false, detailFailed);

  final bool granted;
  final bool detailFailed;
}
