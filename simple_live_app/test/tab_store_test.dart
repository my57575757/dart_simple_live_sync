import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_batch_releaser.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

TabOpenRequest req(String site, String room, [String share = ""]) =>
    TabOpenRequest(siteId: site, roomId: room, shareUrl: share);

class FakeRegistry implements RoomControllerRegistry {
  final registered = <String, TabOpenRequest>{};
  @override
  void register(String tabId, TabOpenRequest request) =>
      registered[tabId] = request;
  @override
  void unregister(String tabId) => registered.remove(tabId);
  @override
  bool isRegistered(String tabId) => registered.containsKey(tabId);

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;

  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

/// register 同步抛错（模拟未知 site），用于验证 open 的激活态回滚
class ThrowingRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) =>
      throw ArgumentError('unknown site: ${request.siteId}');
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;

  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

/// 首次 register 成功、其后抛错，模拟打开第二个标签时控制器初始化失败
class FakeThenThrowRegistry extends FakeRegistry {
  int registerCalls = 0;
  @override
  void register(String tabId, TabOpenRequest request) {
    registerCalls++;
    if (registerCalls > 1) {
      throw ArgumentError('boom');
    }
    super.register(tabId, request);
  }
}

class _BlockingReleaser implements PresenceBatchReleaser {
  int calls = 0;
  final Completer<void> entered = Completer<void>();
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> batchRelease(Set<String> tabIds) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate.future;
  }
}

