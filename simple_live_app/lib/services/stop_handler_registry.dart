import 'dart:async';

/// 一组带 key 的异步处理器，用于单通道事件扇出到多个标签
class StopHandlerRegistry {
  final _handlers = <String, FutureOr<void> Function()>{};

  bool get isEmpty => _handlers.isEmpty;

  void set(String key, FutureOr<void> Function()? handler) {
    if (handler == null) {
      _handlers.remove(key);
    } else {
      _handlers[key] = handler;
    }
  }

  Future<void> invokeAll() async {
    for (final handler in _handlers.values.toList()) {
      await handler();
    }
  }
}
