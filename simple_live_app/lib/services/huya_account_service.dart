import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class HuyaAccountService extends GetxService {
  static HuyaAccountService get instance =>
      Get.find<HuyaAccountService>();

  var logined = false.obs;
  var cookie = "";
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
    logined.value = cookie.contains("udb_biztoken");
    name.value = logined.value ? _uid : "未登录";
    setSite();
    super.onInit();
  }

  String get _uid {
    var m = RegExp(r"(?:yyuid|udb_uid)=([^;]+)").firstMatch(cookie);
    return m != null ? "UID: ${m.group(1)}" : "已登录";
  }

  void setSite() {
    var site = Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite;
    site.cookie = cookie;
  }

  void startWebLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "虎牙账号登录",
        startUrl: "https://www.huya.com",
        cookieUrl: "https://www.huya.com",
        requiredCookies: ["udb_biztoken"],
        onSuccess: (cookieStr) {
          cookie = cookieStr;
          LocalStorageService.instance
              .setValue(LocalStorageService.kHuyaCookie, cookieStr);
          logined.value = true;
          name.value = _uid;
          setSite();
          SmartDialog.showToast("虎牙登录成功");
        },
      ),
    );
  }

  void logout() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, "");
    logined.value = false;
    name.value = "未登录";
    setSite();
  }

  /// 同步自其他设备/云端的 cookie
  void setSyncedCookie(String cookieStr) {
    cookie = cookieStr;
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, cookieStr);
    logined.value = cookieStr.contains("udb_biztoken");
    name.value = logined.value ? _uid : "未登录";
    setSite();
  }
}
