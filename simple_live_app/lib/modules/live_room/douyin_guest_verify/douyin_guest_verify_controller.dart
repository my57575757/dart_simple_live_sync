import 'dart:convert';
import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

class DouyinGuestVerifyController extends GetxController {
  late final String webRid;
  InAppWebViewController? webController;

  final ready = false.obs;
  final submitting = false.obs;

  WebViewEnvironment? environment;
  List<Cookie> savedCookies = [];
  bool usedClearFallback = false;
  bool finished = false;
  bool canceled = false;

  WebUri get roomUrl => WebUri("https://live.douyin.com/$webRid");

  @override
  void onInit() {
    super.onInit();
    webRid = Get.arguments.toString();
  }

  Future<void> setupIsolation() async {
    if (Platform.isWindows) {
      try {
        final support = await getApplicationSupportDirectory();
        final folder =
            "${support.path}${Platform.pathSeparator}guest_verify_env";
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: folder),
        );
        return;
      } catch (e) {
        Log.logPrint("Windows 独立环境创建失败，改走清 cookie：$e");
        environment = null;
      }
    }
    await clearCookies();
  }

  Future<void> clearCookies() async {
    usedClearFallback = true;
    final cm = CookieManager.instance();
    savedCookies = await cm.getCookies(url: roomUrl);
    // host-only cookie：删除指令不带 Domain
    await cm.deleteCookies(url: roomUrl);
    // Domain=.douyin.com 的域 cookie
    await cm.deleteCookies(url: roomUrl, domain: ".douyin.com");
  }

  InAppWebViewSettings buildSettings() => InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        javaScriptEnabled: true,
      );

  void onWebViewCreated(InAppWebViewController c) {
    webController = c;
  }

  Future<bool> checkVerified() async {
    try {
      final c = webController;
      if (c == null) return false;
      final result = await c.evaluateJavascript(
        source:
            'JSON.stringify({title: document.title, hasVideo: !!document.querySelector("video"), path: location.pathname})',
      );
      if (result == null) return false;
      final info = json.decode(result.toString()) as Map<String, dynamic>;
      return info["title"] != "验证码中间页" &&
          info["path"] == "/$webRid" &&
          info["hasVideo"] == true;
    } catch (e) {
      Log.logPrint("验证完成检测失败：$e");
      return false;
    }
  }

  void onLoadStop(InAppWebViewController c, Uri? uri) async {
    final verified = await checkVerified();
    if (verified && !ready.value) {
      ready.value = true;
      await Future.delayed(const Duration(seconds: 1));
      if (ready.value && !submitting.value && !finished) {
        await submit();
      }
    }
  }

  Future<void> manualSubmit() async {
    if (submitting.value) return;
    final verified = await checkVerified();
    if (!verified && !ready.value) {
      SmartDialog.showToast("请先完成页面验证");
      return;
    }
    await submit();
  }

  static bool isAccountCookieName(String name) => [
        "sessionid",
        "sid_",
        "ssid_",
        "uid_",
        "passport_",
        "sso_",
        "toutiao_sso",
      ].any(name.startsWith);

  Future<void> submit() async {
    final c = webController;
    if (c == null || submitting.value) return;
    submitting.value = true;
    try {
      final cm = CookieManager.instance(webViewEnvironment: environment);
      final cookies = await cm.getCookies(url: roomUrl);
      final cookieStr = cookies
          .where((item) => !isAccountCookieName(item.name))
          .map((item) => "${item.name}=${item.value}")
          .join("; ");
      final ua = await InAppWebViewController.getDefaultUserAgent();
      await GuardServerService.instance.saveRoomTrust(
        webRid: webRid,
        cookies: cookieStr,
        ua: ua,
      );
      if (canceled) {
        Log.logPrint("验证信息已保存但页面已取消，不再退窗");
        return;
      }
      finished = true;
      await restore();
      Get.back(result: true);
    } catch (e) {
      submitting.value = false;
      Log.logPrint("提交游客验证失败：$e");
      SmartDialog.showToast("提交失败，请点「完成验证」重试");
    }
  }

  Future<void> cancel() async {
    canceled = true;
    finished = true;
    await restore();
    Get.back(result: false);
  }

  Future<void> restore() async {
    if (environment != null) {
      await environment!.dispose().catchError((_) {});
      environment = null;
      return;
    }
    if (usedClearFallback) {
      final cm = CookieManager.instance();
      for (final item in savedCookies) {
        try {
          await cm.setCookie(
            url: roomUrl,
            name: item.name,
            value: item.value,
            path: item.path ?? "/",
            domain: item.domain,
          );
        } catch (e) {
          Log.logPrint("恢复 cookie 失败(${item.name})：$e");
        }
      }
    }
  }
}
