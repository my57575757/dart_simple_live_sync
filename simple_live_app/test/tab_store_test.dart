import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';

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

  test('closeOthers / closeRight', () {
    final t1 = store.open(req('a', '1'));
    store.open(req('a', '2'));
    store.open(req('a', '3'));
    store.closeOthers(t1.tabId);
    expect(store.tabs.single.tabId, t1.tabId);
    expect(store.activeTabId.value, t1.tabId);

    store.open(req('a', '2'));
    store.open(req('a', '3'));
    store.closeRight(t1.tabId);
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
}
