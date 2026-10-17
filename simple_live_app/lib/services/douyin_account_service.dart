import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance =>
      Get.find<DouyinAccountService>();

  /// 自定义 ttwid（设备标识，可选）
  var cookie = "";
  var hasCookie = false.obs;

  /// 账号登录完整 cookie
  var loginCookie = "";
  var logined = false.obs;
  var loginName = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    loginCookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginCookie, "");
    logined.value = loginCookie.contains("sessionid");
    loginName.value = logined.value ? "已登录" : "未登录";
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);
    // cookie 恒为设备 ttwid；登录 cookie 单独承载，打开房间默认不带登录身份
    site.cookie = cookie;
    site.loginCookie = logined.value ? loginCookie : "";
  }

  /// 打开真实 WebView 登录页（live.douyin.com），滑块安全验证与登录都在该页完成
  void startWebLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "抖音账号登录",
        startUrl: "https://live.douyin.com",
        cookieUrl: "https://live.douyin.com",
        userAgent: WebLoginArgs.desktopUserAgent,
        requiredCookies: const ["sessionid"],
        onSuccess: (cookieStr) {
          setLoginCookie(cookieStr);
          SmartDialog.showToast("抖音登录成功");
        },
      ),
    );
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = false;
    setSite();
  }

  void setLoginCookie(String cookie) {
    loginCookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, cookie);
    logined.value = cookie.contains("sessionid");
    loginName.value = logined.value ? "已登录" : "未登录";
    setSite();
    _registerGuardAccount();
  }

  void _registerGuardAccount() {
    final cookie = loginCookie;
    if (cookie.trim().isEmpty) return;
    final guard = GuardServerService.instance;
    if (!guard.configured) return;
    guard.registerAccount("douyin", cookie).then((accountId) {
      LocalStorageService.instance.setValue(
        "${LocalStorageService.kGuardAccountIdPrefix}douyin",
        accountId,
      );
    }).catchError((e) {
      Log.logPrint("注册弹幕签名服务失败: $e");
    });
  }

  /// 子窗口借用主窗口登录身份（M4-3 presence IPC）。
  ///
  /// 纯内存单点：只写 loginCookie 字段与 DouyinSite.loginCookie，不写 KV、
  /// 不翻转 logined/loginName/hasCookie、不触发 guard 账号注册。cookie 仅
  /// 在 pr_apply_enter 载荷里下行一次；yield/suspended/子窗关闭三个失效
  /// 点立即传 null 清除，进程退出即消失。必须绕过 setSite()——那里受
  /// logined 门控会把借用 cookie 立刻清空。
  void setBorrowedLoginCookie(String? cookie) {
    loginCookie = cookie ?? '';
    final site =
        Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    site.loginCookie = loginCookie;
  }

  void logout() async {
    final accountId = LocalStorageService.instance.getValue(
      "${LocalStorageService.kGuardAccountIdPrefix}douyin",
      "",
    );
    await LocalStorageService.instance.removeValue(
      "${LocalStorageService.kGuardAccountIdPrefix}douyin",
    );
    if (accountId.isNotEmpty && GuardServerService.instance.configured) {
      GuardServerService.instance
          .deleteAccount(accountId)
          .catchError((e) => Log.logPrint("删除签名服务会话失败: $e"));
    }
    loginCookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, "");
    logined.value = false;
    loginName.value = "未登录";
    setSite();
  }
}
