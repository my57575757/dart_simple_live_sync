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

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    logined.value = cookie.contains("acf_stk") && cookie.contains("acf_uid");
    name.value = logined.value ? _uid : "未登录";
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

  void startWebLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "斗鱼账号登录",
        startUrl: "https://www.douyu.com",
        cookieUrl: "https://www.douyu.com",
        requiredCookies: ["acf_uid", "acf_stk"],
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
}
