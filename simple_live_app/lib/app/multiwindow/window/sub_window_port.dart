/// 子窗操作能力抽象：生产用 dmw，单测用内存 fake
abstract class SubWindowPort {
  Future<SubWindowHandle> createRoomWindow(String argumentsJson);
  Future<void> invoke(String windowId, String method, Object? arguments);
  Future<List<String>> listWindowIds();
  Stream<void> get windowsChanged;
}

class SubWindowHandle {
  const SubWindowHandle(this.windowId);
  final String windowId;
}
