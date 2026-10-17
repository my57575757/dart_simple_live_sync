/// WindowOpenService 对账号面无缝迁移能力的窄依赖：窗口层不具体依赖
/// presence/ipc 的 MainPresenceService。生产实现为 MainPresenceService，
/// 单测用内存 fake。
abstract class PresenceHandoffController {
  /// tab 未被 presence 跟踪（非抖音/未绑定）时返回 null，壳流程不等；
  /// 否则返回在目标窗 register 驱动 rehome（或 rehomeLocal）时结算的
  /// Future，10s 超时以异常失败，编排层按 spec §8 收口。
  Future<void>? prepareHandoff(String tabId, String destWindowId);

  /// 目标为主窗：摘远端死亡索引，并驱动网关把 tabId 端口换给主窗
  /// 本地控制器（控制器 onInit 的 bindTab 已先行完成）。
  Future<void> rehomeLocal(String tabId);
}
