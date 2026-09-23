import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class GuardServerService extends GetxService {
  static GuardServerService get instance => Get.find<GuardServerService>();

  String serverUrl = "";
  String token = "";

  @override
  void onInit() {
    serverUrl = LocalStorageService.instance
        .getValue(LocalStorageService.kGuardServerUrl, "");
    token = LocalStorageService.instance
        .getValue(LocalStorageService.kGuardServerToken, "");
    super.onInit();
  }

  bool get configured => serverUrl.trim().isNotEmpty;

  Future<void> setConfig(String url, String token) async {
    serverUrl = url.trim();
    this.token = token.trim();
    await LocalStorageService.instance
        .setValue(LocalStorageService.kGuardServerUrl, serverUrl);
    await LocalStorageService.instance
        .setValue(LocalStorageService.kGuardServerToken, this.token);
  }

  Options get _options => Options(headers: {"Authorization": "Bearer $token"});

  Future<String> registerAccount(String platform, String cookie) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 10)));
    final res = await dio.post<dynamic>(
      "/api/account",
      data: {"platform": platform, "cookie": cookie},
      options: _options,
    );
    return res.data["data"]["accountId"].toString();
  }

  Future<String> getStatus(String accountId) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 10)));
    final res = await dio.get<dynamic>(
      "/api/account/$accountId",
      options: _options,
    );
    return res.data["data"]["status"].toString();
  }

  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = "",
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 30)));
    final res = await dio.post<dynamic>(
      "/api/send",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
        "content": content,
        "extra": extra ?? {},
      },
      options: _options,
    );
    return Map<String, dynamic>.from(res.data["data"] as Map);
  }

  Future<void> deleteAccount(String accountId) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl));
    await dio.delete<dynamic>("/api/account/$accountId", options: _options);
  }
}
