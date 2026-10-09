import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

class DouyinGuestVerifyController extends GetxController {
  // 验证 webview 固定用桌面 UA：移动端默认 UA 会被抖音识别为手机、下发移动版
  // 验证页；guard 本身是桌面 Chrome，桌面页验证得到的设备令牌也与其一致。
  static const String desktopUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36";

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
        // Windows 平台线程上 create 偶发无限挂起（残留进程/资源压力时），
        // 必须有超时：否则验证页永久转圈且无任何出口
        environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(userDataFolder: folder),
        ).timeout(const Duration(seconds: 10));
        if (canceled) {
          await environment?.dispose().catchError((_) {});
          environment = null;
          return;
        }
        return;
      } catch (e) {
        Log.logPrint("Windows 独立环境创建失败/超时，改走清 cookie：$e");
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
        userAgent: desktopUserAgent,
        preferredContentMode: UserPreferredContentMode.DESKTOP,
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
            'JSON.stringify({title: document.title, path: location.pathname, hasVideo: !!document.querySelector("video"), hasCaptcha: !!document.querySelector(".secsdk-captcha-drag-icon, [class*=captcha], [id*=captcha]") || /请完成验证|滑动验证|点击按钮完成验证/.test(document.body.innerText || "")})',
      );
      return parseVerified(result?.toString(), webRid);
    } catch (e) {
      Log.logPrint("验证完成检测失败：$e");
      return false;
    }
  }

  /// 验证完成判据：不在验证码中间页、路径正确且无验证码控件。
  /// 不能要求有 video——未开播房间验证通过后本就没有视频。
  @visibleForTesting
  static bool parseVerified(String? result, String webRid) {
    if (result == null) return false;
    final info = json.decode(result) as Map<String, dynamic>;
    return info["title"] != "验证码中间页" &&
        info["path"] == "/$webRid" &&
        info["hasCaptcha"] != true;
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
      // Windows 插件未实现静态 getDefaultUserAgent；直接取当前 webview 的
      // UA，保证与所提交 cookie 的隔离环境一致
      final uaRaw = await c.evaluateJavascript(
        source: "JSON.stringify(navigator.userAgent)",
      );
      final ua = uaRaw == null ? "" : json.decode(uaRaw.toString());
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
