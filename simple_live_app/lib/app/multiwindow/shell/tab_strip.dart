import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

import 'room_controller_registry.dart';
import 'tab_descriptor.dart';
import 'tab_store.dart';

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

class _TabItem extends StatelessWidget {
  const _TabItem({required this.descriptor});
  final TabDescriptor descriptor;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final theme = Theme.of(context);
    final tabId = descriptor.tabId;
    // 中键关闭：Listener 比 GestureDetector 更直接
    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kMiddleMouseButton) {
          store.close(tabId);
        }
      },
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
          final title = c?.detail.value?.title ?? descriptor.title.value;
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

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rel = RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    );
    LiveRoomController? controller;
    if (registry.isRegistered(descriptor.tabId)) {
      controller = Get.find<LiveRoomController>(tag: descriptor.tabId);
    }
    final isAccount =
        controller?.presence.value == RoomPresence.account;
    // M4-1：移动仅主窗游客态可用；子窗不显示该项，账号态置灰
    final showMoveItem = Platform.isWindows &&
        !MultiWindowRole.isSubWindow &&
        Get.isRegistered<WindowOpenService>();
    Widget moveChild = const Text('移到新窗口');
    if (isAccount) {
      moveChild = const Tooltip(
        message: '账号跨窗在下一阶段支持',
        child: Text('移到新窗口'),
      );
    }

    final value = await showMenu<String>(
      context: context,
      position: rel,
      items: [
        const PopupMenuItem(value: 'close', child: Text('关闭')),
        const PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
        const PopupMenuItem(value: 'right', child: Text('关闭右侧标签')),
        if (showMoveItem)
          PopupMenuItem(
            value: 'move_window',
            enabled: !isAccount,
            child: moveChild,
          ),
        const PopupMenuItem(value: 'copy', child: Text('复制房间链接')),
      ],
    );
    if (value == null) return;
    switch (value) {
      case 'close':
        store.close(descriptor.tabId);
      case 'others':
        unawaited(store.closeOthers(descriptor.tabId));
      case 'right':
        unawaited(store.closeRight(descriptor.tabId));
      case 'move_window':
        unawaited(
          WindowOpenService.instance
              .moveTabToNewWindow(descriptor.tabId),
        );
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
