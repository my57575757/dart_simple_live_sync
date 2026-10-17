import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/unhandled_method_router.dart';

void main() {
  test('pr_ 前缀走 presence，mw_ 前缀走 window，互不串线', () async {
    final seen = <String>[];
    Future<Object?> presence(String method, Object? arguments) async {
      seen.add('p:$method');
      return 'p-result';
    }

    Future<Object?> window(String method, Object? arguments) async {
      seen.add('w:$method');
      return 'w-result';
    }

    expect(
      await routeUnhandledMethod('pr_claim', null,
          presenceHandler: presence, windowHandler: window),
      'p-result',
    );
    expect(
      await routeUnhandledMethod('mw_open_tab', null,
          presenceHandler: presence, windowHandler: window),
      'w-result',
    );
    expect(seen, ['p:pr_claim', 'w:mw_open_tab']);
  });

  test('dp_ 与其他未知方法返回 null，不触达任一 handler', () async {
    var calls = 0;
    Future<Object?> noop(String method, Object? arguments) async {
      calls++;
      return null;
    }

    expect(
      await routeUnhandledMethod('dp_set', 1,
          presenceHandler: noop, windowHandler: noop),
      isNull,
    );
    expect(
      await routeUnhandledMethod('focus_tab', 'a_b',
          presenceHandler: noop, windowHandler: noop),
      isNull,
    );
    expect(calls, 0, reason: 'dp_ 由数据面自身 switch 先行，focus_tab 是子端方法');
  });
}
