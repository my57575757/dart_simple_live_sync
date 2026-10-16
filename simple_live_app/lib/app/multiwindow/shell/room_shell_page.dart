import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';

import 'tab_store.dart';
import 'tab_strip.dart';

class RoomShellPage extends StatefulWidget {
  const RoomShellPage({super.key});

  @override
  State<RoomShellPage> createState() => _RoomShellPageState();
}

class _RoomShellPageState extends State<RoomShellPage> with WindowListener {
  /// 关闭流程重入保护：确认框弹出期间窗口关闭事件可能被再次触发
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    final store = Get.find<TabStore>();
    if (store.tabs.isNotEmpty) {
      // 决定进入关闭流程即占位，防止确认框弹出期间重复触发
      _closing = true;
      final ok = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('关闭窗口'),
          content: Text('还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？'),
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
        // 取消：复位以保证再次点 X 仍能弹框
        _closing = false;
        return;
      }
    }
    await store.closeAll();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    return Column(
      children: [
        const TabStrip(),
        Expanded(
          child: Obx(() {
            // 首页 + 所有标签全部常驻：后台标签持续播放
            final children = <Widget>[
              const IndexedPage(),
              for (final t in store.tabs)
                LiveRoomPage(
                  key: ValueKey(t.tabId),
                  tag: t.tabId,
                ),
            ];
            final index = store.activeTabId.value == null
                ? 0
                : store.tabs.indexWhere((t) => t.tabId == store.activeTabId.value) + 1;
            return IndexedStack(index: index < 0 ? 0 : index, children: children);
          }),
        ),
      ],
    );
  }
}
