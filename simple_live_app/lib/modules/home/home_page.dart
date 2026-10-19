import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/home/home_list_view.dart';
import 'package:simple_live_app/modules/search/search_page.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 用 Stack 浮盖而非替换：搜索态开关时主页 Scaffold 及其列表滚动/播放
    // 状态始终挂载保活（与原「搜索页压路由、主页在底层不卸载」的行为一致）
    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(
            titleSpacing: 8,
            title: TabBar(
              controller: controller.tabController,
              labelPadding: AppStyle.edgeInsetsH20,
              isScrollable: true,
              indicatorSize: TabBarIndicatorSize.label,
              tabAlignment: TabAlignment.center,
              tabs: Sites.supportSites
                  .map(
                    (e) => Tab(
                      //text: e.name,

                      child: Row(
                        children: [
                          Image.asset(
                            e.logo,
                            width: 24,
                          ),
                          AppStyle.hGap8,
                          Text(e.name),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
            actions: [
              IconButton(
                onPressed: controller.toSearch,
                icon: const Icon(Icons.search),
              )
            ],
          ),
          body: TabBarView(
            controller: controller.tabController,
            children: Sites.supportSites
                .map(
                  (e) => HomeListView(
                    e.id,
                  ),
                )
                .toList(),
          ),
        ),
        Obx(
          () => controller.isSearching.value
              ? SearchPage(onBack: controller.closeSearch)
              : const SizedBox.shrink(),
        ),
      ],
    );
  }
}
