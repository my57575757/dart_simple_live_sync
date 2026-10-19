import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_list_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

class HomeController extends GetxController
    with GetSingleTickerProviderStateMixin {
  late TabController tabController;
  HomeController() {
    tabController =
        TabController(length: Sites.supportSites.length, vsync: this);
  }

  /// Windows：搜索是主页标签内的视图（不压路由），标签条始终是壳的那一条
  final isSearching = false.obs;

  /// 切到房间标签时只隐藏视图不结束会话；新会话首次挂载搜索框自动获焦，
  /// 从房间标签切回时不重新抢焦（避免原生 EDIT popup 再次弹出）
  bool _pendingSearchAutofocus = false;

  StreamSubscription<dynamic>? streamSubscription;

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 0) {
          refreshOrScrollTop();
        }
      },
    );
    for (var site in Sites.supportSites) {
      Get.put(HomeListController(site), tag: site.id);
    }

    super.onInit();
  }

  void refreshOrScrollTop() {
    var tabIndex = tabController.index;
    BasePageController controller;
    controller =
        Get.find<HomeListController>(tag: Sites.supportSites[tabIndex].id);
    controller.scrollToTopOrRefresh();
  }

  void toSearch() {
    if (Platform.isWindows) {
      // 壳内主页标签直接置换为搜索视图，避免搜索页压住壳路由
      if (!Get.isRegistered<AppSearchController>()) {
        Get.put(AppSearchController());
      }
      _pendingSearchAutofocus = true;
      isSearching.value = true;
    } else {
      Get.toNamed(RoutePath.kSearch);
    }
  }

  /// 搜索浮层是否可见：搜索会话进行中且主页标签处于激活态。
  /// 切到房间标签时 SearchPage 卸载（原生 EDIT popup 随 dispose 隐藏），
  /// 但搜索控制器与会话保留，切回主页即恢复。
  bool get isSearchOverlayVisible {
    if (!isSearching.value) return false;
    if (!Get.isRegistered<TabStore>()) return true;
    return Get.find<TabStore>().isHomeActive;
  }

  /// HomePage 挂载 SearchPage 时取本次会话是否自动获焦（取一次即消费）
  bool takeSearchAutofocus() {
    final v = _pendingSearchAutofocus;
    _pendingSearchAutofocus = false;
    return v;
  }

  /// Windows 退出壳内搜索视图：销毁搜索态全部控制器，等同原路由 pop 的清理
  void closeSearch() {
    if (!isSearching.value) return;
    isSearching.value = false;
    for (final site in Sites.supportSites) {
      Get.delete<SearchListController>(tag: site.id);
    }
    Get.delete<AppSearchController>();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    super.onClose();
  }
}
