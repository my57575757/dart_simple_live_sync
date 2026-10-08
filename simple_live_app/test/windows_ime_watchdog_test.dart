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

  group('TextFocusTransitionMachine', () {
    test('首次 poll 只建立基线，不触发', () {
      final machine = TextFocusTransitionMachine();

      expect(machine.poll(textFocused: true, nowMs: 1000), isFalse);
      expect(machine.poll(textFocused: true, nowMs: 1100), isFalse);
    });

    test('非文本焦点 -> 文本焦点时触发', () {
      final machine = TextFocusTransitionMachine();
      machine.poll(textFocused: false, nowMs: 0);

      // 正是 #191196 的文本客户端切换时刻：重建必须在此时发生
      expect(machine.poll(textFocused: true, nowMs: 1000), isTrue);
      expect(machine.poll(textFocused: true, nowMs: 1100), isFalse);
    });

    test('文本焦点消失不触发', () {
      final machine = TextFocusTransitionMachine();
      machine.poll(textFocused: true, nowMs: 0);

      expect(machine.poll(textFocused: false, nowMs: 500), isFalse);
      // 对话框关闭立刻重开：防抖窗口内不重复触发
      expect(machine.poll(textFocused: true, nowMs: 600), isFalse);
      // 超过防抖间隔后再次进入文本焦点才触发
      expect(machine.poll(textFocused: false, nowMs: 1000), isFalse);
      expect(machine.poll(textFocused: true, nowMs: 1600), isTrue);
    });
  });
}
