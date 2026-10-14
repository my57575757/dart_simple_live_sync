import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
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
}
