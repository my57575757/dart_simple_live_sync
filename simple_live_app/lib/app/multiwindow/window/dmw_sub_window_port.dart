import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'sub_window_port.dart';

class DmwSubWindowPort implements SubWindowPort {
  /// 主引擎自己的 controller（main() 分发时挂载）；kShell binding 据此
  /// 构造 WindowRegistry
  static WindowController? mainController;

  static String? get mainWindowId => mainController?.windowId;

  static void attachMain(WindowController controller) {
    mainController = controller;
  }

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final controller = await WindowController.create(
      WindowConfiguration(arguments: argumentsJson, hiddenAtLaunch: true),
    );
    return SubWindowHandle(controller.windowId);
  }

  @override
  Future<void> invoke(
      String windowId, String method, Object? arguments) async {
    await WindowController.fromWindowId(windowId)
        .invokeMethod(method, arguments);
  }

  @override
  Future<List<String>> listWindowIds() async {
    final all = await WindowController.getAll();
    return all.map((e) => e.windowId).toList();
  }

  @override
  Stream<void> get windowsChanged => onWindowsChanged;
}
