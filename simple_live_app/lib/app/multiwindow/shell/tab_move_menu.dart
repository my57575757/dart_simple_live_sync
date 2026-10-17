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
