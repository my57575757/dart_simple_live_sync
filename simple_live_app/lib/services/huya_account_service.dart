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
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class HuyaAccountService extends GetxService {
  static HuyaAccountService get instance =>
      Get.find<HuyaAccountService>();

  var logined = false.obs;
  var cookie = "";
  var name = "未登录".obs;

  /// 登录页自动填充用的账号密码
  var loginAccount = "";
  var loginPassword = "";

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
    loginAccount = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaLoginAccount, "");
    loginPassword = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaLoginPassword, "");
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

  /// 子窗口借用主窗口登录身份（presence IPC）。
  ///
  /// 纯内存单点：只写 cookie 并经 setSite() 同步 site（getRoomDetail 构造
  /// HuyaDanmakuArgs 读 site.cookie），不写 KV、不翻转 logined/name、不注册
  /// guard 账号。yield/suspended/子窗关闭/刷新等失效点由 coordinator 传
  /// null 清除，进程退出即消失。
  void setBorrowedLoginCookie(String? cookie) {
    this.cookie = cookie ?? '';
    setSite();
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

  void saveCredential(String account, String password) {
    loginAccount = account;
    loginPassword = password;
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaLoginAccount, account);
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaLoginPassword, password);
  }

  void clearCredential() {
    loginAccount = "";
    loginPassword = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaLoginAccount, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaLoginPassword, "");
  }

  Future<void> startWebLogin() async {
    await Get.toNamed(
      RoutePath.kWebLogin,
      arguments: buildWebLoginArgs(),
    );
  }

  /// 单独抽出以便单测：构造虎牙登录页参数（壳页握手 + 凭据自动填充）
  WebLoginArgs buildWebLoginArgs() {
    return WebLoginArgs(
      title: "虎牙账号登录",
      // 虎牙登录表单是 aq.huya.com 的嵌入式壳页：直接打开时等待父页
      // postMessage 握手才渲染，故以顶层页打开并由 _huyaLoginBootstrap
      // 模拟宿主握手；登录成功后壳页发 _loginSuccess，脚本跳回主站，
      // onLoadStop 据此在 www.huya.com 集齐 udb_biztoken
      startUrl: "https://aq.huya.com/p/udb_login.html",
      cookieUrl: "https://www.huya.com",
      userAgent: WebLoginArgs.desktopUserAgent,
      requiredCookies: ["udb_biztoken"],
      // 与斗鱼同理：表单登录 POST→302 顶层跳转走 CDP Fetch 会闪退
      useShouldOverrideUrlLoading: false,
      credential: LoginCredential(
        account: loginAccount,
        password: loginPassword,
        onSave: saveCredential,
        onClear: clearCredential,
        accountHint: "手机号 / 虎牙号",
        passwordTabText: "",
        injectHost: "aq.huya.com",
        accountSelector: "#username",
        passwordSelector: "#password",
        bootstrapScript: _huyaLoginBootstrap,
      ),
      onSuccess: _onLoginSuccess,
    );
  }

  void _onLoginSuccess(String cookieStr) {
    cookie = cookieStr;
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, cookieStr);
    logined.value = true;
    name.value = _uid;
    setSite();
    _registerGuardAccount();
    SmartDialog.showToast("虎牙登录成功");
    cloudPushHuya();
  }

  final SyncClientRequest _cloudRequest = SyncClientRequest();

  /// 云端拉取冷却：本地未登录且云端无数据时避免每次进房都请求
  DateTime? _lastCloudPullTime;
  static const Duration _cloudPullCooldown = Duration(minutes: 5);

  /// 登录成功后自动把虎牙 cookie/账号/密码同步到云端；未配置云端或失败均静默
  Future<void> cloudPushHuya() async {
    final userName = AppSettingsController.instance.userName.value;
    final syncUrl = AppSettingsController.instance.syncUrl.value;
    if (userName.isEmpty || syncUrl.isEmpty) return;
    try {
      final params = {
        "userName": userName,
        "dataInfo": {
          "huyaData": cookie,
          "huyaAccount": loginAccount,
          "huyaPassword": loginPassword,
        },
      };
      await _cloudRequest.updateHuya(json.encode(params), syncUrl);
    } catch (e) {
      Log.logPrint("虎牙登录信息自动同步失败: $e");
    }
  }

  /// 本地未登录（重装/清数据/从未登录）时尝试从云端恢复一次登录态与凭据。
  /// 本地已有登录态不动；虎牙无 JWT 之类的本地过期信号，不做"过期续命"
  Future<bool> cloudPullHuyaIfAbsent() async {
    if (logined.value) return false;
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
      final data = await _cloudRequest.getHuyaData(userName, syncUrl);
      final cloudCookie = (data["huyaData"] ?? "").toString();
      if (!cloudCookie.contains("udb_biztoken")) return false;
      setSyncedCookie(cloudCookie);
      final account = data["huyaAccount"];
      final password = data["huyaPassword"];
      if (account != null || password != null) {
        setSyncedCredential(account?.toString(), password?.toString());
      }
      SmartDialog.showToast("虎牙登录态已从云端同步");
      return true;
    } catch (e) {
      Log.logPrint("虎牙登录信息云端拉取失败: $e");
      return false;
    }
  }

  /// 同步自其他设备/云端的登录凭据；null 表示对端无此数据，不覆盖本地，
  /// 空串表示对端已取消记住，需清空
  void setSyncedCredential(String? account, String? password) {
    if (account != null) {
      loginAccount = account;
      LocalStorageService.instance
          .setValue(LocalStorageService.kHuyaLoginAccount, account);
    }
    if (password != null) {
      loginPassword = password;
      LocalStorageService.instance
          .setValue(LocalStorageService.kHuyaLoginPassword, password);
    }
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

/// 虎牙 udb_login 壳页引导：页面以顶层打开时不渲染登录表单，需模拟宿主
/// postMessage 握手触发 SDK init；登录成功后壳页回发 _loginSuccess，
/// 随即跳回主站，交由 onLoadStop 检查 udb_biztoken。随填充轮询重复执行，
/// 以 __huyaLoginBoot 标志保证只握手一次。
const String _huyaLoginBootstrap = r'''
(function(){
  if(window.__huyaLoginBoot) return;
  window.__huyaLoginBoot = 1;
  window.addEventListener('message', function(ev){
    try { var m = JSON.parse(ev.data); } catch (e) { return; }
    if (m && (m.fnName === '_loginSuccess' || m.fnName === '_loginAuthSuccess')) {
      location.href = 'https://www.huya.com/';
    }
  });
  window.postMessage(JSON.stringify({origin:'udbSdkWeb', opt:{appid:'5002'}, fnName:'login'}), '*');
})();
''';
