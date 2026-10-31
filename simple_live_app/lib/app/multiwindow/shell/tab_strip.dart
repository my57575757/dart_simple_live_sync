import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';

import 'room_controller_registry.dart';
import 'tab_descriptor.dart';
import 'tab_move_menu.dart';
import 'tab_store.dart';

/// 标签标题解析：已关注用关注时保存的主播名（固定，不随主播改名更新），
/// 未关注或关注名为空时用详情里的实时主播名；详情未加载回退直播间标题，
/// 再不行用描述符标题（初始为房间号）。
String resolveTabTitle({
  required bool followed,
  required String? followedUserName,
  required String? realtimeUserName,
  required String? roomTitle,
  required String fallback,
}) {
  if (followed && followedUserName != null && followedUserName.isNotEmpty) {
    return followedUserName;
  }
  if (realtimeUserName != null && realtimeUserName.isNotEmpty) {
    return realtimeUserName;
  }
  if (roomTitle != null && roomTitle.isNotEmpty) {
    return roomTitle;
  }
  return fallback;
}

class TabStrip extends StatelessWidget {
  const TabStrip({super.key});

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      child: SizedBox(
        height: height,
        child: Obx(() {
          return Row(
            children: [
              if (store.hasHome)
                _HomeButton(active: store.isHomeActive),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: store.tabs.length,
                  itemBuilder: (_, i) =>
                      _TabItem(descriptor: store.tabs[i]),
                ),
              ),
              if (store.hasHome)
                IconButton(
                  tooltip: "首页",
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: store.activateHome,
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final theme = Theme.of(context);
    return InkWell(
      onTap: store.activateHome,
      child: Container(
        padding: AppStyle.edgeInsetsH12,
        color: active ? theme.colorScheme.primary.withAlpha(30) : null,
        alignment: Alignment.center,
        child: Icon(Icons.home,
            size: 18, color: active ? theme.colorScheme.primary : null),
      ),
    );
  }
}

class _TabItem extends StatefulWidget {
  const _TabItem({required this.descriptor});
  final TabDescriptor descriptor;

  @override
  State<_TabItem> createState() => _TabItemState();
}

class _TabItemState extends State<_TabItem> {
  TabDescriptor get descriptor => widget.descriptor;

  // —— 拖出成窗手势：Listener 原始指针不与 ListView 横向滚动争手势竞技场 ——
  int? _dragPointer;
  Offset? _dragStart;
  MoveMenuHost? _dragHost;
  bool _dragArmed = false;
  OverlayEntry? _dragHint;

  // 子窗拖出落点浮层（主窗拖出仍走 _dragHint 直接开新窗）
  OverlayEntry? _dropOverlay;
  DropOverlayGeometry? _dropGeometry;
  final ValueNotifier<String?> _dropHover = ValueNotifier<String?>(null);

  MoveMenuHost _resolveHost() => TabMoveMenu.resolveMoveMenuHost(
        isWindows: Platform.isWindows,
        isSubWindow: MultiWindowRole.isSubWindow,
        windowServiceRegistered: Get.isRegistered<WindowOpenService>(),
        controlServiceRegistered:
            Get.isRegistered<SubWindowControlService>(),
      );

  void _onPointerDown(PointerDownEvent event) {
    // 中键关闭：Listener 比 GestureDetector 更直接
    if (event.kind == PointerDeviceKind.mouse &&
        event.buttons == kMiddleMouseButton) {
      Get.find<TabStore>().close(descriptor.tabId);
      return;
    }
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kPrimaryMouseButton) {
      return;
    }
    if (_dragPointer != null) {
      // 上一次拖拽在窗口外松手、引擎收不到 up：先清滞留状态，否则本标签
      // 拖出手势会被永久卡死
      _resetDrag();
    }
    final host = _resolveHost();
    if (host == MoveMenuHost.none) return;
    _dragPointer = event.pointer;
    _dragStart = event.position;
    _dragHost = host;
    _dragArmed = false;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (event.pointer != _dragPointer) return;
    if (_dragArmed) {
      final next = _dropGeometry?.hitTest(event.position);
      if (next != _dropHover.value) _dropHover.value = next;
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    final start = _dragStart;
    if (box == null || start == null || !box.attached) return;
    final topLeft = box.localToGlobal(Offset.zero);
    if (TabMoveMenu.isPointerOutsideBand(
      pointer: event.position,
      start: start,
      bandTop: topLeft.dy,
      bandBottom: topLeft.dy + box.size.height,
    )) {
      _dragArmed = true;
      // 子窗：落点浮层（拖回主窗口 / 去新窗口）；主窗：维持直接开新窗
      if (_dragHost == MoveMenuHost.sub) {
        _showDropOverlay();
      } else {
        _showDragHint();
      }
    }
  }

  void _onPointerUp(PointerUpEvent event) {
    if (event.pointer != _dragPointer) return;
    final armed = _dragArmed;
    final host = _dragHost;
    // 子窗落点模式：只有压中目标才迁移，压在浮层外松手即取消
    final dropTarget = _dropGeometry?.hitTest(event.position);
    _resetDrag();
    if (!armed || host == null) return;
    if (host == MoveMenuHost.sub) {
      if (dropTarget != null) {
        unawaited(
          SubWindowControlService.instance.requestMove(
            tab: descriptor,
            target: dropTarget,
          ),
        );
      }
      return;
    }
    unawaited(_moveToNewWindow(host));
  }

  void _onPointerCancel(PointerCancelEvent event) {
    if (event.pointer != _dragPointer) return;
    _resetDrag();
  }

  void _resetDrag() {
    _dragPointer = null;
    _dragStart = null;
    _dragHost = null;
    _dragArmed = false;
    _dragHint?.remove();
    _dragHint = null;
    _dropOverlay?.remove();
    _dropOverlay = null;
    _dropGeometry = null;
    _dropHover.value = null;
  }

  /// 越过条带松开：复用右键菜单同一条编排路径（在途守卫/handoff/失败文案）。
  Future<void> _moveToNewWindow(MoveMenuHost host) async {
    if (host == MoveMenuHost.sub) {
      await SubWindowControlService.instance.requestMove(
        tab: descriptor,
        target: WindowControlProtocol.targetNew,
      );
    } else if (host == MoveMenuHost.main) {
      await WindowOpenService.instance.moveTabToWindow(
        tabId: descriptor.tabId,
        target: WindowControlProtocol.targetNew,
      );
    }
  }

  void _showDragHint() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context);
    if (box == null || !box.attached || overlay == null) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    _dragHint = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: _DragTearOffHint(anchor: rect),
      ),
    );
    overlay.insert(_dragHint!);
  }

  /// 子窗拖出落点浮层：几何为纯函数（tab_move_menu），命中矩形即视觉块，
  /// 全程不出本窗（跨引擎收不到窗口外指针事件）。
  void _showDropOverlay() {
    final box = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.maybeOf(context);
    if (box == null || !box.attached || overlay == null) return;
    final anchor = box.localToGlobal(Offset.zero) & box.size;
    final geometry = TabMoveMenu.layoutDropOverlay(
      anchor: anchor,
      viewSize: MediaQuery.sizeOf(context),
    );
    _dropGeometry = geometry;
    _dropOverlay = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: _TabDropOverlay(geometry: geometry, hover: _dropHover),
      ),
    );
    overlay.insert(_dropOverlay!);
  }

  @override
  void dispose() {
    _dragHint?.remove();
    _dragHint = null;
    _dropOverlay?.remove();
    _dropOverlay = null;
    _dropHover.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final theme = Theme.of(context);
    final tabId = descriptor.tabId;
    return Listener(
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: GestureDetector(
        onTap: () => store.activate(tabId),
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition),
        child: Obx(() {
          final active = store.activeTabId.value == tabId;
          LiveRoomController? c;
          if (registry.isRegistered(tabId)) {
            c = Get.find<LiveRoomController>(tag: tabId);
          }
          final title = _resolveTabTitle(c);
          final error = c?.loadError.value ?? false;
          return Container(
            width: 180,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: active
                  ? theme.colorScheme.primary.withAlpha(30)
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(
                  color:
                      active ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(error ? Icons.error_outline : Icons.live_tv,
                    size: 14,
                    color: error ? theme.colorScheme.error : null),
                AppStyle.hGap4,
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                if (c != null)
                  Tooltip(
                    message: c.muted.value ? '取消静音' : '静音',
                    child: InkWell(
                      onTap: c.toggleMute,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          c.muted.value
                              ? Icons.volume_off
                              : Icons.volume_up,
                          size: 14,
                          color: c.muted.value
                              ? theme.colorScheme.error
                              : theme.hintColor,
                        ),
                      ),
                    ),
                  ),
                InkWell(
                  onTap: () => store.close(tabId),
                  child: const Icon(Icons.close, size: 15),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  /// 标签标题：已关注用关注时保存的主播名（固定，不随主播改名更新），
  /// 未关注用详情里的实时主播名；详情未加载回退描述符标题（初始为房间号）。
  String _resolveTabTitle(LiveRoomController? c) {
    if (c == null) return descriptor.title.value;
    return resolveTabTitle(
      followed: c.followed.value,
      followedUserName:
          DBService.instance.getFollowUserName('${c.site.id}_${c.roomId}'),
      realtimeUserName: c.detail.value?.userName,
      roomTitle: c.detail.value?.title,
      fallback: descriptor.title.value,
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rel = RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    );

    // M4-4：主窗经 WOS 本地编排，子窗经控制服务转发主端；账号态可直接迁移
    // （presence 无缝 handoff），不再置灰
    final host = TabMoveMenu.resolveMoveMenuHost(
      isWindows: Platform.isWindows,
      isSubWindow: MultiWindowRole.isSubWindow,
      windowServiceRegistered: Get.isRegistered<WindowOpenService>(),
      controlServiceRegistered:
          Get.isRegistered<SubWindowControlService>(),
    );
    final mainTargets = host == MoveMenuHost.main
        ? WindowOpenService.instance
            .listMoveTargets(excludeWindowId: null)
        : const <WindowListEntry>[];

    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'close', child: Text('关闭')),
      const PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
      const PopupMenuItem(value: 'right', child: Text('关闭右侧标签')),
      if (host != MoveMenuHost.none)
        ...TabMoveMenu.buildMoveEntries(
          hasTargets: host == MoveMenuHost.sub || mainTargets.isNotEmpty,
        ),
      const PopupMenuItem(value: 'copy', child: Text('复制房间链接')),
    ];

    final value = await showMenu<String>(
      context: context,
      position: rel,
      items: items,
    );
    if (value == null) return;

    // 「其他窗口」：主窗用同步候选；子窗点击后拉列表（排除自己），
    // 空列表 toast，非空在原位弹二级
    String? moveTarget = TabMoveMenu.decodeMoveTarget(value);
    if (value == TabMoveMenu.moveOthers) {
      final List<WindowListEntry> targets;
      if (host == MoveMenuHost.main) {
        targets = mainTargets;
      } else {
        final control = SubWindowControlService.instance;
        final all = await control.requestWindowList();
        targets =
            all.where((e) => e.id != control.windowId).toList(growable: false);
      }
      if (targets.isEmpty) {
        SmartDialog.showToast('没有可移入的其他窗口');
        return;
      }
      if (!context.mounted) return;
      final second = await showMenu<String>(
        context: context,
        position: rel,
        items: TabMoveMenu.buildTargetEntries(targets),
      );
      if (second == null) return;
      moveTarget = TabMoveMenu.decodeMoveTarget(second);
    }

    if (moveTarget != null) {
      if (host == MoveMenuHost.sub) {
        unawaited(
          SubWindowControlService.instance.requestMove(
            tab: descriptor,
            target: moveTarget,
          ),
        );
      } else if (host == MoveMenuHost.main) {
        unawaited(
          WindowOpenService.instance.moveTabToWindow(
            tabId: descriptor.tabId,
            target: moveTarget,
          ),
        );
      }
      return;
    }

    switch (value) {
      case 'close':
        store.close(descriptor.tabId);
      case 'others':
        unawaited(store.closeOthers(descriptor.tabId));
      case 'right':
        unawaited(store.closeRight(descriptor.tabId));
      case 'copy':
        // 优先复制控制器已加载的真实房间链接，避免 shareUrl 为空时复制裸 roomId
        String? realUrl;
        if (registry.isRegistered(descriptor.tabId)) {
          realUrl = Get.find<LiveRoomController>(tag: descriptor.tabId)
              .detail
              .value
              ?.url;
        }
        final r = descriptor.request;
        Utils.copyToClipboard(
          (realUrl != null && realUrl.isNotEmpty)
              ? realUrl
              : (r.shareUrl.isNotEmpty ? r.shareUrl : r.roomId),
        );
    }
  }
}

/// 拖出条带后的松开提示：跟随被拖标签，标签靠近顶部时翻到下方显示。
class _DragTearOffHint extends StatelessWidget {
  const _DragTearOffHint({required this.anchor});

  final Rect anchor;
  static const double _width = 188;

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final left = (anchor.center.dx - _width / 2)
        .clamp(8.0, screenWidth - _width - 8.0)
        .toDouble();
    final top =
        anchor.top > 48 ? anchor.top - 40 : anchor.bottom + 8;
    // OverlayEntry 的直接子节点不处于 Stack 中，Positioned 必须自带 Stack
    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: Material(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(16),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.open_in_new, size: 14, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    '松开鼠标，移入新窗口',
                    style: TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 子窗拖出落点浮层：压中目标块高亮，松开发起对应跨窗移动；块尺寸严格等于
/// [DropTargetGeometry.rect] 的命中矩形，避免「看着压中却不触发」。
class _TabDropOverlay extends StatelessWidget {
  const _TabDropOverlay({required this.geometry, required this.hover});

  final DropOverlayGeometry geometry;
  final ValueListenable<String?> hover;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fromRect(
          rect: geometry.outer,
          child: Material(
            color: Theme.of(context).colorScheme.surface,
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.all(TabMoveMenu.dropMenuPadding),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final t in geometry.targets)
                    ValueListenableBuilder<String?>(
                      valueListenable: hover,
                      builder: (_, hovered, __) => _DropTile(
                        target: t.target,
                        highlighted: hovered == t.target,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DropTile extends StatelessWidget {
  const _DropTile({required this.target, required this.highlighted});

  /// WindowControlProtocol target 线值；呈现文案/图标由此稳定标识派生。
  final String target;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final isMain = target == WindowControlProtocol.targetMain;
    final theme = Theme.of(context);
    return Container(
      width: TabMoveMenu.dropMenuWidth - TabMoveMenu.dropMenuPadding * 2,
      height: TabMoveMenu.dropItemHeight,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: highlighted
            ? theme.colorScheme.primary.withAlpha(30)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(isMain ? Icons.home : Icons.open_in_new, size: 16),
          const SizedBox(width: 8),
          Text(isMain ? '主窗口' : '新窗口'),
        ],
      ),
    );
  }
}
