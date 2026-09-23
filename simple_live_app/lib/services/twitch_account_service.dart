import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class TwitchAccountService extends GetxService {
  static TwitchAccountService get instance =>
      Get.find<TwitchAccountService>();

  var clientId = "";
  var oauthToken = "";
  var userLogin = "";
  var configured = false.obs;

  @override
  void onInit() {
    clientId = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchClientId,
      "",
    );
    oauthToken = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchToken,
      "",
    );
    userLogin = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchUserLogin,
      "",
    );
    configured.value = oauthToken.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kTwitch]!.liveSite as TwitchSite);
    site.clientId = clientId.isEmpty ? TwitchSite.kWebClientId : clientId;
    site.oauthToken = oauthToken;
    site.userLogin = userLogin;
  }

  void reload() {
    clientId = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchClientId,
      "",
    );
    oauthToken = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchToken,
      "",
    );
    userLogin = LocalStorageService.instance.getValue(
      LocalStorageService.kTwitchUserLogin,
      "",
    );
    configured.value = oauthToken.isNotEmpty;
    setSite();
  }

  void setConfig({String? clientId, String? oauthToken, String? userLogin}) {
    if (clientId != null) {
      this.clientId = clientId;
      LocalStorageService.instance.setValue(
        LocalStorageService.kTwitchClientId,
        clientId,
      );
    }
    if (oauthToken != null) {
      this.oauthToken = oauthToken;
      LocalStorageService.instance.setValue(
        LocalStorageService.kTwitchToken,
        oauthToken,
      );
    }
    if (userLogin != null) {
      this.userLogin = userLogin;
      LocalStorageService.instance.setValue(
        LocalStorageService.kTwitchUserLogin,
        userLogin,
      );
    }
    configured.value = this.oauthToken.isNotEmpty;
    setSite();
  }

  void clearConfig() {
    clientId = "";
    oauthToken = "";
    userLogin = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchClientId, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchToken, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchUserLogin, "");
    configured.value = false;
    setSite();
  }

  /// OAuth 重定向地址；用户需在 Twitch 开发者后台把它加入
  /// 应用的 OAuth Redirect URLs
  static const String kOAuthRedirectUri = "http://localhost";

  /// 走官方 OAuth Implicit Flow 获取用户令牌：
  /// WebView 打开授权页，重定向回 localhost 时从 fragment 提取 token
  void startOAuth({required String clientId}) {
    setConfig(clientId: clientId);
    var authUrl = Uri.https("id.twitch.tv", "/oauth2/authorize", {
      "client_id": clientId,
      "redirect_uri": kOAuthRedirectUri,
      "response_type": "token",
      "scope": "chat:read chat:edit",
    }).toString();
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "Twitch 授权登录",
        startUrl: authUrl,
        cookieUrl: "",
        requiredCookies: [],
        redirectMatch: kOAuthRedirectUri,
        fragmentKey: "access_token",
        onSuccess: (token) {
          setConfig(oauthToken: token);
          validateCurrentConfig().then((login) {
            SmartDialog.showToast("Twitch 登录成功：$login");
          }).catchError((_) {
            SmartDialog.showToast("Token 已保存，请补填登录名");
          });
        },
      ),
    );
  }

  /// 用当前配置反查登录名；成功且本地未填登录名时自动补全
  Future<String> validateCurrentConfig() async {
    setSite();
    var site =
        (Sites.allSites[Constant.kTwitch]!.liveSite as TwitchSite);
    var login = await site.validateAndResolveLogin();
    if (userLogin.isEmpty) {
      setConfig(userLogin: login);
    }
    return login;
  }
}
