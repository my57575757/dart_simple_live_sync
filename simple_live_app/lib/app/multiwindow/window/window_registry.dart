/// 主引擎持有的子窗注册表：windowId → 该窗承载的 tab keys。
/// 纯内存逻辑，不碰 dmw，便于单测。主窗自身标签不在此表（归 TabStore）。
class WindowRegistry {
  WindowRegistry({required this.mainWindowId});

  final String mainWindowId;
  final Map<String, Set<String>> _childTabs = {};

  /// 打开顺序，关闭联动时按序通知
  final List<String> _order = [];

  int get childCount => _childTabs.length;
  List<String> get childWindowIds => List<String>.unmodifiable(_order);

  void registerChild(String windowId, Set<String> tabKeys) {
    if (!_childTabs.containsKey(windowId)) {
      _order.add(windowId);
    }
    _childTabs[windowId] = <String>{...tabKeys};
  }

  Set<String> tabsOf(String windowId) => {
        ...?_childTabs[windowId],
      };

  /// tabKey（siteId_roomId）所在子窗；主窗标签由调用方先查 TabStore
  String? windowForTab(String tabKey) {
    for (final entry in _childTabs.entries) {
      if (entry.value.contains(tabKey)) return entry.key;
    }
    return null;
  }

  /// onWindowsChanged 后按存活窗口列表对账，摘除已关闭窗口。
  /// 返回本次被摘除的 windowId 集合（无变化为空集），供订阅者
  /// （MainPresenceService）批量释放该窗名下的远端 presence 标签。
  Set<String> reconcile(Iterable<String> aliveWindowIds) {
    final alive = aliveWindowIds.toSet();
    final removed = <String>{};
    _childTabs.removeWhere((id, _) {
      if (alive.contains(id)) return false;
      removed.add(id);
      return true;
    });
    _order.removeWhere((id) => !_childTabs.containsKey(id));
    return removed;
  }
}
