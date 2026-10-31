import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import '../presence/presence_batch_releaser.dart';
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

  /// Windows 标签壳注入；null（单元测试 / 未来其他宿主）时行为与 M2 完全一致。
  /// 主引擎传 DouyinPresenceGateway，子引擎传 IpcPresenceCoordinator。
  final PresenceBatchReleaser? presenceGateway;

  final _uuid = const Uuid();

  /// 批量菜单防抖：closeOthers/closeRight/closeAll 任一在途时，其余批量
  /// 调用直接 no-op（终态幂等），杜绝快速两次批量操作的"刚 enter 即 exit"
  /// 抖动（spec §7 #8）。单标签 close() 不受此门控。
  bool _batchClosing = false;

  Future<void> _batchGuarded(Future<void> Function() body) async {
    if (_batchClosing) return;
    _batchClosing = true;
    try {
      await body();
    } finally {
      _batchClosing = false;
    }
  }

  final RxList<TabDescriptor> tabs = <TabDescriptor>[].obs;
  final RxnString activeTabId = RxnString();

  /// 已启动但尚未完成的播放器释放。子窗关掉最后一个标签时，页面移除会同步
  /// 触发空窗监听→关窗；关窗的 _closeAll 必须等这批在途释放完成，否则
  /// player.dispose 会与 DestroyWindow 的子引擎同步销毁赛跑（libmpv 野回调）。
  final Set<Future<void>> _pendingReleases = <Future<void>>{};

  /// 页面已摘出树后、Get.delete 前启动播放器的有序释放（幂等，onClose 复用）。
  void _beginPlayerRelease(String tabId) {
    final controller = registry.controllerForTabId(tabId);
    if (controller == null) return;
    final future = controller.ensurePlayerReleased();
    _pendingReleases.add(future);
    future.whenComplete(() => _pendingReleases.remove(future));
  }

  bool get isHomeActive => activeTabId.value == null;

  TabDescriptor? get activeTab {
    final id = activeTabId.value;
    if (id == null) return null;
    return tabs.firstWhereOrNull((t) => t.tabId == id);
  }

  /// 打开（或激活已存在的）直播间标签
  /// [activate]=false 时为后台打开：去重命中不激活、新建也不切换激活标签
  TabDescriptor open(TabOpenRequest request,
      {bool activate = true, String? tabId}) {
    final existing =
        tabs.firstWhereOrNull((t) => t.request.key == request.key);
    if (existing != null) {
      if (activate) {
        activeTabId.value = existing.tabId;
      }
      return existing;
    }
    final id = tabId ?? _uuid.v4();
    // 激活态必须先于 register 设置：register 同步触发 Get.put→onInit→
    // loadData，控制器在其同步头内据此判定前/后台，决定是否弹全局 loading；
    // 若在 register 之后才赋值，首次左键前台开标签也会被误判为后台。
    // 激活态先于 tabs 成员关系只存在于 register 的同步调用栈内——Obx 最早
    // 下一帧重建，届时 tabs.add 已完成。
    final previousActive = activeTabId.value;
    if (activate) {
      activeTabId.value = id;
    }
    try {
      registry.register(id, request);
    } catch (_) {
      // 防御 register 失败（如未知 site）：恢复原激活态，避免悬空指向
      // 尚未加入 tabs 的标签，然后原样抛出
      activeTabId.value = previousActive;
      rethrow;
    }
    final descriptor = TabDescriptor(tabId: id, request: request);
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
    // 先摘页面、启动有序释放，再 Get.delete：onClose 复用同一释放 Future，
    // 释放期间已无仍挂载的 Video 组件会读到已 dispose 的播放器。
    _beginPlayerRelease(tabId);
    registry.unregister(tabId);
    if (activeTabId.value == tabId) {
      activeTabId.value =
          tabs.isEmpty ? null : tabs[index.clamp(0, tabs.length - 1)].tabId;
    }
    return removed;
  }

  /// 跨窗迁移关闭：先标记控制器「已迁走」抑制其 onClose 的 presence leave
  /// （心跳/仲裁栈由主端 rehome 延续），其余与 close 完全相同。
  TabDescriptor closeForMove(String tabId) {
    registry.controllerForTabId(tabId)?.markMovedAway();
    return close(tabId);
  }

  Future<void> closeOthers(String tabId) =>
      _batchGuarded(() => _closeOthers(tabId));

  Future<void> _closeOthers(String tabId) async {
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

  Future<void> closeRight(String tabId) =>
      _batchGuarded(() => _closeRight(tabId));

  Future<void> _closeRight(String tabId) async {
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

  Future<void> closeAll() => _batchGuarded(_closeAll);

  Future<void> _closeAll() async {
    final all = tabs.toList();
    await presenceGateway?.batchRelease(
      all.map((t) => t.tabId).toSet(),
    );
    // 汇总本批控制器的有序释放，并带上此前单标签 close() 在途的释放（子窗
    // 最后一个标签 × 会先经 close() 启动释放、tabs 变空后同步触发关窗）。
    final releases = <Future<void>>[..._pendingReleases];
    for (final t in all) {
      final controller = registry.controllerForTabId(t.tabId);
      if (controller != null) {
        releases.add(controller.ensurePlayerReleased());
      }
    }
    // 摘出页面后再等释放完成：释放期间不再有挂载中的 Video 组件读到已销毁的
    // 播放器；随后的 Get.delete 触发 onClose 时释放早已完成（复用同一 Future）。
    tabs.clear();
    activeTabId.value = null;
    await Future.wait(releases);
    for (final t in all) {
      registry.unregister(t.tabId);
    }
  }
}
