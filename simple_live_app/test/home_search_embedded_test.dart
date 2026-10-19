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

  test('搜索态前台打开房间标签：切到房间标签时搜索自动收起', () {
    final store = TabStore(registry: _FakeRegistry());
    Get.put(store);
    final controller = boot();
    controller.toSearch();
    expect(controller.isSearching.value, isTrue);

    store.open(
      TabOpenRequest(siteId: 'douyin', roomId: '123'),
      activate: true,
    );

    expect(store.activeTabId.value, isNotNull);
    expect(controller.isSearching.value, isFalse,
        reason: '切到房间标签后搜索浮层必须收起，否则原生输入框 popup 仍浮在房间上');
    expect(Get.isRegistered<AppSearchController>(), isFalse);
  });

  test('搜索态后台打开标签（右键新标签页打开）：留在搜索页不收起', () {
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
    expect(Get.isRegistered<AppSearchController>(), isTrue);
  });
}
