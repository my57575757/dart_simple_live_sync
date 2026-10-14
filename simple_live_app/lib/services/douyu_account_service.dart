import 'dart:convert';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/requests/sync_client_request.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance =>
      Get.find<DouyuAccountService>();

  var logined = false.obs;
  var cookie = "";
  var name = "未登录".obs;

  /// 登录页自动填充用的账号密码
  var loginAccount = "";
  var loginPassword = "";

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    logined.value = cookie.contains("acf_stk") && cookie.contains("acf_uid");
    name.value = logined.value ? _uid : "未登录";
    loginAccount = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuLoginAccount, "");
    loginPassword = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuLoginPassword, "");
    setSite();
    super.onInit();
  }

  String get _uid {
    var m = RegExp(r"acf_uid=([^;]+)").firstMatch(cookie);
    return m != null ? "UID: ${m.group(1)}" : "已登录";
  }

  void setSite() {
    var site = Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite;
    site.cookie = cookie;
  }

  Future<void> startWebLogin() async {
    await Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "斗鱼账号登录",
        // 直接打开 passport 登录页：登录表单在跨域 iframe 中无法注入，
        // 顶层页可被 JS 自动填充账号密码；登录成功后 .douyu.com 域 cookie 写入，
        // 页面跳回 state(www.douyu.com) 时集齐 acf_uid/acf_stk
        startUrl:
            "https://passport.douyu.com/index/login?passport_reg_callback=PASSPORT_REG_SUCCESS_CALLBACK&passport_login_callback=PASSPORT_LOGIN_SUCCESS_CALLBACK&passport_close_callback=PASSPORT_CLOSE_CALLBACK&type=login&client_id=1&state=https%3A%2F%2Fwww.douyu.com%2F&source=click_topnavi_login",
        cookieUrl: "https://www.douyu.com",
        requiredCookies: ["acf_uid", "acf_stk"],
        // passport 表单登录成功是 POST→302 跨域顶层跳转，Windows 端 CDP Fetch
        // 拦截会闪退；关闭后由 onLoadStop 查 cookie 判定登录成功
        useShouldOverrideUrlLoading: false,
        credential: LoginCredential(
          account: loginAccount,
          password: loginPassword,
          onSave: saveCredential,
          onClear: clearCredential,
        ),
        onSuccess: (cookieStr) {
          cookie = cookieStr;
          LocalStorageService.instance
              .setValue(LocalStorageService.kDouyuCookie, cookieStr);
          logined.value = true;
          name.value = _uid;
          setSite();
          SmartDialog.showToast("斗鱼登录成功");
          cloudPushDouyu();
        },
      ),
    );
  }

  void saveCredential(String account, String password) {
    loginAccount = account;
    loginPassword = password;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuLoginAccount, account);
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuLoginPassword, password);
  }

  void clearCredential() {
    loginAccount = "";
    loginPassword = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuLoginAccount, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuLoginPassword, "");
  }

  void logout() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, "");
    logined.value = false;
    name.value = "未登录";
    setSite();
  }

  /// 同步自其他设备/云端的 cookie
  void setSyncedCookie(String cookieStr) {
    cookie = cookieStr;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, cookieStr);
    logined.value = cookieStr.contains("acf_stk") && cookieStr.contains("acf_uid");
    name.value = logined.value ? _uid : "未登录";
    setSite();
  }

  /// 同步自其他设备/云端的登录凭据；null 表示对端无此数据，不覆盖本地
  void setSyncedCredential(String? account, String? password) {
    if (account != null) {
      loginAccount = account;
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyuLoginAccount, account);
    }
    if (password != null) {
      loginPassword = password;
      LocalStorageService.instance
          .setValue(LocalStorageService.kDouyuLoginPassword, password);
    }
  }

  final SyncClientRequest _cloudRequest = SyncClientRequest();

  /// 云端续命拉取冷却：本地已过期且云端也无新数据时，避免每次进房都请求
  DateTime? _lastCloudPullTime;
  static const Duration _cloudPullCooldown = Duration(minutes: 5);

  /// 登录成功后自动把斗鱼 cookie/账号/密码同步到云端；未配置云端或失败均静默
  Future<void> cloudPushDouyu() async {
    final userName = AppSettingsController.instance.userName.value;
    final syncUrl = AppSettingsController.instance.syncUrl.value;
    if (userName.isEmpty || syncUrl.isEmpty) return;
    try {
      final params = {
        "userName": userName,
        "dataInfo": {
          "douyuData": cookie,
          "douyuAccount": loginAccount,
          "douyuPassword": loginPassword,
        },
      };
      await _cloudRequest.updateDouyu(json.encode(params), syncUrl);
    } catch (e) {
      Log.logPrint("斗鱼登录信息自动同步失败: $e");
    }
  }

  /// 本地登录态是否已过期：以 acf_dmjwt_token 的 JWT exp 为准；
  /// cookie 中无该字段或无法解析 exp 时保守返回 false，交由服务端拒绝后走手动重登
  bool isLoginExpired() {
    if (!logined.value) return false;
    final jwt = DouyuDanmaku.cookieValue(cookie, "acf_dmjwt_token");
    if (jwt.isEmpty) return false;
    final exp = DouyuDanmaku.jwtExpirySec(jwt);
    if (exp == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp <= nowSec;
  }

  /// 进入斗鱼直播间前调用：本地登录态过期时从云端拉取最新斗鱼信息覆盖。
  /// 返回 true 表示已用云端有效 cookie 更新本地
  Future<bool> cloudRefreshDouyuIfExpired() async {
    if (!isLoginExpired()) return false;
    final now = DateTime.now();
    if (_lastCloudPullTime != null &&
        now.difference(_lastCloudPullTime!) < _cloudPullCooldown) {
      return false;
    }
    final userName = AppSettingsController.instance.userName.value;
    final syncUrl = AppSettingsController.instance.syncUrl.value;
    if (userName.isEmpty || syncUrl.isEmpty) return false;
    _lastCloudPullTime = now;
    try {
      final data = await _cloudRequest.getDouyuData(userName, syncUrl);
      final cloudCookie = (data["douyuData"] ?? "").toString();
      if (!_isCookieLoginValid(cloudCookie)) return false;
      setSyncedCookie(cloudCookie);
      final account = data["douyuAccount"];
      final password = data["douyuPassword"];
      if (account != null || password != null) {
        setSyncedCredential(account?.toString(), password?.toString());
      }
      SmartDialog.showToast("斗鱼登录态已从云端同步");
      return true;
    } catch (e) {
      Log.logPrint("斗鱼登录信息云端拉取失败: $e");
      return false;
    }
  }

  /// cookie 是否带未过期的登录态（acf_uid/acf_stk 齐全且 JWT 未过期）
  bool _isCookieLoginValid(String cookieStr) {
    if (!cookieStr.contains("acf_stk") || !cookieStr.contains("acf_uid")) {
      return false;
    }
    final jwt = DouyuDanmaku.cookieValue(cookieStr, "acf_dmjwt_token");
    if (jwt.isEmpty) return false;
    final exp = DouyuDanmaku.jwtExpirySec(jwt);
    if (exp == null) return false;
    final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return exp > nowSec;
  }
}
