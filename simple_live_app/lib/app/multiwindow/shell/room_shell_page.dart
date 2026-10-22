import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart' show LiveRoomDetail;
import 'package:window_manager/window_manager.dart';

import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';
import 'package:simple_live_app/services/windows_native_edit.dart';

import 'room_controller_registry.dart';
import 'tab_store.dart';
import 'tab_strip.dart';

class RoomShellPage extends StatefulWidget {
  const RoomShellPage({super.key, this.isSubWindow = false});

  /// 子引擎房间窗：无首页、最后一个标签关闭即关窗、关窗走 close() 不 destroy
  final bool isSubWindow;

  @override
  State<RoomShellPage> createState() => _RoomShellPageState();
}

class _RoomShellPageState extends State<RoomShellPage> with WindowListener {
  /// 关闭流程重入保护：确认框弹出期间窗口关闭事件可能被再次触发
  bool _closing = false;

  Worker? _emptyWorker;
  Worker? _activeWorker;
  Worker? _titleWorker;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    final store = Get.find<TabStore>();
    if (widget.isSubWindow) {
      // IPC close_window 的实际执行者
      SubWindowCommands.closeRequested = _forceClose;
      // 最后一个标签被关掉 → 窗口随之关闭（无首页可停留）
      _emptyWorker = ever(store.tabs, (_) {
        if (store.tabs.isEmpty) {
          unawaited(_forceClose());
        }
      });
    }
    _activeWorker = ever(store.activeTabId, (_) {
      _bindTitle();
      // 旧标签的原生输入 popup 只被 Offstage 遮挡、仍持键盘焦点，不挂起会串房。
      WindowsNativeEdit.instance.suspendSession();
    });
    _bindTitle();
  }

  @override
  void dispose() {
    if (widget.isSubWindow) {
      SubWindowCommands.closeRequested = null;
    }
    _emptyWorker?.dispose();
    _activeWorker?.dispose();
    _titleWorker?.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  /// OS 标题跟随子窗激活标签的房间名
  void _bindTitle() {
    _titleWorker?.dispose();
    _titleWorker = null;
    if (!widget.isSubWindow) return;

    final store = Get.find<TabStore>();
    final id = store.activeTabId.value;
    if (id == null) {
      windowManager.setTitle('Simple Live');
      return;
    }
    final registry = Get.find<RoomControllerRegistry>();
    if (!registry.isRegistered(id)) return;

    final controller = Get.find<LiveRoomController>(tag: id);
    void update(LiveRoomDetail? detail) {
      final title = detail?.title ?? '';
      if (title.isNotEmpty) {
        windowManager.setTitle(title);
      }
    }

    update(controller.detail.value);
    _titleWorker = ever(controller.detail, update);
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    // 立即占据关闭流程：单标签路径不弹确认框，但 closeAll 清空 tabs 会触发
    // _emptyWorker → _forceClose，若不占位会导致 setPreventClose/close 重复
    // 执行（第二条 SC_CLOSE 打进正在销毁的窗口，触发系统错误音）。
    _closing = true;
    final store = Get.find<TabStore>();
    final childWindowCount =
        (!widget.isSubWindow && Get.isRegistered<WindowOpenService>())
            ? WindowOpenService.instance.childWindowCount
            : 0;

    // 单标签且无子窗：直接关，不弹确认（新建子窗只有 1 标签是常态）
    if (store.tabs.length > 1 || childWindowCount > 0) {
      final message = widget.isSubWindow
          ? '还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？'
          : childWindowCount > 0
              ? store.tabs.isNotEmpty
                  ? '还有 ${store.tabs.length} 个直播间标签正在播放，关闭将同时退出 $childWindowCount 个直播间窗口，确定关闭吗？'
                  : '关闭将同时退出 $childWindowCount 个直播间窗口，确定关闭吗？'
              : '还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？';
      final ok = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('关闭窗口'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Get.back(result: true),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (ok != true) {
        _closing = false;
        return;
      }
    }

    if (!widget.isSubWindow && Get.isRegistered<WindowOpenService>()) {
      await WindowOpenService.instance.requestCloseAllChildren();
    }
    await store.closeAll();

    // 主窗也走 close()：先 DestroyWindow 让窗口立即消失，再由主窗
    // quit_on_close（WM_DESTROY→PostQuitMessage）退出进程。原来的
    // destroy() 只 PostQuitMessage、不毁窗，窗口会停留在屏幕上直到引擎/
    // 插件收尾完成才消失，体感为点 × 后卡约 0.5s。
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  /// IPC close_window / 最后标签关闭：不经确认框直接收尾关窗
  Future<void> _forceClose() async {
    if (_closing) return;
    _closing = true;
    final store = Get.find<TabStore>();
    await store.closeAll();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    return Obx(() {
      final activeId = store.activeTabId.value;
      // 当前激活标签处于窗口内沉浸时，连顶部标签条一起隐藏，只剩视频
      final immersive = activeId != null &&
          registry.isRegistered(activeId) &&
          Get.find<LiveRoomController>(tag: activeId)
              .inWindowFullScreenState
              .value;
      return Column(
        children: [
          Offstage(
            offstage: immersive,
            child: const TabStrip(),
          ),
          Expanded(
            child: Obx(() {
              final livePages = <Widget>[
                for (final tab in store.tabs)
                  LiveRoomPage(
                    key: ValueKey(tab.tabId),
                    tag: tab.tabId,
                  ),
              ];

              // 主窗：首页 + 所有标签全部常驻，后台标签持续播放
              if (!widget.isSubWindow) {
                final children = <Widget>[
                  const IndexedPage(),
                  ...livePages,
                ];
                final index = store.activeTabId.value == null
                    ? 0
                    : store.tabs.indexWhere(
                            (t) => t.tabId == store.activeTabId.value) +
                        1;
                return IndexedStack(
                    index: index < 0 ? 0 : index, children: children);
              }

              // 子窗：无首页；收尾瞬间可能为空
              if (livePages.isEmpty) {
                return const SizedBox.shrink();
              }
              final index = store.tabs
                  .indexWhere((t) => t.tabId == store.activeTabId.value);
              return IndexedStack(
                index: index < 0 ? 0 : index,
                children: livePages,
              );
            }),
          ),
        ],
      );
    });
  }
}
