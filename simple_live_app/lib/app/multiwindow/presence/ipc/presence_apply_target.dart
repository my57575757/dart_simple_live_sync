import 'package:simple_live_core/simple_live_core.dart';

/// 子引擎侧可接收主端 presence apply 的目标（LiveRoomController 实现）。
/// 抽成独立接口：IpcPresenceCoordinator 依赖它而非具体控制器，单测可注入
/// 假目标，避免构造真实 LiveRoomController 触网取房间详情。
abstract class PresenceApplyTarget {
  Future<LiveRoomDetail> fetchAccountDetail();

  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  });

  Future<void> applyYieldToGuest();

  Future<void> applySuspended();
}
