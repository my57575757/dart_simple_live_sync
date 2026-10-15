import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/stop_handler_registry.dart';

void main() {
  test('多处理器按注册顺序全部执行', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () async => calls.add('a'));
    r.set('b', () => calls.add('b'));
    expect(r.isEmpty, false);
    await r.invokeAll();
    expect(calls, ['a', 'b']);
  });

  test('传 null 移除指定处理器，不影响其他', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () => calls.add('a'));
    r.set('b', () => calls.add('b'));
    r.set('a', null);
    await r.invokeAll();
    expect(calls, ['b']);
  });

  test('同 key 重复注册为覆盖', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () => calls.add('old'));
    r.set('a', () => calls.add('new'));
    await r.invokeAll();
    expect(calls, ['new']);
  });
}
