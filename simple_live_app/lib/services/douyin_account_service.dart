import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
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

  /// 登录页自动填充用的账号密码
  var loginAccount = "";
  var loginPassword = "";

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    loginCookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginCookie, "");
    loginAccount = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginAccount, "");
    loginPassword = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginPassword, "");
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
  Future<void> startWebLogin() async {
    await Get.toNamed(
      RoutePath.kWebLogin,
      arguments: buildWebLoginArgs(),
    );
  }

  /// 单独抽出以便单测：抖音登录页参数（密码登录 tab + 凭据自动填充）
  WebLoginArgs buildWebLoginArgs() {
    return WebLoginArgs(
      title: "抖音账号登录",
      startUrl: "https://live.douyin.com",
      cookieUrl: "https://live.douyin.com",
      userAgent: WebLoginArgs.desktopUserAgent,
      requiredCookies: const ["sessionid"],
      credential: LoginCredential(
        account: loginAccount,
        password: loginPassword,
        onSave: saveCredential,
        onClear: clearCredential,
        accountHint: "手机号",
        // 桌面 UA 默认停在扫码登录，填充脚本据此先点「密码登录」tab
        passwordTabText: "密码登录",
        injectHost: "live.douyin.com",
        // 手机号/密码两个输入框 id 同名（normal-input），靠 type 区分
        accountSelector: 'input#normal-input[type="tel"]',
        passwordSelector: 'input#normal-input[type="password"]',
      ),
      onSuccess: (cookieStr) {
        setLoginCookie(cookieStr);
        SmartDialog.showToast("抖音登录成功");
        cloudPushDouyin();
      },
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

  void saveCredential(String account, String password) {
    loginAccount = account;
    loginPassword = password;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginAccount, account);
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginPassword, password);
  }

  void clearCredential() {
    loginAccount = "";
    loginPassword = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginAccount, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginPassword, "");
  }

  /// 同步自其他设备/云端的登录凭据；null 表示对端无此数据，不覆盖本地，
  /// 空串表示对端已取消记住，需清空
  void setSyncedCredential(String? account, String? password) {
    if (account != null) {
      loginAccount = account;
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyinLoginAccount, account);
    }
    if (password != null) {
      loginPassword = password;
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyinLoginPassword, password);
    }
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

  final SyncClientRequest _cloudRequest = SyncClientRequest();

  /// 云端拉取冷却：本地未登录且云端无数据时避免每次进房都请求
  DateTime? _lastCloudPullTime;
  static const Duration _cloudPullCooldown = Duration(minutes: 5);

  /// 登录成功后自动把抖音登录 cookie/账号/密码同步到云端；未配置云端或失败均静默
  Future<void> cloudPushDouyin() async {
    final userName = AppSettingsController.instance.userName.value;
    final syncUrl = AppSettingsController.instance.syncUrl.value;
    if (userName.isEmpty || syncUrl.isEmpty) return;
    try {
      final params = {
        "userName": userName,
        "dataInfo": {
          "douyinData": loginCookie,
          "douyinAccount": loginAccount,
          "douyinPassword": loginPassword,
        },
      };
      await _cloudRequest.updateDouyin(json.encode(params), syncUrl);
    } catch (e) {
      Log.logPrint("抖音登录信息自动同步失败: $e");
    }
  }

  /// 本地未登录（重装/清数据/从未登录）时尝试从云端恢复一次登录态与凭据。
  /// 本地已有登录态不动。
  Future<bool> cloudPullDouyinIfAbsent() async {
    if (logined.value) return false;
    final data = await _fetchCloudDouyin();
    if (data == null) return false;
    if (!applyCloudLoginData(data, requireDifferent: false)) return false;
    SmartDialog.showToast("抖音登录态已从云端同步");
    return true;
  }

  /// 发弹幕被服务端判登录态失效（20003）后，先拉云端最新 cookie 尝试无感恢复：
  /// 云端须有有效 sessionid 且与本地不是同一份（同一份说明云端也已失效）。
  /// 真正是否仍有效由调用方重发一次验证；失败则引导重新登录。
  Future<bool> cloudRefreshDouyinIfExpired() async {
    final data = await _fetchCloudDouyin();
    if (data == null) return false;
    if (!applyCloudLoginData(data, requireDifferent: true)) return false;
    SmartDialog.showToast("抖音登录态已从云端同步");
    return true;
  }

  /// 读云端抖音登录信息；未配置/冷却中/失败返回 null
  Future<Map<String, dynamic>?> _fetchCloudDouyin() async {
    final now = DateTime.now();
    if (_lastCloudPullTime != null &&
        now.difference(_lastCloudPullTime!) < _cloudPullCooldown) {
      return null;
    }
    final userName = AppSettingsController.instance.userName.value;
    final syncUrl = AppSettingsController.instance.syncUrl.value;
    if (userName.isEmpty || syncUrl.isEmpty) return null;
    _lastCloudPullTime = now;
    try {
      return await _cloudRequest.getDouyinData(userName, syncUrl);
    } catch (e) {
      Log.logPrint("抖音登录信息云端拉取失败: $e");
      return null;
    }
  }

  /// 应用云端抖音登录数据，返回是否采用。
  /// cookie 须含 sessionid；[requireDifferent] 为 true 时还须与本地不同
  /// （失效恢复场景，同一份意味着云端也已过期）。
  @visibleForTesting
  bool applyCloudLoginData(
    Map<String, dynamic> data, {
    required bool requireDifferent,
  }) {
    final cloudCookie = (data["douyinData"] ?? "").toString();
    if (!cloudCookie.contains("sessionid")) return false;
    if (requireDifferent && cloudCookie == loginCookie) return false;
    setLoginCookie(cloudCookie);
    final account = data["douyinAccount"];
    final password = data["douyinPassword"];
    if (account != null || password != null) {
      setSyncedCredential(account?.toString(), password?.toString());
    }
    return true;
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
