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

  void _registerGuardAccount() {
    final cookie = this.cookie;
    if (cookie.trim().isEmpty) return;
    final guard = GuardServerService.instance;
    if (!guard.configured) return;
    guard.registerAccount("huya", cookie).then((accountId) {
      LocalStorageService.instance.setValue(
        "${LocalStorageService.kGuardAccountIdPrefix}huya",
        accountId,
      );
    }).catchError((e) {
      Log.logPrint("注册弹幕签名服务失败: $e");
    });
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
          _registerGuardAccount();
          SmartDialog.showToast("虎牙登录成功");
        },
      ),
    );
  }

  void logout() async {
    final accountId = LocalStorageService.instance.getValue(
      "${LocalStorageService.kGuardAccountIdPrefix}huya",
      "",
    );
    await LocalStorageService.instance.removeValue(
      "${LocalStorageService.kGuardAccountIdPrefix}huya",
    );
    if (accountId.isNotEmpty && GuardServerService.instance.configured) {
      GuardServerService.instance
          .deleteAccount(accountId)
          .catchError((e) => Log.logPrint("删除签名服务会话失败: $e"));
    }
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
    _registerGuardAccount();
  }
}
