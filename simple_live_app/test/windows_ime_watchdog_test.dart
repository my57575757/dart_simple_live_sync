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

  group('KeyboardLayoutTransitionMachine', () {
    test('首次 poll 只建立基线，不触发', () {
      final machine = KeyboardLayoutTransitionMachine();

      expect(machine.poll(12345), isFalse);
      expect(machine.poll(12345), isFalse);
    });

    test('布局变化（切换输入法）时触发一次', () {
      final machine = KeyboardLayoutTransitionMachine();
      machine.poll(111);

      expect(machine.poll(222), isTrue);
      expect(machine.poll(222), isFalse);
    });
  });
}
