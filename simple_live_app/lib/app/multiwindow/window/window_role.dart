/// 当前 engine 角色：主引擎 false（默认），房间子引擎 true。
/// 纯 Dart 静态位，由 main() 分发时在子引擎置位。
class MultiWindowRole {
  static bool isSubWindow = false;
}

/// 主引擎 IPC → 子窗壳的命令挂载点。
/// close_window 具体动作（关播放器、防重复、close 窗口）由 RoomShellPage
/// 在 initState 注册，引导期/IPC 处理器不持有 widget 上下文。
class SubWindowCommands {
  static Future<void> Function()? closeRequested;
}
