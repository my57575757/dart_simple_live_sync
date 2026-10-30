import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/bili_watch_session.dart';

void main() {
  group('BiliWatchSession 前台标签会话编排', () {
    test('shouldRun 翻转才发 start/stop，同态幂等', () {
      final starts = <int>[];
      final stops = <int>[];
      final session = BiliWatchSession(
        roomId: 5050,
        onStart: starts.add,
        onStop: stops.add,
      );

      session.evaluate(true);
      session.evaluate(true);
      expect(starts, [5050]);
      expect(stops, isEmpty);

      session.evaluate(false);
      session.evaluate(false);
      expect(stops, [5050]);

      session.evaluate(true);
      expect(starts, [5050, 5050]);

      session.dispose();
    });

    test('初始不应计时：dispose 不发 stop', () {
      final stops = <int>[];
      final session = BiliWatchSession(
        roomId: 5050,
        onStart: (_) {},
        onStop: stops.add,
      );

      session.evaluate(false);
      session.dispose();

      expect(stops, isEmpty);
    });

    test('运行中 dispose：补发一次 stop（交给 tracker 防抖发最后 X）', () {
      final stops = <int>[];
      final session = BiliWatchSession(
        roomId: 6060,
        onStart: (_) {},
        onStop: stops.add,
      );

      session.evaluate(true);
      session.dispose();

      expect(stops, [6060]);
    });

    test('dispose 后再 evaluate 不再触发任何调用', () {
      final starts = <int>[];
      final stops = <int>[];
      final session = BiliWatchSession(
        roomId: 5050,
        onStart: starts.add,
        onStop: stops.add,
      );

      session.evaluate(true);
      session.dispose();
      session.evaluate(true);
      session.evaluate(false);

      expect(starts, [5050]);
      expect(stops, [5050]);
    });
  });
}
