/// 主引擎 method channel default 分支的协议族前缀路由。
/// dp_ 由 MainDataPlaneService 自身 switch 先行处理，不到这里；
/// pr_ 去账号面，mw_ 去窗口面，其余返回 null（dmw 对未处理方法回空）。
typedef UnhandledMethodHandler = Future<Object?> Function(
    String method, Object? arguments);

Future<Object?> routeUnhandledMethod(
  String method,
  Object? arguments, {
  required UnhandledMethodHandler presenceHandler,
  required UnhandledMethodHandler windowHandler,
}) async {
  if (method.startsWith('pr_')) {
    return presenceHandler(method, arguments);
  }
  if (method.startsWith('mw_')) {
    return windowHandler(method, arguments);
  }
  return null;
}
