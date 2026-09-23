import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/self_echo_tracker.dart';

void main() {
  test("回环命中后被消费，仅一次", () {
    var clock = 100000;
    var tracker = SelfEchoTracker(now: () => clock);
    tracker.add("你好");
    expect(tracker.consume("你好"), isTrue);
    expect(tracker.consume("你好"), isFalse);
  });

  test("重复发送相同内容，每条回环各消费一次", () {
    var clock = 0;
    var tracker = SelfEchoTracker(now: () => clock);
    tracker.add("666");
    tracker.add("666");
    expect(tracker.consume("666"), isTrue);
    expect(tracker.consume("666"), isTrue);
    expect(tracker.consume("666"), isFalse);
  });

  test("超过窗口的回环不再去重，避免吞掉别人的同文消息", () {
    var clock = 0;
    var tracker = SelfEchoTracker(now: () => clock);
    tracker.add("迟到");
    clock = SelfEchoTracker.windowMs + 1;
    expect(tracker.consume("迟到"), isFalse);
  });

  test("未登记的消息不被误吞", () {
    var tracker = SelfEchoTracker(now: () => 0);
    expect(tracker.consume("路人弹幕"), isFalse);
  });

  test("超过上限淘汰最早的登记", () {
    var tracker = SelfEchoTracker(now: () => 0);
    for (var i = 0; i < SelfEchoTracker.maxPending; i++) {
      tracker.add("m$i");
    }
    tracker.add("new");
    expect(tracker.consume("m0"), isFalse);
    expect(tracker.consume("m1"), isTrue);
    expect(tracker.consume("new"), isTrue);
  });
}
