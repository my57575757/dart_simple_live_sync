import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/search_controller.dart';
import 'package:simple_live_app/modules/search/search_list_view.dart';
import 'package:simple_live_app/widgets/native_edit_field.dart';

class SearchPage extends GetView<AppSearchController> {
  const SearchPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final modeDropdown = Obx(
      () => DropdownButton<int>(
        underline: const SizedBox(),
        items: const [
          DropdownMenuItem(
            value: 0,
            child: Text("房间"),
          ),
          DropdownMenuItem(
            value: 1,
            child: Text("主播"),
          ),
        ],
        value: controller.searchMode.value,
        onChanged: (e) {
          controller.searchMode.value = e ?? 0;
          controller.doSearch();
        },
      ),
    );

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Platform.isWindows
            ? Row(
                children: [
                  IconButton(
                    onPressed: Get.back,
                    icon: const Icon(Icons.arrow_back),
                  ),
                  modeDropdown,
                  AppStyle.hGap8,
                  Expanded(
                    child: NativeEditField(
                      controller: controller.searchField,
                      autofocus: true,
                      hintText: '搜点什么吧',
                      radius: 24,
                      onSubmitted: (_) => controller.doSearch(),
                    ),
                  ),
                  IconButton(
                    // 原生 popup 里未提交的文本先同步回 controller 再搜索。
                    onPressed: () async {
                      await controller.searchField.commit();
                      controller.doSearch();
                    },
                    icon: const Icon(Icons.search),
                  ),
                ],
              )
            : TextField(
                controller: controller.searchController,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: "搜点什么吧",
                  border: OutlineInputBorder(
                    borderRadius: AppStyle.radius24,
                  ),
                  contentPadding: AppStyle.edgeInsetsH12,
                  prefixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: Get.back,
                        icon: const Icon(Icons.arrow_back),
                      ),
                      modeDropdown,
                      AppStyle.hGap8,
                    ],
                  ),
                  suffixIcon: IconButton(
                    onPressed: controller.doSearch,
                    icon: const Icon(Icons.search),
                  ),
                ),
                onSubmitted: (e) {
                  controller.doSearch();
                },
              ),
        bottom: TabBar(
          controller: controller.tabController,
          padding: EdgeInsets.zero,
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
          labelPadding: AppStyle.edgeInsetsH20,
          isScrollable: true,
          indicatorSize: TabBarIndicatorSize.label,
        ),
      ),
      body: TabBarView(
        physics: const NeverScrollableScrollPhysics(),
        controller: controller.tabController,
        children: Sites.supportSites
            .map((e) => SearchListView(
                      e.id,
                    )
                // (e) => e.id == Constant.kDouyin
                //     ? const DouyinSearchView()
                //     : SearchListView(
                //         e.id,
                //       ),
                )
            .toList(),
      ),
    );
  }
}
