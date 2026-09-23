import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/core_error.dart';

class AccountController extends GetxController {
  void bilibiliTap() async {
    if (BiliBiliAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出哔哩哔哩账号吗？", title: "退出登录");
      if (result) {
        BiliBiliAccountService.instance.logout();
      }
    } else {
      //AppNavigator.toBiliBiliLogin();
      bilibiliLogin();
    }
  }

  void bilibiliLogin() {
    Utils.showBottomSheet(
      title: "登录哔哩哔哩",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Visibility(
            visible: Platform.isAndroid || Platform.isIOS,
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined),
              title: const Text("Web登录"),
              subtitle: const Text("填写用户名密码登录"),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Get.back();
                Get.toNamed(RoutePath.kBiliBiliWebLogin);
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code),
            title: const Text("扫码登录"),
            subtitle: const Text("使用哔哩哔哩APP扫描二维码登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              Get.toNamed(RoutePath.kBiliBiliQRLogin);
            },
          ),
          ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text("Cookie登录"),
            subtitle: const Text("手动输入Cookie登录"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doBiliBiliCookieLogin();
            },
          ),
        ],
      ),
    );
  }

  void doBiliBiliCookieLogin() async {
    var cookie = await Utils.showEditTextDialog(
      "",
      title: "请输入Cookie",
      hintText: "请输入Cookie",
    );
    if (cookie == null || cookie.isEmpty) {
      return;
    }
    BiliBiliAccountService.instance.setCookie(cookie);
    await BiliBiliAccountService.instance.loadUserInfo();
  }

  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出斗鱼账号吗？", title: "退出登录");
      if (result) {
        DouyuAccountService.instance.logout();
      }
    } else {
      DouyuAccountService.instance.startWebLogin();
    }
  }

  void huyaTap() async {
    if (HuyaAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出虎牙账号吗？", title: "退出登录");
      if (result) {
        HuyaAccountService.instance.logout();
      }
    } else {
      HuyaAccountService.instance.startWebLogin();
    }
  }

  void douyinTap() {
    douyinMenu();
  }

  void douyinLoginTap() {
    DouyinAccountService.instance.logout();
    SmartDialog.showToast("已退出抖音账号");
  }

  void douyinLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "抖音账号登录",
        startUrl: "https://live.douyin.com",
        cookieUrl: "https://live.douyin.com",
        userAgent: WebLoginArgs.desktopUserAgent,
        requiredCookies: ["sessionid"],
        onSuccess: (cookieStr) {
          DouyinAccountService.instance.setLoginCookie(cookieStr);
          SmartDialog.showToast("抖音登录成功");
        },
      ),
    );
  }

  void douyinMenu() {
    Utils.showBottomSheet(
      title: "抖音",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(DouyinAccountService.instance.logined.value
                ? "退出账号登录"
                : "账号登录（可发送弹幕）"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              if (DouyinAccountService.instance.logined.value) {
                douyinLoginTap();
              } else {
                douyinLogin();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text("自定义 ttwid"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doDouyinCookieConfig();
            },
          ),
        ],
      ),
    );
  }

  void twitchTap() async {
    if (TwitchAccountService.instance.configured.value) {
      var result = await Utils.showAlertDialog("确定要退出 Twitch 账号吗？", title: "退出登录");
      if (result) {
        TwitchAccountService.instance.logout();
        SmartDialog.showToast("已退出 Twitch 登录");
      }
    } else {
      // 已保存 Client ID：直接走官方授权页；否则引导首次配置
      if (!TwitchAccountService.instance.login()) {
        showTwitchConfigDialog();
      }
    }
  }

  void showTwitchConfigDialog() {
    var clientIdController = TextEditingController(
      text: TwitchAccountService.instance.clientId,
    );
    var tokenController = TextEditingController(
      text: TwitchAccountService.instance.oauthToken,
    );
    var loginController = TextEditingController(
      text: TwitchAccountService.instance.userLogin,
    );
    Get.dialog(
      AlertDialog(
        title: const Text("Twitch 接口配置（可选）"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "默认匿名模式可直接观看。发弹幕需要「用户令牌」：\n"
                "1. 推荐点下方「授权登录」：先在 dev.twitch.tv/console 注册应用，"
                "把 OAuth Redirect URLs 填为 http://localhost，再把 Client ID 填到下面；\n"
                "2. 也可手工粘贴用户令牌与登录名（如 twitchtokengenerator.com 生成）。\n"
                "注意：应用令牌（App Access Token）不能发弹幕。",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: clientIdController,
                decoration: const InputDecoration(
                  hintText: "Client ID（授权登录必填）",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: tokenController,
                maxLines: 2,
                decoration: const InputDecoration(
                  hintText: "OAuth User Access Token",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: loginController,
                decoration: const InputDecoration(
                  hintText: "Twitch 登录名（小写，发弹幕必填）",
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              var cid = clientIdController.text.trim();
              if (cid.isEmpty) {
                SmartDialog.showToast("请先填写 Client ID");
                return;
              }
              Get.back();
              TwitchAccountService.instance.startOAuth(clientId: cid);
            },
            child: const Text("授权登录"),
          ),
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
                userLogin: loginController.text.trim().toLowerCase(),
              );
              if (TwitchAccountService.instance.configured.value) {
                _validateTwitchConfig();
              } else if (TwitchAccountService.instance.clientId.isNotEmpty) {
                TwitchAccountService.instance.login();
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }

  void _validateTwitchConfig() async {
    try {
      var login = await TwitchAccountService.instance.validateCurrentConfig();
      SmartDialog.showToast("Twitch 配置有效，登录名：$login");
    } on CoreError catch (e) {
      var msg = e.statusCode == 400
          ? "该 Token 是应用令牌（App Access Token），无法发弹幕，请点「授权登录」获取用户令牌"
          : e.statusCode == 401
              ? "Client ID 与 Token 不匹配：请填写 Token 所属应用的 Client ID"
              : "Twitch Token 校验失败";
      Utils.showAlertDialog(msg, title: "Twitch 配置提示");
    } catch (_) {}
  }

  void doDouyinCookieConfig() {
    // 初始化文本框时，只显示 ttwid 的值部分
    var savedCookie = DouyinAccountService.instance.cookie;
    var displayText = savedCookie;
    if (savedCookie.startsWith('ttwid=')) {
      displayText = savedCookie.substring(6); // 去掉 "ttwid="
    }
    var controller = TextEditingController(text: displayText);

    Get.dialog(
      AlertDialog(
        title: const Text("配置抖音 ttwid"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "默认已内置有效的 ttwid，可观看所有画质（包括蓝光）。\n如有需要可自定义配置。",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: "请粘贴 ttwid 值（留空则使用默认值）",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () {
                  // 提取 ttwid 的值部分（去掉 "ttwid=" 前缀）
                  var defaultValue = DouyinSite.kDefaultCookie;
                  if (defaultValue.startsWith('ttwid=')) {
                    defaultValue = defaultValue.substring(6); // 去掉 "ttwid="
                  }
                  controller.text = defaultValue;
                },
                icon: const Icon(Icons.restore),
                label: const Text("恢复默认 ttwid"),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Get.back(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () {
              var input = controller.text.trim();
              Get.back();
              if (input.isEmpty) {
                DouyinAccountService.instance.clearCookie();
                SmartDialog.showToast("已清除自定义 Cookie，将使用默认 ttwid");
              } else {
                // 如果用户只输入了 ttwid 值，自动添加 "ttwid=" 前缀
                var cookie = input;
                if (!input.startsWith('ttwid=')) {
                  cookie = 'ttwid=$input';
                }
                DouyinAccountService.instance.setCookie(cookie);
                SmartDialog.showToast("ttwid 已保存");
              }
            },
            child: const Text("确定"),
          ),
        ],
      ),
    );
  }
}