void main() {
  late FakeRegistry registry;
  late TabStore store;

  setUp(() {
    registry = FakeRegistry();
    store = TabStore(registry: registry);
  });

  test('初始无标签，首页为激活态', () {
    expect(store.tabs, isEmpty);
    expect(store.isHomeActive, true);
    expect(store.activeTab, null);
  });

  test('open 注册控制器、加标签并激活', () {
    final t = store.open(req('douyin', 'r1'));
    expect(store.tabs.single.tabId, t.tabId);
    expect(store.activeTabId.value, t.tabId);
    expect(registry.registered[t.tabId]?.roomId, 'r1');
    expect(store.isHomeActive, false);
  });

  test('同 site+room 再 open 不重复创建，只激活已有标签', () {
    final t1 = store.open(req('douyin', 'r1'));
    store.open(req('douyin', 'r2'));
    final again = store.open(req('douyin', 'r1'));
    expect(store.tabs.length, 2);
    expect(again.tabId, t1.tabId);
    expect(store.activeTabId.value, t1.tabId);
    expect(registry.registered.length, 2);
  });

  test('关闭激活标签后激活相邻标签并注销控制器', () {
    final t1 = store.open(req('douyin', 'r1'));
    final t2 = store.open(req('douyin', 'r2'));
    store.close(t1.tabId);
    expect(store.tabs.single.tabId, t2.tabId);
    expect(store.activeTabId.value, t2.tabId);
    expect(registry.registered.containsKey(t1.tabId), false);
  });

  test('关闭最后一个标签回到首页', () {
    final t = store.open(req('douyin', 'r1'));
    store.close(t.tabId);
    expect(store.tabs, isEmpty);
    expect(store.isHomeActive, true);
    expect(registry.registered, isEmpty);
  });

  test('关闭非激活标签不改变激活态', () {
    store.open(req('a', '1'));
    final t2 = store.open(req('a', '2'));
    store.activate(store.tabs.first.tabId);
    store.close(t2.tabId);
    expect(store.activeTabId.value, store.tabs.single.tabId);
  });

  test('closeOthers / closeRight', () async {
    final t1 = store.open(req('a', '1'));
    store.open(req('a', '2'));
    store.open(req('a', '3'));
    await store.closeOthers(t1.tabId);
    expect(store.tabs.single.tabId, t1.tabId);
    expect(store.activeTabId.value, t1.tabId);

    store.open(req('a', '2'));
    store.open(req('a', '3'));
    await store.closeRight(t1.tabId);
    expect(store.tabs.map((t) => t.request.roomId), ['1']);
  });

  test('reorder 使用 ListView onReorder 语义', () {
    final t1 = store.open(req('a', '1'));
    final t2 = store.open(req('a', '2'));
    final t3 = store.open(req('a', '3'));
    store.reorder(2, 0); // 3 移到最前
    expect(store.tabs.map((t) => t.tabId), [t3.tabId, t1.tabId, t2.tabId]);
    expect(store.activeTabId.value, isNotNull);
  });

  test('closeAll 注销全部控制器并回首页', () async {
    store.open(req('a', '1'));
    store.open(req('a', '2'));
    await store.closeAll();
    expect(store.tabs, isEmpty);
    expect(registry.registered, isEmpty);
    expect(store.isHomeActive, true);
  });

  test('closeOthers 未知 tabId 抛 ArgumentError 且不改动标签', () async {
    store.open(req('a', '1'));
    await expectLater(store.closeOthers('nope'), throwsArgumentError);
    expect(store.tabs.length, 1);
    expect(registry.registered.length, 1);
  });

  test('closeRight 未知 tabId 抛 ArgumentError 且不改动标签', () async {
    store.open(req('a', '1'));
    await expectLater(store.closeRight('nope'), throwsArgumentError);
    expect(store.tabs.length, 1);
    expect(registry.registered.length, 1);
  });

  test('后台打开新标签：tabs +1 但不激活（首页态），随后普通打开才切换', () {
    final t1 = store.open(req('douyin', 'r1'), activate: false);
    expect(store.tabs.single.tabId, t1.tabId);
    expect(registry.registered.containsKey(t1.tabId), true);
    expect(store.activeTabId.value, null);
    expect(store.isHomeActive, true);

    final t2 = store.open(req('douyin', 'r2'));
    expect(store.tabs.length, 2);
    expect(store.activeTabId.value, t2.tabId);
  });

  test('后台打开已存在标签：不新增、不改变当前激活', () {
    final a = store.open(req('douyin', 'A'));
    final b = store.open(req('douyin', 'B'));
    expect(store.activeTabId.value, b.tabId);

    final again = store.open(req('douyin', 'A'), activate: false);
    expect(again.tabId, a.tabId);
    expect(store.tabs.length, 2);
    expect(registry.registered.length, 2);
    expect(store.activeTabId.value, b.tabId);
  });

  test('register 抛异常（首页态）：不加标签、激活态恢复 null 并原样抛出', () {
    final failingStore = TabStore(registry: ThrowingRegistry());
    expect(
      () => failingStore.open(req('unknown-site', 'x')),
      throwsArgumentError,
    );
    expect(failingStore.tabs, isEmpty);
    expect(failingStore.activeTabId.value, null);
    expect(failingStore.isHomeActive, true);
  });

  test('register 抛异常（已有激活标签）：激活态回滚为原标签、不加新标签', () {
    final mixedRegistry = FakeThenThrowRegistry();
    final mixedStore = TabStore(registry: mixedRegistry);
    final t1 = mixedStore.open(req('douyin', 'r1'));
    expect(mixedStore.activeTabId.value, t1.tabId);

    expect(
      () => mixedStore.open(req('douyin', 'r2')),
      throwsArgumentError,
    );
    expect(mixedStore.tabs.single.tabId, t1.tabId);
    expect(mixedStore.activeTabId.value, t1.tabId);
  });

  test('findByKey 与 activateByKey（跨窗置前用）', () {
    final t1 = store.open(req('douyin', 'r1'));
    final t2 = store.open(req('douyin', 'r2'));
    store.activate(t2.tabId);
    expect(store.activeTabId.value, t2.tabId);

    store.activateByKey('douyin_r1');
    expect(store.activeTabId.value, t1.tabId);
    expect(store.findByKey('douyin_r1')?.tabId, t1.tabId);
    expect(store.findByKey('douyin_missing'), isNull);
    store.activateByKey('douyin_missing');
    expect(store.activeTabId.value, t1.tabId, reason: '未命中不改变激活态');
  });

  test('#8 批量流程在途时再次批量操作直接 no-op，结束后恢复', () async {
    final releaser = _BlockingReleaser();
    final s = TabStore(registry: registry, presenceGateway: releaser);
    s.open(req('a', '1'));
    s.open(req('a', '2'));
    final first = s.closeAll();
    await releaser.entered.future; // 首批量卡在 batchRelease 在途

    // 在途期间：tabs 尚未清空（摘栈 await 之后才 unregister/clear）
    await s.closeAll();
    await s.closeOthers(s.tabs.first.tabId);
    await s.closeRight(s.tabs.first.tabId);
    expect(releaser.calls, 1, reason: '在途期间只允许一个批量摘栈');

    releaser.gate.complete();
    await first;
    expect(s.tabs, isEmpty);

    // 流程结束后批量能力恢复
    s.open(req('a', '9'));
    await s.closeAll();
    expect(releaser.calls, 2);
  });
}
