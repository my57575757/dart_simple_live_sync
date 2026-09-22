import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';
import 'package:simple_live_tv_app/services/bilibili_account_service.dart';
import 'package:simple_live_tv_app/services/twitch_account_service.dart';

class SettingsController extends BaseController
    with GetTickerProviderStateMixin {
  late TabController tabController;
  var tabIndex = 0.obs;

  SettingsController() {
    tabController = TabController(length: 5, vsync: this);
    tabController.animation?.addListener(() {
      var currentIndex = (tabController.animation?.value ?? 0).round();
      if (tabIndex.value == currentIndex) {
        return;
      }
      tabIndex.value = currentIndex;
      if (tabIndex.value == 0) {
        hardwareDecodeFocusNode.requestFocus();
      }
      if (tabIndex.value == 1) {
        danmakuFoucsNode.requestFocus();
      }
      if (tabIndex.value == 2) {
        autoUpdateFollowEnableFocusNode.requestFocus();
      }
      if (tabIndex.value == 3) {
        bilibiliFoucsNode.requestFocus();
      }
      if (tabIndex.value == 4) {
        versionFocusNode.requestFocus();
      }
    });
  }
  var hardwareDecodeFocusNode = AppFocusNode()..isFoucsed.value = true;
  var compatibleModeFocusNode = AppFocusNode();
  var scaleFoucsNode = AppFocusNode();
  var defaultQualityFocusNode = AppFocusNode();
  var danmakuFoucsNode = AppFocusNode();
  var danmakuSizeFoucsNode = AppFocusNode();
  var danmakuSpeedFoucsNode = AppFocusNode();
  var danmakuAreaFoucsNode = AppFocusNode();
  var danmakuOpacityFoucsNode = AppFocusNode();
  var danmakuStorkeFoucsNode = AppFocusNode();

  var autoUpdateFollowEnableFocusNode = AppFocusNode();
  var autoUpdateFollowDurationFocusNode = AppFocusNode();
  var updateFollowThreadFocusNode = AppFocusNode();

  var bilibiliFoucsNode = AppFocusNode();
  var twitchFocusNode = AppFocusNode();
  var versionFocusNode = AppFocusNode();

  void twitchTap() async {
    if (TwitchAccountService.instance.configured.value) {
      var result = await Utils.showAlertDialog("确定要清除 Twitch 接口配置吗？", title: "清除配置");
      if (result) {
        TwitchAccountService.instance.clearConfig();
        SmartDialog.showToast("已清除配置，使用匿名模式");
      }
    } else {
      showTwitchConfigDialog();
    }
  }

  void showTwitchConfigDialog() {
    var clientIdController = TextEditingController(
      text: TwitchAccountService.instance.clientId,
    );
    var tokenController = TextEditingController(
      text: TwitchAccountService.instance.oauthToken,
    );
    Get.dialog(
      AlertDialog(
        title: const Text("Twitch 接口配置（可选）"),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "默认匿名模式可直接使用。若匿名接口受限，可在 dev.twitch.tv/console 注册应用并填写 App Access Token。留空保存即恢复匿名模式。",
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: clientIdController,
                  decoration: const InputDecoration(
                    hintText: "Client ID（留空使用内置值）",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: tokenController,
                  decoration: const InputDecoration(
                    hintText: "OAuth App Access Token",
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              Get.back();
              TwitchAccountService.instance.setConfig(
                clientId: clientIdController.text.trim(),
                oauthToken: tokenController.text.trim(),
              );
              SmartDialog.showToast(
                TwitchAccountService.instance.configured.value
                    ? "已切换到 Helix 接口"
                    : "已保存，使用匿名模式",
              );
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      AppNavigator.toBiliBiliLogin();
    }
  }

}
