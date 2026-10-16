import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/routes/app_navigation.dart';

/// 房间列表项右键菜单（仅 Windows）
///
/// - 新标签页打开：后台创建标签，不切换当前激活标签；
/// - 新窗口打开：独立 OS 窗口游客身份进入；同 siteId+roomId 全局去重，
///   已在任一窗口打开时只置前已有窗口/标签。
///
/// [position] 为右键松开时的全局坐标（onSecondaryTapUp 的
/// TapUpDetails.globalPosition），优先使用；未传时回退到 [context]
/// 对应组件的矩形（写法同 tab_strip.dart 的 showMenu）。
Future<void> showRoomContextMenu({
  required BuildContext context,
  required Site site,
  required String roomId,
  required String shareUrl,
  Offset? position,
}) async {
  // 移动端无右键，不挂载行为
  if (!Platform.isWindows) return;

  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final RelativeRect menuPosition;
  if (position != null) {
    // showMenu 会自行约束在屏幕内
    menuPosition = RelativeRect.fromLTRB(
      position.dx,
      position.dy,
      position.dx + 1,
      position.dy + 1,
    );
  } else {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    menuPosition = RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy,
      overlay.size.width - topLeft.dx - box.size.width,
      overlay.size.height - topLeft.dy - box.size.height,
    );
  }

  final value = await showMenu<String>(
    context: context,
    position: menuPosition,
    items: const [
      PopupMenuItem(value: 'tab', child: Text('新标签页打开')),
      PopupMenuItem(value: 'window', child: Text('新窗口打开')),
    ],
  );
  if (value == 'tab') {
    AppNavigator.toLiveRoomDetail(
      site: site,
      roomId: roomId,
      shareUrl: shareUrl,
      background: true,
    );
  }
  if (value == 'window' && Get.isRegistered<WindowOpenService>()) {
    unawaited(
      WindowOpenService.instance.openInNewWindow(
        TabOpenRequest(siteId: site.id, roomId: roomId, shareUrl: shareUrl),
      ),
    );
  }
}
