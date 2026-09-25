import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
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
    unawaited(rehydrate());
  }

  static const _platformCookieKeys = {
    "douyin": LocalStorageService.kDouyinLoginCookie,
    "bilibili": LocalStorageService.kBilibiliCookie,
    "huya": LocalStorageService.kHuyaCookie,
  };

  String _accountIdKey(String platform) =>
      "${LocalStorageService.kGuardAccountIdPrefix}$platform";

  /// 发送前确保平台账号已在服务端注册。本地无 accountId 时用保存的
  /// cookie 自动注册；返回 null 表示未配置/未登录，调用方走直连。
  Future<String?> ensureAccount(String platform) async {
    if (!configured) return null;
    final saved = LocalStorageService.instance.getValue(
      _accountIdKey(platform),
      "",
    );
    if (saved.isNotEmpty) return saved;
    return reregister(platform);
  }

  /// 用本地保存的 cookie 重新注册并落库新的 accountId
  Future<String?> reregister(String platform) async {
    final cookieKey = _platformCookieKeys[platform];
    if (cookieKey == null) return null;
    final cookie = LocalStorageService.instance.getValue(cookieKey, "");
    if (cookie.trim().isEmpty) return null;
    final accountId = await registerAccount(platform, cookie);
    await LocalStorageService.instance.setValue(
      _accountIdKey(platform),
      accountId,
    );
    return accountId;
  }

  /// 服务重启/首次配置后用本地 cookie 自愈式重新注册，恢复 accountId
  Future<void> rehydrate() async {
    if (!configured) return;
    for (final entry in _platformCookieKeys.entries) {
      final cookie = LocalStorageService.instance.getValue(entry.value, "");
      if (cookie.trim().isEmpty) continue;
      try {
        final accountId = await registerAccount(entry.key, cookie);
        await LocalStorageService.instance.setValue(
          "${LocalStorageService.kGuardAccountIdPrefix}${entry.key}",
          accountId,
        );
      } catch (e) {
        Log.logPrint("重新注册弹幕签名服务失败(${entry.key}): $e");
      }
    }
  }

  String? savedAccountId(String platform) {
    final saved = LocalStorageService.instance.getValue(
      _accountIdKey(platform),
      "",
    );
    return saved.isEmpty ? null : saved;
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

  Future<void> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = "",
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 30),
    ));
    await dio.post<dynamic>(
      "/api/room/enter",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
        "extra": extra ?? {},
      },
      options: _options,
    );
  }

  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = "",
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/heartbeat",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
        "extra": extra ?? {},
      },
      options: _options,
    );
    return Map<String, dynamic>.from(res.data["data"] as Map);
  }

  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = "",
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
    ));
    await dio.post<dynamic>(
      "/api/room/exit",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
        "extra": extra ?? {},
      },
      options: _options,
    );
  }
}