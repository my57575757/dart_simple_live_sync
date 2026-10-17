import 'douyin_presence_gateway.dart';
import 'presence_client.dart';
import 'presence_claimant.dart';

/// 主引擎内的控制器侧薄代理：直接函数调用。
/// 子引擎场景替换为 IPC 实现，控制器侧调用点不变。
class LocalPresenceClient implements PresenceClient {
  LocalPresenceClient(this._gateway, this._tab);

  final DouyinPresenceGateway _gateway;
  final DouyinPresenceTab _tab;

  @override
  Future<PresenceClaimResult> claim() => _gateway.claim(_tab);

  @override
  Future<void> release() => _gateway.release(_tab.tabId);

  @override
  Future<void> detach() => _gateway.detach(_tab.tabId);

  @override
  bool get isClaimed => _gateway.hasClaim(_tab.tabId);

  @override
  Future<PresenceSendResult> sendDanmaku(String content) =>
      _gateway.sendDanmakuAsHolder(tabId: _tab.tabId, content: content);

  @override
  Future<PresenceSendResult> sendAction(String action) =>
      _gateway.sendActionAsHolder(tabId: _tab.tabId, action: action);
}
