import 'dart:async';
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
  // 页面空白（WebView2 渲染层白屏 / 文档未加载完）：驱动自动重载与覆盖层出口
  final blank = false.obs;

  WebViewEnvironment? environment;
  List<Cookie> savedCookies = [];
  bool usedClearFallback = false;
  bool finished = false;
  bool canceled = false;

  int _reloadCount = 0;
  Timer? _watchdog;

  static const int _maxAutoReloads = 2;

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
    // 清 cookie 兜底在资源紧张/残留进程时同样可能无限挂起；必须限时，
    // 超时也继续展示页面，否则 prepared 永不为 true、验证页只剩转圈
    await clearCookies().timeout(const Duration(seconds: 10), onTimeout: () {
      Log.logPrint("清 cookie 整体超时，直接展示验证页");
    });
  }

  Future<void> clearCookies() async {
    usedClearFallback = true;
    final cm = CookieManager.instance();
    try {
      savedCookies = await cm
          .getCookies(url: roomUrl)
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      Log.logPrint("读取待清理 cookie 失败/超时：$e");
      savedCookies = [];
    }
    try {
      // host-only cookie：删除指令不带 Domain
      await cm
          .deleteCookies(url: roomUrl)
          .timeout(const Duration(seconds: 4));
      // Domain=.douyin.com 的域 cookie
      await cm
          .deleteCookies(url: roomUrl, domain: ".douyin.com")
          .timeout(const Duration(seconds: 4));
    } catch (e) {
      Log.logPrint("删除 cookie 失败/超时：$e");
    }
  }

  InAppWebViewSettings buildSettings() => InAppWebViewSettings(
        mediaPlaybackRequiresUserGesture: false,
        javaScriptEnabled: true,
        userAgent: desktopUserAgent,
        preferredContentMode: UserPreferredContentMode.DESKTOP,
      );

  void onWebViewCreated(InAppWebViewController c) {
    webController = c;
    _armWatchdog();
  }

  /// onLoadStop 永不触发（WebView2 永久转圈/白屏）时的兜底出口
  void _armWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer(const Duration(seconds: 15), () {
      if (finished || canceled || ready.value) return;
      Log.logPrint("游客验证页加载看门狗超时，展示重载出口");
      blank.value = true;
    });
  }

  @override
  void onClose() {
    _watchdog?.cancel();
    super.onClose();
  }

  /// 页面探针：只报原始字段，判定全部在 Dart 侧（便于单测）。
  /// 只采集通用信号：readyState、title、path、验证码控件。不能采集「正文
  /// 长度」判白屏——抖音滑动验证码是 canvas 渲染，innerText 极短是验证页的
  /// 正常形态，正文长短无法与真白屏区分，会误伤验证页。
  static const String probeScript = r'''
(function(){
  try {
    var body = document.body;
    return JSON.stringify({
      ready: document.readyState,
      title: document.title,
      path: location.pathname,
      hasCaptcha: !!document.querySelector(".secsdk-captcha-drag-icon,[class*=captcha],[id*=captcha]") ||
        /请完成验证|滑动验证|点击按钮完成验证/.test((body && body.innerText) || "")
    });
  } catch (e) { return null; }
})()
''';

  Future<Map<String, dynamic>?> probePageInfo() async {
    try {
      final c = webController;
      if (c == null) return null;
      // 必须限时：WebView2 异常时 evaluateJavascript 可能永不返回，
      // 不加超时「完成验证」按钮会表现为彻底无响应
      final result = await c
          .evaluateJavascript(source: probeScript)
          .timeout(const Duration(seconds: 5));
      return decodeProbe(result?.toString());
    } catch (e) {
      Log.logPrint("验证完成检测失败：$e");
      return null;
    }
  }

  @visibleForTesting
  static Map<String, dynamic>? decodeProbe(String? result) {
    if (result == null) return null;
    try {
      final decoded = json.decode(result);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// 白屏判定：仅看文档是否真的加载完（readyState=complete）。不再用正文长度——
  /// canvas 验证码页正文极短是正常形态，正文长短区分不了验证页与白屏。
  @visibleForTesting
  static bool isBlankPage(Map<String, dynamic> info) {
    return info["ready"] != "complete";
  }

  /// 验证完成判据：路径落在目标房间、不是验证码中间页、验证码控件消失、
  /// 且文档加载完成。只认通用信号，不要求 video / 房间节点 / 正文长度——
  /// 未开播房间与 canvas 验证码页都会因这些附加条件被误判。
  @visibleForTesting
  static bool isVerified(Map<String, dynamic> info, String webRid) {
    return info["path"] == "/$webRid" &&
        info["title"] != "验证码中间页" &&
        info["hasCaptcha"] != true &&
        info["ready"] == "complete";
  }

  static bool parseVerified(String? result, String webRid) {
    final info = decodeProbe(result);
    return info != null && isVerified(info, webRid);
  }

  /// 手动点「完成验证」的放行判据：只排除仍明确停在验证码中间页的情况。
  /// 开播/未开播/极简空页等渲染形态差异不在客户端猜测——用户主动点击意图
  /// 明确，放行后由服务端落库前实测判定（不通过返回明确原因），保证按钮
  /// 始终有响应而不是被客户端判据静默挡住。
  @visibleForTesting
  static bool canManualSubmit(Map<String, dynamic> info, String webRid) {
    return info["path"] == "/$webRid" &&
        info["title"] != "验证码中间页" &&
        info["hasCaptcha"] != true;
  }

  void onLoadStop(InAppWebViewController c, Uri? uri) async {
    _armWatchdog();
    final info = await probePageInfo();
    if (info == null || finished || canceled) return;
    if (isVerified(info, webRid)) {
      if (ready.value) return;
      blank.value = false;
      ready.value = true;
      await Future.delayed(const Duration(seconds: 1));
      if (ready.value && !submitting.value && !finished) {
        await submit();
      }
      return;
    }
    // 白屏：先自动重载（WebView2 渲染层白屏 reload 通常即恢复），
    // 次数用尽后保留覆盖层，由用户手动重载
    if (isBlankPage(info)) {
      if (_reloadCount < _maxAutoReloads) {
        _reloadCount++;
        blank.value = true;
        Log.logPrint(
            "游客验证页空白，自动重载 $_reloadCount/$_maxAutoReloads");
        await Future.delayed(const Duration(milliseconds: 1500));
        if (canceled || finished) return;
        await webController?.reload();
        return;
      }
      blank.value = true;
    } else {
      blank.value = false;
    }
  }

  /// 覆盖层/右上角按钮的手动重载：重置自动重载计数再给两轮机会
  Future<void> manualReload() async {
    _reloadCount = 0;
    blank.value = false;
    _armWatchdog();
    await webController?.reload();
  }

  Future<void> manualSubmit() async {
    if (submitting.value) return;
    final info = await probePageInfo();
    if (info != null && !canManualSubmit(info, webRid)) {
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
      _watchdog?.cancel();
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
      final raw = e.toString();
      final msg =
          raw.startsWith("Exception: ") ? raw.substring(11) : raw;
      // 服务端实测拒绝（cookie 残缺/撞验证页）时直接展示其原因，
      // 其余异常回退通用提示
      SmartDialog.showToast(
        msg.contains("验证") ? msg : "提交失败，请点「完成验证」重试",
      );
    }
  }

  Future<void> cancel() async {
    canceled = true;
    finished = true;
    _watchdog?.cancel();
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
