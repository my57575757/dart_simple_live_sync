import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎账号面 presence 调用的单一出口（pr_ 前缀）。
/// 生产走 dmw，测试用内存 fake；与 SubDataPlanePort 物理隔离，
/// 两个通道在主端分别由两个服务解析。
abstract class SubPresencePort {
  Future<Object?> invokeMain(String method, [Object? arguments]);
}

class DmwSubPresencePort implements SubPresencePort {
  DmwSubPresencePort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, arguments);
  }
}
