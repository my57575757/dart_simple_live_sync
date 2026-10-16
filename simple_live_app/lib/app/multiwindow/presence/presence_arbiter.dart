/// 抖音账号在场意图栈的纯状态机（无 Flutter / GetX / HTTP 依赖）。
///
/// 规则（设计文档 7.3）：
/// - 意图有序，新意图在栈尾，栈尾即最新打开、即心跳持有者；
/// - claim 幂等：已在栈中则移到栈尾（"提到最新"）并清除其 suspended；
/// - release（关标签）：持有者发 exit 并回退栈尾次新接管；非持有者仅出栈；
/// - detach（跨窗移动）：同 release 但持有者不发 exit（M4 接线，目标窗
///   attach 后以同一 tabId 重新 claim）；
/// - 外部端抢占 markSuspended：仅暂停持有者，不自动抢回 / 不回退；
///   回退落到 suspended 标签时清除 suspended 并重新 enter。
class PresenceTransition {
  const PresenceTransition({this.enters, this.exits, this.yields});

  /// 需执行 enterRoom 并接管心跳的 tabId
  final String? enters;

  /// 需发 exitRoom 的 tabId（仅 close 路径的原持有者）
  final String? exits;

  /// 需降级为游客的原持有者（claim 抢占时）
  final String? yields;
}

class PresenceArbiter {
  final List<String> _claimants = [];
  final Set<String> _suspended = <String>{};
  String? _holder;

  List<String> get claimants => List.unmodifiable(_claimants);
  String? get holder => _holder;
  bool isSuspended(String tabId) => _suspended.contains(tabId);
  bool isClaimed(String tabId) => _claimants.contains(tabId);

  PresenceTransition claim(String tabId) {
    final previousHolder = _holder;
    _claimants.remove(tabId);
    _claimants.add(tabId);
    _suspended.remove(tabId);
    _holder = tabId;
    return PresenceTransition(
      enters: tabId,
      yields: (previousHolder != null && previousHolder != tabId)
          ? previousHolder
          : null,
    );
  }

  PresenceTransition? release(String tabId) =>
      _remove(tabId, emitExit: true);

  PresenceTransition? detach(String tabId) =>
      _remove(tabId, emitExit: false);

  PresenceTransition? _remove(String tabId, {required bool emitExit}) {
    if (!_claimants.contains(tabId)) {
      return null;
    }
    final wasHolder = _holder == tabId;
    _claimants.remove(tabId);
    _suspended.remove(tabId);
    if (!wasHolder) {
      return const PresenceTransition();
    }
    _holder = null;
    final fallback = _claimants.isEmpty ? null : _claimants.last;
    if (fallback != null) {
      _holder = fallback;
      // 用户回到 PC 操作：回退即重新 enter，suspended 同样清除
      _suspended.remove(fallback);
    }
    return PresenceTransition(
      exits: emitExit ? tabId : null,
      enters: fallback,
    );
  }

  /// 同账号在外部端（手机等）进入房间：暂停持有者心跳，不自动回退，
  /// 避免与外部端互踢；用户在本端主动写动作时经 claim 重新进入。
  PresenceTransition markSuspended(String tabId) {
    if (_holder != tabId) {
      return const PresenceTransition();
    }
    _holder = null;
    _suspended.add(tabId);
    return const PresenceTransition();
  }

  /// 批量摘除（关闭其他/右侧/全部）：整批一次计算，至多一次 exit、
  /// 一个 fallback；调用方必须在销毁这批标签的控制器之前调用。
  PresenceTransition? releaseMany(Set<String> tabIds) {
    if (tabIds.isEmpty || !_claimants.any(tabIds.contains)) {
      return null;
    }
    final oldHolder = _holder;
    final holderRemoved = oldHolder != null && tabIds.contains(oldHolder);
    _claimants.removeWhere(tabIds.contains);
    _suspended.removeAll(tabIds);
    if (!holderRemoved) {
      return const PresenceTransition();
    }
    _holder = null;
    final fallback = _claimants.isEmpty ? null : _claimants.last;
    if (fallback != null) {
      _holder = fallback;
      _suspended.remove(fallback);
    }
    return PresenceTransition(exits: oldHolder, enters: fallback);
  }
}
