import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class TwitchAccountService extends GetxService {
  static TwitchAccountService get instance =>
      Get.find<TwitchAccountService>();

  var clientId = "";
  var oauthToken = "";
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
    configured.value = oauthToken.isNotEmpty;
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kTwitch]!.liveSite as TwitchSite);
    site.clientId = clientId.isEmpty ? TwitchSite.kWebClientId : clientId;
    site.oauthToken = oauthToken;
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
    configured.value = oauthToken.isNotEmpty;
    setSite();
  }

  void setConfig({String? clientId, String? oauthToken}) {
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
    configured.value = this.oauthToken.isNotEmpty;
    setSite();
  }

  void clearConfig() {
    clientId = "";
    oauthToken = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchClientId, "");
    LocalStorageService.instance
        .setValue(LocalStorageService.kTwitchToken, "");
    configured.value = false;
    setSite();
  }
}
