import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_arbiter.dart';

void main() {
  group('claim', () {
    test('首个意图成为 holder', () {
      final a = PresenceArbiter();
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(t.enters, 'A');
      expect(t.yields, isNull);
      expect(t.exits, isNull);
    });

    test('新意图抢占：旧 holder 进入 yields，栈尾为最新', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.claim('B');
      expect(a.holder, 'B');
      expect(a.claimants, ['A', 'B']);
      expect(t.enters, 'B');
      expect(t.yields, 'A');
    });

    test('已在栈中的标签 claim：提到栈尾并抢回 holder（发弹幕场景）', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B'); // B holder，A 被让位
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['B', 'A']);
      expect(t.enters, 'A');
      expect(t.yields, 'B');
    });

    test('holder 重复 claim：无 yields', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(t.yields, isNull);
    });

    test('claim 清除自身 suspended', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.markSuspended('A');
      expect(a.isSuspended('A'), isTrue);
      a.claim('A');
      expect(a.isSuspended('A'), isFalse);
      expect(a.holder, 'A');
    });
  });

  group('release（close 语义）', () {
    test('释放 holder：发 exit 并回退栈尾次新接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.release('B')!;
      expect(t.exits, 'B');
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(a.isSuspended('A'), isFalse);
    });

    test('逆序关闭三个标签：回退顺序严格按打开时间', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.claim('C');
      var t = a.release('C')!;
      expect(t.enters, 'B');
      t = a.release('B')!;
      expect(t.enters, 'A');
      t = a.release('A')!;
      expect(t.enters, isNull);
      expect(t.exits, 'A');
      expect(a.holder, isNull);
      expect(a.claimants, isEmpty);
    });

    test('释放非持有者：空 transition、不发 exit、holder 不变', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.release('A');
      expect(t, isNotNull);
      expect(t!.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
      expect(a.claimants, ['B']);
    });

    test('释放唯一 holder：exit 且无接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.release('A')!;
      expect(t.exits, 'A');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
    });

    test('释放未知 tab：返回 null 无动作', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.release('X'), isNull);
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('回退目标是 suspended 标签：清除 suspended 并重新 enter', () {
      final a = PresenceArbiter();
      a.claim('A'); // A holder
      a.markSuspended('A'); // 手机端抢占 A
      a.claim('B'); // 用户改在 B 显式进入，A 仍在栈中且 suspended
      expect(a.isSuspended('A'), isTrue);
      final t = a.release('B')!; // 更新的标签关闭
      expect(t.enters, 'A');
      expect(t.exits, 'B');
      expect(a.holder, 'A');
      expect(a.isSuspended('A'), isFalse);
    });
  });

  group('detach（跨窗移动语义，M4 接线）', () {
    test('detach holder：摘除、不发 exit、次新接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.detach('B')!;
      expect(t.exits, isNull);
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('detach 非持有者：仅摘除', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.detach('A')!;
      expect(t.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
    });

    test('detach 未知 tab 返回 null', () {
      final a = PresenceArbiter();
      expect(a.detach('X'), isNull);
    });
  });

  group('markSuspended（外部端抢占）', () {
    test('抢占 holder：停 holder、不自动回退、标签留在栈中', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.markSuspended('B');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
      expect(a.isSuspended('B'), isTrue);
      expect(a.claimants, ['A', 'B']);
    });

    test('对非 holder 调 markSuspended 无动作', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.markSuspended('A');
      expect(a.holder, 'B');
      expect(a.isSuspended('A'), isFalse);
    });
  });

  group('releaseMany（批量关闭）', () {
    test('全关：只 exit 原 holder 一次，无 fallback、栈清空', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.claim('C');
      final t = a.releaseMany({'A', 'B', 'C'})!;
      expect(t.exits, 'C');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
      expect(a.claimants, isEmpty);
    });

    test('关闭其他：受害者含 holder，幸存者在栈中则接管（清 suspended）', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.markSuspended('A'); // 手机抢占 A
      a.claim('B');
      a.claim('C'); // C holder，A 仍 suspended 在栈
      final t = a.releaseMany({'B', 'C'})!;
      expect(t.exits, 'C');
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(a.isSuspended('A'), isFalse);
    });

    test('批内不含 holder：空 transition，holder 与心跳归属不变', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B'); // B holder
      final t = a.releaseMany({'A'})!;
      expect(t.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
      expect(a.claimants, ['B']);
    });

    test('全部未知：返回 null', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.releaseMany({'X', 'Y'}), isNull);
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('空集合：返回 null', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.releaseMany(<String>{}), isNull);
    });
  });
}
