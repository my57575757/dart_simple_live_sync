import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/windows_ime_watchdog.dart';

void main() {
  group('FocusTransitionMachine', () {
    test('首次 poll 只建立基线，不产出事件', () {
      final machine = FocusTransitionMachine();

      expect(machine.poll(false), isNull);
      expect(machine.poll(false), isNull);
    });

    test('持续失焦/持续获焦只产生一次翻转事件', () {
      final machine = FocusTransitionMachine();

      expect(machine.poll(true), isNull);
      expect(machine.poll(false), FocusEvent.deactivated);
      expect(machine.poll(false), isNull);
      expect(machine.poll(false), isNull);
      expect(machine.poll(true), FocusEvent.activated);
      expect(machine.poll(true), isNull);
    });

    test('单帧抖动只产生一一对应的翻转，无重复事件', () {
      final machine = FocusTransitionMachine();
      machine.poll(true);

      expect(machine.poll(false), FocusEvent.deactivated);
      expect(machine.poll(true), FocusEvent.activated);
      expect(machine.poll(true), isNull);
    });
  });
}
