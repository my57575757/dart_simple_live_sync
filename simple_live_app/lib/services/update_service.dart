import 'dart:io';

import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:url_launcher/url_launcher_string.dart';

class UpdateService extends GetxService {
  static UpdateService get instance => Get.find<UpdateService>();

  static const String _versionUrl =
      "http://remote.zhixiongshouci.top:1379/live_coer_by_me_version.json";

  /// 启动后检查更新，网络异常等情况静默忽略
  Future<void> checkUpdate() async {
    if (!Platform.isAndroid && !Platform.isWindows) {
      return;
    }
    try {
      var info = await HttpClient.instance.getJson(_versionUrl);
      var remoteBuild = int.tryParse(info["version_num"].toString()) ?? 0;
      var localBuild = int.tryParse(Utils.packageInfo.buildNumber) ?? 0;
      if (remoteBuild <= localBuild) {
        return;
      }
      var downloadUrl = Platform.isAndroid
          ? info["download_url_apk"].toString()
          : info["download_url_windows"].toString();
      var confirmed = await Utils.showAlertDialog(
        info["version_desc"].toString(),
        title: "发现新版本 v${info["version"]}",
        confirm: "立即更新",
        cancel: "稍后",
      );
      if (confirmed) {
        await launchUrlString(downloadUrl,
            mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      Log.d("检查更新失败: $e");
    }
  }
}
