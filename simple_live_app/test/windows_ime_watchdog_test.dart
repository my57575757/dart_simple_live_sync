import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/windows_ime_watchdog.dart';

void main() {
  group('TextFocusTransitionMachine', () {
    test('首次 poll 只建立基线，不触发', () {
      final machine = TextFocusTransitionMachine();

      expect(machine.poll(textFocused: true, nowMs: 1000), isFalse);
      expect(machine.poll(textFocused: true, nowMs: 1100), isFalse);
    });

    test('非文本 -> 文本焦点时触发（attach 时机）', () {
      final machine = TextFocusTransitionMachine();
      machine.poll(textFocused: false, nowMs: 0);

      // 正是 #191196 的文本客户端切换时刻：attach 必须在此时发生
      expect(machine.poll(textFocused: true, nowMs: 1000), isTrue);
      expect(machine.poll(textFocused: true, nowMs: 1100), isFalse);
    });

    test('文本 -> 非文本焦点时触发（detach 时机）', () {
      final machine = TextFocusTransitionMachine();
      machine.poll(textFocused: true, nowMs: 0);

      expect(machine.poll(textFocused: false, nowMs: 1000), isTrue);
      expect(machine.poll(textFocused: false, nowMs: 1100), isFalse);
    });

    test('对话框关闭立刻重开：进入文本的抖动被防抖', () {
      final machine = TextFocusTransitionMachine();
      machine.poll(textFocused: false, nowMs: 0);

      expect(machine.poll(textFocused: true, nowMs: 1000), isTrue);
      expect(machine.poll(textFocused: false, nowMs: 1100), isTrue);
      // 距上次进入文本仅 100ms：防抖窗口内不重复 attach
      expect(machine.poll(textFocused: true, nowMs: 1200), isFalse);
      // 超过防抖间隔后再次进入文本才触发
      expect(machine.poll(textFocused: false, nowMs: 2000), isTrue);
      expect(machine.poll(textFocused: true, nowMs: 2501), isTrue);
    });
  });
}
