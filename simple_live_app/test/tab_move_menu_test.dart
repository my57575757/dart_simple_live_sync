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
