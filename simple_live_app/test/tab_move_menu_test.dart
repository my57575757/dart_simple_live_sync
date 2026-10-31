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

  group('layoutDropOverlay（子窗拖出落点浮层）', () {
    // 子窗最小 360x400；浮层宽 208、两块各 40 高、上下内边距 6 → 总高 92
    const view = Size(1200, 720);
    // 标签锚：(100,100)-(280,138)
    const anchor = Rect.fromLTWH(100, 100, 180, 38);

    test('默认落在标签正下方；主窗口在第一块、新窗口第二块，互不重叠且在浮层内',
        () {
      final g = TabMoveMenu.layoutDropOverlay(
        anchor: anchor,
        viewSize: view,
      );
      expect(g.outer.left, 100, reason: '左缘对齐标签');
      expect(g.outer.top, 146, reason: '标签底 138 + 间距 8');
      expect(g.targets.map((t) => t.target), [
        WindowControlProtocol.targetMain,
        WindowControlProtocol.targetNew,
      ]);
      final main = g.targets[0].rect;
      final fresh = g.targets[1].rect;
      expect(main.top, 146 + 6, reason: '浮层内边距 6');
      expect(fresh.top, main.bottom, reason: '两块紧贴排布');
      expect(main.bottom, 146 + 46);
      expect(fresh.bottom, 146 + 86, reason: '总高 92 = 12+80');
      expect(main.left, fresh.left);
      expect(main.width, 208 - 12);
      expect(main.overlaps(fresh), isFalse);
      expect(main.left >= g.outer.left && fresh.right <= g.outer.right, isTrue);
    });

    test('贴右缘时左缘 clamp 进窗口，浮层整体不越界', () {
      final g = TabMoveMenu.layoutDropOverlay(
        anchor: const Rect.fromLTWH(1100, 100, 180, 38),
        viewSize: view,
      );
      expect(g.outer.left, 1200 - 208 - 8);
      expect(g.outer.right, 1200 - 8);
    });

    test('下方空间不足时翻到标签上方', () {
      // view 高 200：下方 146+92=238 > 192 → 上方 anchor.top-8-92=0，
      // 再被屏边 clamp 到 8（底边 100 贴住标签上沿）
      final g = TabMoveMenu.layoutDropOverlay(
        anchor: anchor,
        viewSize: const Size(1200, 200),
      );
      expect(g.outer.top, 8);
      expect(g.outer.bottom, 100);
    });

    test('hitTest：压中哪块返回其稳定 target；间隙/浮层外返回 null', () {
      final g = TabMoveMenu.layoutDropOverlay(anchor: anchor, viewSize: view);
      final mainCenter = g.targets[0].rect.center;
      final newCenter = g.targets[1].rect.center;
      expect(g.hitTest(mainCenter), WindowControlProtocol.targetMain);
      expect(g.hitTest(newCenter), WindowControlProtocol.targetNew);
      // 两块之间没有间隙（紧贴），改用浮层左内边距空白与浮层外侧
      expect(g.hitTest(Offset(g.outer.left + 2, g.outer.top + 2)), isNull,
          reason: '浮层 padding 区不是落点');
      expect(g.hitTest(const Offset(10, 10)), isNull);
    });

    test('比浮层还矮的极端小窗不抛异常（实际最小 360x400 不会到这）', () {
      expect(
        () => TabMoveMenu.layoutDropOverlay(
          anchor: anchor,
          viewSize: const Size(200, 100),
        ),
        returnsNormally,
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
