import 'package:flutter/gestures.dart' show kTouchSlop;
import 'package:flutter/material.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

/// 右键移动菜单的宿主形态：主窗（WOS 编排）/ 子窗（控制服务转发）/ 无菜单。
enum MoveMenuHost { none, main, sub }

/// 跨窗移动菜单的纯决策/构建层：不碰 GetX 与遥控器，tab_strip 只做组装
/// 与服务调用；级联交互（点「其他窗口」后拉列表再弹二级）在 widget 侧。
abstract final class TabMoveMenu {
  static const String moveNew = 'move_new';
  static const String moveOthers = 'move_others';
  static const String _moveToPrefix = 'move_to:';

  static String moveTo(String target) => '$_moveToPrefix$target';

  /// 一级/二级 value → target 线值；非移动类菜单 value 一律 null。
  static String? decodeMoveTarget(String? value) {
    if (value == moveNew) return WindowControlProtocol.targetNew;
    if (value != null && value.startsWith(_moveToPrefix)) {
      return value.substring(_moveToPrefix.length);
    }
    return null;
  }

  static MoveMenuHost resolveMoveMenuHost({
    required bool isWindows,
    required bool isSubWindow,
    required bool windowServiceRegistered,
    required bool controlServiceRegistered,
  }) {
    if (!isWindows) return MoveMenuHost.none;
    if (isSubWindow) {
      return controlServiceRegistered
          ? MoveMenuHost.sub
          : MoveMenuHost.none;
    }
    return windowServiceRegistered ? MoveMenuHost.main : MoveMenuHost.none;
  }

  /// 标签拖出条带判定（拖拽成窗）：位移超过 [slop] 且指针越过当前标签
  /// 纵向热区（上下各留 [margin] 容差）。只看纵向——横向拖动是 ListView
  /// 滚动手势，停在条带内不触发。[slop] 与 TapGestureRecognizer 的
  /// kTouchSlop 对齐：触发判定时 tap 已被取消，不会拖出成窗又激活标签。
  static bool isPointerOutsideBand({
    required Offset pointer,
    required Offset start,
    required double bandTop,
    required double bandBottom,
    double margin = 6,
    double slop = kTouchSlop,
  }) {
    if ((pointer - start).distance < slop) return false;
    return pointer.dy < bandTop - margin ||
        pointer.dy > bandBottom + margin;
  }

  // ---- 拖出落点浮层（子窗：拖回主窗口 / 去新窗口）----
  // 命中全程在本窗 overlay 内完成：跨引擎收不到窗口外的指针事件，
  // desktop_multi_window 也无窗口命中 API，落点必须画在窗内。
  static const double dropMenuWidth = 208;
  static const double dropItemHeight = 40;
  static const double dropMenuPadding = 6;
  static const double dropGap = 8;
  static const double dropScreenMargin = 8;

  /// 子窗落点顺序：主窗口第一块（拖回是主诉求，离标签最近）。
  static const List<String> subDropTargets = [
    WindowControlProtocol.targetMain,
    WindowControlProtocol.targetNew,
  ];

  /// 计算落点浮层的外框与各落点命中矩形（窗口内逻辑坐标）。
  /// 默认落在标签正下方，下方放不下翻上方；水平 clamp 不越窗。
  static DropOverlayGeometry layoutDropOverlay({
    required Rect anchor,
    required Size viewSize,
    List<String>? targets,
  }) {
    final list = targets ?? subDropTargets;
    final height = dropMenuPadding * 2 + list.length * dropItemHeight;
    final maxLeft = viewSize.width - dropMenuWidth - dropScreenMargin;
    final left = maxLeft < dropScreenMargin
        ? dropScreenMargin
        : anchor.left.clamp(dropScreenMargin, maxLeft).toDouble();
    double top;
    final belowTop = anchor.bottom + dropGap;
    if (belowTop + height <= viewSize.height - dropScreenMargin) {
      top = belowTop;
    } else {
      top = anchor.top - dropGap - height;
    }
    final maxTop = viewSize.height - height - dropScreenMargin;
    if (maxTop < dropScreenMargin) {
      top = dropScreenMargin;
    } else {
      top = top.clamp(dropScreenMargin, maxTop).toDouble();
    }
    return DropOverlayGeometry(
      outer: Rect.fromLTWH(left, top, dropMenuWidth, height),
      targets: [
        for (var i = 0; i < list.length; i++)
          DropTargetGeometry(
            target: list[i],
            rect: Rect.fromLTWH(
              left + dropMenuPadding,
              top + dropMenuPadding + i * dropItemHeight,
              dropMenuWidth - dropMenuPadding * 2,
              dropItemHeight,
            ),
          ),
      ],
    );
  }

  /// 一级菜单移动区：「移到新窗口」恒有；「移到其他窗口」仅在确有候选时。
  /// 子窗候选需异步拉取，调用方恒传 true（点击后空列表改 toast）。
  static List<PopupMenuEntry<String>> buildMoveEntries({
    required bool hasTargets,
  }) =>
      [
        const PopupMenuItem<String>(
          value: moveNew,
          child: Text('移到新窗口'),
        ),
        if (hasTargets)
          const PopupMenuItem<String>(
            value: moveOthers,
            child: Text('移到其他窗口'),
          ),
      ];

  /// 二级菜单：disabled 标题 + 目标窗口项。
  static List<PopupMenuEntry<String>> buildTargetEntries(
    List<WindowListEntry> targets,
  ) =>
      [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('移到其他窗口'),
        ),
        for (final entry in targets)
          PopupMenuItem<String>(
            value: moveTo(entry.id),
            child: Text(entry.label),
          ),
      ];
}

/// 拖出落点浮层布局结果：外框（绘制用）与各目标命中矩形。
class DropOverlayGeometry {
  const DropOverlayGeometry({required this.outer, required this.targets});

  final Rect outer;
  final List<DropTargetGeometry> targets;

  /// 压中哪块返回其 target 线值；间隙/浮层外返回 null（松手即取消）。
  String? hitTest(Offset pointer) {
    for (final t in targets) {
      if (t.rect.contains(pointer)) return t.target;
    }
    return null;
  }
}

class DropTargetGeometry {
  const DropTargetGeometry({required this.target, required this.rect});

  /// WindowControlProtocol target 线值（稳定标识，呈现文案由 widget 派生）。
  final String target;
  final Rect rect;
}
