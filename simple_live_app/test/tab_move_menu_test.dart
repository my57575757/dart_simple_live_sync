import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_move_menu.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

void main() {
  group('resolveMoveMenuHost', () {
    test('非 Windows 恒 none，即使服务齐备', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: false,
          isSubWindow: false,
          windowServiceRegistered: true,
          controlServiceRegistered: true,
        ),
        MoveMenuHost.none,
      );
    });

    test('主窗：注册 WOS 为 main，未注册为 none', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: false,
          windowServiceRegistered: true,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.main,
      );
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: false,
          windowServiceRegistered: false,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.none,
      );
    });

    test('子窗：注册控制服务为 sub，未注册为 none', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: true,
          windowServiceRegistered: false,
          controlServiceRegistered: true,
        ),
        MoveMenuHost.sub,
      );
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: true,
          windowServiceRegistered: false,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.none,
      );
    });
  });

  group('buildMoveEntries', () {
    test('恒有「移到新窗口」；hasTargets 决定「其他窗口」', () {
      final withTargets = TabMoveMenu.buildMoveEntries(hasTargets: true);
      expect(withTargets, hasLength(2));
      expect((withTargets[0] as PopupMenuItem<String>).value,
          TabMoveMenu.moveNew);
      expect((withTargets[1] as PopupMenuItem<String>).value,
          TabMoveMenu.moveOthers);

      final noTargets = TabMoveMenu.buildMoveEntries(hasTargets: false);
      expect(noTargets, hasLength(1));
      final newItem = noTargets.single as PopupMenuItem<String>;
      expect(newItem.value, TabMoveMenu.moveNew);
      expect(newItem.enabled, isTrue,
          reason: '账号态置灰已删除：新窗口项对任何标签恒可点');
    });
  });

  group('buildTargetEntries', () {
    test('disabled 标题 + 每窗一项，value 经 moveTo 编码、文本为 label', () {
      final entries = TabMoveMenu.buildTargetEntries(const [
        WindowListEntry(id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
      expect(entries, hasLength(3));
      final header = entries[0] as PopupMenuItem<String>;
      expect(header.enabled, isFalse);
      expect((entries[1] as PopupMenuItem<String>).value,
          TabMoveMenu.moveTo(WindowControlProtocol.targetMain));
      expect((entries[2] as PopupMenuItem<String>).value,
          TabMoveMenu.moveTo('w2'));
    });
  });

  group('isPointerOutsideBand', () {
    // 条带 y ∈ [0,38]，指针在标签中央按下
    const start = Offset(100, 19);
    bool outside(Offset p) => TabMoveMenu.isPointerOutsideBand(
          pointer: p,
          start: start,
          bandTop: 0,
          bandBottom: 38,
        );

    test('未移动 / 横向移动（ListView 滚动）一律不触发', () {
      expect(outside(start), isFalse);
      expect(outside(const Offset(200, 19)), isFalse);
      expect(outside(const Offset(100, 0)), isFalse);
    });

    test('越过上下边界 + margin 才触发', () {
      expect(outside(const Offset(100, 45)), isTrue, reason: '下方 44 之外');
      expect(outside(const Offset(100, -7)), isTrue, reason: '上方 -6 之外');
      expect(outside(const Offset(100, 43)), isFalse, reason: 'margin 容差内');
      expect(outside(const Offset(100, -5)), isFalse, reason: 'margin 容差内');
    });

    test('位移不足 slop（对齐 kTouchSlop=18）即使越界也不触发', () {
      // 从条带上沿附近起手，向上 7px 已越 margin，但总位移 < 18：
      // tap 尚未被取消，不能判拖出（否则成窗与 onTap 双触发）
      expect(
        TabMoveMenu.isPointerOutsideBand(
          pointer: const Offset(100, -7),
          start: const Offset(100, 0),
          bandTop: 0,
          bandBottom: 38,
        ),
        isFalse,
      );
    });

    test('自定义 slop/margin 生效', () {
      expect(
        TabMoveMenu.isPointerOutsideBand(
          pointer: const Offset(100, -7),
          start: const Offset(100, 0),
          bandTop: 0,
          bandBottom: 38,
          slop: 4,
        ),
        isTrue,
      );
      expect(
        TabMoveMenu.isPointerOutsideBand(
          pointer: const Offset(100, -1),
          start: start,
          bandTop: 0,
          bandBottom: 38,
          margin: 0,
        ),
        isTrue,
      );
    });
  });

  group('decodeMoveTarget', () {
    test('新窗口/具体窗解码；无关 value 返回 null', () {
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveNew),
          WindowControlProtocol.targetNew);
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveTo('w2')), 'w2');
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveTo('__main__')),
          WindowControlProtocol.targetMain);
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveOthers), isNull);
      expect(TabMoveMenu.decodeMoveTarget('close'), isNull);
      expect(TabMoveMenu.decodeMoveTarget(null), isNull);
    });
  });
}
