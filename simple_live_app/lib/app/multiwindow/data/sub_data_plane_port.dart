import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎数据面调用的单一出口。生产走 dmw，测试用内存 fake。
abstract class SubDataPlanePort {
  Future<Object?> invokeMain(String method, [Object? arguments]);
}

class DmwSubDataPlanePort implements SubDataPlanePort {
  DmwSubDataPlanePort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, arguments);
  }
}
