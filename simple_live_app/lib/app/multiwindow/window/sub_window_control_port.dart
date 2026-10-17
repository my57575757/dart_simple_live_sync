import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎窗口管理面调用的单一出口（mw_ 前缀）。
/// 与 SubPresencePort / SubDataPlanePort 物理隔离：主端分别由
/// WindowOpenService 与 MainPresenceService 解析，凭据永不进入本通道。
abstract class SubWindowControlPort {
  Future<Object?> invokeMain(String method, [Object? args]);
}

class DmwSubWindowControlPort implements SubWindowControlPort {
  DmwSubWindowControlPort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? args]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, args);
  }
}
