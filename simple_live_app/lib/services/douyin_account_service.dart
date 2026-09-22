import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
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
    site.cookie = logined.value ? loginCookie : cookie;
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
  }

  void logout() {
    loginCookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, "");
    logined.value = false;
    loginName.value = "未登录";
    setSite();
  }
}
