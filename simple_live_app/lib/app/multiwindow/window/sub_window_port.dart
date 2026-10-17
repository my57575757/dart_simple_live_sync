/// 子窗操作能力抽象：生产用 dmw，单测用内存 fake
abstract class SubWindowPort {
  Future<SubWindowHandle> createRoomWindow(String argumentsJson);
  /// 调用子窗 method handler；返回值为子端回执（如 mw_open_tab 的 bool）。
  /// 既有 focus_tab/close_window/apply_* 调用方忽略返回值。
  Future<Object?> invoke(String windowId, String method, Object? arguments);
  Future<List<String>> listWindowIds();
  Stream<void> get windowsChanged;
}

class SubWindowHandle {
  const SubWindowHandle(this.windowId);
  final String windowId;
}
