import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';

void main() {
  test('addChildTab 合并不覆盖；未注册窗抛 StateError', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a'});
    r.addChildTab('w1', 'douyin_b');
    expect(r.tabsOf('w1'), {'douyin_a', 'douyin_b'});

    r.addChildTab('w1', 'douyin_a'); // 幂等
    expect(r.tabsOf('w1'), {'douyin_a', 'douyin_b'});

    expect(() => r.addChildTab('w9', 'douyin_x'), throwsStateError);
  });

  test('removeChildTab 摘除 key；空 set 保留（窗存活由 reconcile 对账）', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a', 'douyin_b'});
    r.removeChildTab('w1', 'douyin_a');
    expect(r.tabsOf('w1'), {'douyin_b'});
    expect(r.childWindowIds, ['w1'], reason: '空窗不立即摘除');

    r.removeChildTab('w1', 'douyin_b');
    expect(r.tabsOf('w1'), isEmpty);
    expect(r.childWindowIds, ['w1']);
    expect(r.windowForTab('douyin_b'), isNull);

    // 未知窗/未知 key 静默 no-op
    r.removeChildTab('w9', 'x');
    r.removeChildTab('w1', 'x');
  });

  test('moveChildTab：源摘除、目标合并；windowForTab 更新', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a'});
    r.registerChild('w2', {'douyin_b'});
    r.moveChildTab('w1', 'w2', 'douyin_a');
    expect(r.tabsOf('w1'), isEmpty);
    expect(r.tabsOf('w2'), {'douyin_a', 'douyin_b'});
    expect(r.windowForTab('douyin_a'), 'w2');
  });

  test('childWindowOrder：按开窗序给 1 起 ordinal；reconcile 后重算列表', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w10', {'a_1'});
    r.registerChild('w20', {'a_2'});
    final order = r.childWindowOrder();
    expect(order.map((e) => e.id), ['w10', 'w20']);
    expect(order.map((e) => e.ordinal), [1, 2]);

    r.reconcile(['main', 'w20']);
    final after = r.childWindowOrder();
    expect(after.single.id, 'w20');
    expect(after.single.ordinal, 1, reason: '摘除后剩余窗 ordinal 连续重排');
  });
}
