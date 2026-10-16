import 'douyin_presence_gateway.dart';
import 'presence_claimant.dart';

/// 主引擎内的控制器侧薄代理：直接函数调用。
/// M4 子引擎场景替换为 IPC 实现，控制器侧调用点不变。
class LocalPresenceClient {
  LocalPresenceClient(this._gateway, this._tab);

  final DouyinPresenceGateway _gateway;
  final DouyinPresenceTab _tab;

  Future<PresenceClaimResult> claim() => _gateway.claim(_tab);

  Future<void> release() => _gateway.release(_tab.tabId);

  Future<void> detach() => _gateway.detach(_tab.tabId);
}
