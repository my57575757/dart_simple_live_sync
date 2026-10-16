import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../presence/douyin_presence_gateway.dart';
import 'room_controller_registry.dart';
import 'tab_descriptor.dart';
import 'tab_open_request.dart';

class TabStore extends GetxController {
  TabStore({
    required this.registry,
    this.hasHome = true,
    this.presenceGateway,
  });

  final RoomControllerRegistry registry;
  final bool hasHome;

  /// Windows 标签壳注入；null（单元测试 / 未来其他宿主）时行为与 M2 完全一致
  final DouyinPresenceGateway? presenceGateway;

  final _uuid = const Uuid();

  final RxList<TabDescriptor> tabs = <TabDescriptor>[].obs;
  final RxnString activeTabId = RxnString();

  bool get isHomeActive => activeTabId.value == null;

  TabDescriptor? get activeTab {
    final id = activeTabId.value;
    if (id == null) return null;
    return tabs.firstWhereOrNull((t) => t.tabId == id);
  }

  /// 打开（或激活已存在的）直播间标签
  /// [activate]=false 时为后台打开：去重命中不激活、新建也不切换激活标签
  TabDescriptor open(TabOpenRequest request, {bool activate = true}) {
    final existing =
        tabs.firstWhereOrNull((t) => t.request.key == request.key);
    if (existing != null) {
      if (activate) {
        activeTabId.value = existing.tabId;
      }
      return existing;
    }
    final tabId = _uuid.v4();
    // 激活态必须先于 register 设置：register 同步触发 Get.put→onInit→
    // loadData，控制器在其同步头内据此判定前/后台，决定是否弹全局 loading；
    // 若在 register 之后才赋值，首次左键前台开标签也会被误判为后台。
    // 激活态先于 tabs 成员关系只存在于 register 的同步调用栈内——Obx 最早
    // 下一帧重建，届时 tabs.add 已完成。
    final previousActive = activeTabId.value;
    if (activate) {
      activeTabId.value = tabId;
    }
    try {
      registry.register(tabId, request);
    } catch (_) {
      // 防御 register 失败（如未知 site）：恢复原激活态，避免悬空指向
      // 尚未加入 tabs 的标签，然后原样抛出
      activeTabId.value = previousActive;
      rethrow;
    }
    final descriptor = TabDescriptor(tabId: tabId, request: request);
    tabs.add(descriptor);
    return descriptor;
  }

  void activate(String tabId) {
    if (tabs.any((t) => t.tabId == tabId)) {
      activeTabId.value = tabId;
    }
  }

  void activateHome() {
    if (hasHome) activeTabId.value = null;
  }

  /// 按 siteId_roomId 查找标签（跨窗全局去重用）
  TabDescriptor? findByKey(String key) =>
      tabs.firstWhereOrNull((t) => t.request.key == key);

  /// 跨窗 IPC 置前：按 siteId_roomId 激活本窗标签
  void activateByKey(String key) {
    final tab = findByKey(key);
    if (tab != null) {
      activeTabId.value = tab.tabId;
    }
  }

  TabDescriptor close(String tabId) {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final removed = tabs.removeAt(index);
    registry.unregister(tabId);
    if (activeTabId.value == tabId) {
      activeTabId.value =
          tabs.isEmpty ? null : tabs[index.clamp(0, tabs.length - 1)].tabId;
    }
    return removed;
  }

  Future<void> closeOthers(String tabId) async {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final victims = tabs.where((t) => t.tabId != tabId).toList();
    // 必须先摘栈再销毁控制器：否则 holder 关闭会对同样即将销毁的次新标签
    // 连环发起 enter/exit；幸存者由网关一次性接管
    await presenceGateway?.batchRelease(
      victims.map((t) => t.tabId).toSet(),
    );
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    activeTabId.value = tabId;
  }

  Future<void> closeRight(String tabId) async {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final victims = tabs.sublist(index + 1);
    await presenceGateway?.batchRelease(
      victims.map((t) => t.tabId).toSet(),
    );
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    if (!tabs.any((t) => t.tabId == activeTabId.value)) {
      activeTabId.value = tabId;
    }
  }

  /// 参数语义同 ReorderableListView.onReorder（old>new 时调用方已减 1）
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    final t = tabs.removeAt(oldIndex);
    tabs.insert(newIndex.clamp(0, tabs.length), t);
  }

  Future<void> closeAll() async {
    final all = tabs.toList();
    await presenceGateway?.batchRelease(
      all.map((t) => t.tabId).toSet(),
    );
    for (final t in all) {
      registry.unregister(t.tabId);
    }
    tabs.clear();
    activeTabId.value = null;
  }
}
