import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

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
}
