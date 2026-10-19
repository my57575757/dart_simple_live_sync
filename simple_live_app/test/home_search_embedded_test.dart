import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _FakeRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}

  @override
  void unregister(String tabId) {}

  @override
  bool isRegistered(String tabId) => false;

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;

  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

void main() {
  setUp(() {
    Get.put<LocalStorageService>(InMemoryLocalStorageService(),
        permanent: true);
    Get.put(AppSettingsController());
  });

  tearDown(() async {
    await Get.delete<HomeController>();
    Get.reset();
  });

  HomeController boot() {
    // Get.put 触发 onInit：为每个站点注册 HomeListController
    return Get.put(HomeController());
  }

  test('Windows：toSearch 在主页标签内置换搜索视图，不压新路由', () {
    final controller = boot();

    expect(controller.isSearching.value, isFalse);
    controller.toSearch();

    expect(controller.isSearching.value, isTrue);
    expect(Get.isRegistered<AppSearchController>(), isTrue,
        reason: '搜索视图所需控制器随进入动作注册');
  });

  test('closeSearch：回到主页并注销搜索控制器（等同原路由 pop 的清理）', () {
    final controller = boot();
    controller.toSearch();

    controller.closeSearch();

    expect(controller.isSearching.value, isFalse);
    expect(Get.isRegistered<AppSearchController>(), isFalse,
        reason: '退出搜索后搜索态控制器必须销毁，关键词/TabController 不残留');
  });

  test('再次进入搜索：注册的是新实例，旧输入不残留', () {
    final controller = boot();
    controller.toSearch();
    final first = Get.find<AppSearchController>();
    first.searchController.text = '残留关键词';
    controller.closeSearch();

    controller.toSearch();
    final second = Get.find<AppSearchController>();

    expect(identical(first, second), isFalse);
    expect(second.searchController.text, isEmpty);
  });

  test('搜索态前台打开房间标签：浮层隐藏但搜索会话保留（控制器不销毁）', () {
    final store = TabStore(registry: _FakeRegistry());
    Get.put(store);
    final controller = boot();
    controller.toSearch();
    Get.find<AppSearchController>().searchController.text = '主播名';
    expect(controller.isSearching.value, isTrue);

    store.open(
      TabOpenRequest(siteId: 'douyin', roomId: '123'),
      activate: true,
    );

    expect(store.activeTabId.value, isNotNull);
    expect(controller.isSearching.value, isTrue,
        reason: '切到房间标签不结束搜索会话，切回主页还要看到搜索页');
    expect(controller.isSearchOverlayVisible, isFalse,
        reason: '房间标签激活时搜索浮层必须不可见，原生 popup 随之 dispose 隐藏');
    expect(Get.isRegistered<AppSearchController>(), isTrue);
  });

  test('从房间标签切回主页：搜索浮层恢复，关键词与控制器实例保留', () {
    final store = TabStore(registry: _FakeRegistry());
    Get.put(store);
    final controller = boot();
    controller.toSearch();
    final searchController = Get.find<AppSearchController>();
    searchController.searchController.text = '主播名';
    store.open(
      TabOpenRequest(siteId: 'douyin', roomId: '123'),
      activate: true,
    );
    expect(controller.isSearchOverlayVisible, isFalse);

    store.activateHome();

    expect(controller.isSearchOverlayVisible, isTrue);
    expect(identical(Get.find<AppSearchController>(), searchController), isTrue);
    expect(Get.find<AppSearchController>().searchController.text, '主播名',
        reason: '切回后搜索词仍在');
  });

  test('搜索态后台打开标签（右键新标签页打开）：仍停留在搜索页', () {
    final store = TabStore(registry: _FakeRegistry());
    Get.put(store);
    final controller = boot();
    controller.toSearch();

    store.open(
      TabOpenRequest(siteId: 'douyin', roomId: '123'),
      activate: false,
    );

    expect(store.activeTabId.value, isNull);
    expect(controller.isSearching.value, isTrue);
    expect(controller.isSearchOverlayVisible, isTrue);
    expect(Get.isRegistered<AppSearchController>(), isTrue);
  });
}
