import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/mine/account/account_controller.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';

class AccountPage extends GetView<AccountController> {
  const AccountPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("账号管理"),
      ),
      body: ListView(
        children: [
          const Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "登录后可在直播间发送弹幕，哔哩哔哩登录后还可观看高清晰度直播。",
              textAlign: TextAlign.center,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/bilibili_2.png',
                width: 36,
                height: 36,
              ),
              title: const Text("哔哩哔哩"),
              subtitle: Text(BiliBiliAccountService.instance.name.value),
              trailing: BiliBiliAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.bilibiliTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyu.png',
                width: 36,
                height: 36,
              ),
              title: const Text("斗鱼直播"),
              subtitle: Text(DouyuAccountService.instance.name.value),
              trailing: DouyuAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyuTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/huya.png',
                width: 36,
                height: 36,
              ),
              title: const Text("虎牙直播"),
              subtitle: Text(HuyaAccountService.instance.name.value),
              trailing: HuyaAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.huyaTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyin.png',
                width: 36,
                height: 36,
              ),
              title: const Text("抖音直播"),
              subtitle: Text(DouyinAccountService.instance.logined.value
                  ? "账号已登录"
                  : DouyinAccountService.instance.hasCookie.value
                      ? "自定义 ttwid（${DouyinAccountService.instance.cookie.length} 字符）"
                      : "使用默认 ttwid"),
              trailing: DouyinAccountService.instance.logined.value ||
                      DouyinAccountService.instance.hasCookie.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyinTap,
            ),
          ),
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/twitch.png',
                width: 36,
                height: 36,
              ),
              title: const Text("Twitch"),
              subtitle: Text(TwitchAccountService.instance.configured.value
                  ? "已配置 Helix 接口"
                  : "匿名模式（无需配置）"),
              trailing: TwitchAccountService.instance.configured.value
                  ? const Icon(Icons.delete_outline)
                  : const Icon(Icons.chevron_right),
              onTap: controller.twitchTap,
            ),
          ),
        ],
      ),
    );
  }
}
