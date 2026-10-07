import 'dart:async';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show DouyinGuestVerifyRequired;
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
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 10), receiveTimeout: const Duration(seconds: 20)));
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

  /// 直播间互动动作：like 点赞、fans_badge 送粉丝团灯牌
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = "",
    required String action,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 30)));
    final res = await dio.post<dynamic>(
      "/api/action",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
        "action": action,
      },
      options: _options,
    );
    return Map<String, dynamic>.from(res.data["data"] as Map);
  }

  Future<void> deleteAccount(String accountId) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl));
    await dio.delete<dynamic>("/api/account/$accountId", options: _options);
  }

  /// 同步抖音关注房 webRid 清单给 guard，供其定时冷启动预热；未配置则忽略。
  Future<void> syncDouyinWarmRooms(List<String> webRids) async {
    if (!configured) return;
    try {
      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 10),
      ));
      await dio.post<dynamic>(
        "/api/warm/rooms",
        data: {"webRids": webRids},
        options: _options,
      );
    } catch (e) {
      Log.logPrint("同步预热房间清单失败: $e");
    }
  }

  /// 立即触发一轮后台预热（不等待完成）
  Future<void> triggerWarm() async {
    if (!configured) return;
    try {
      final dio = Dio(BaseOptions(
        baseUrl: serverUrl,
        connectTimeout: const Duration(seconds: 10),
      ));
      await dio.post<dynamic>("/api/warm/run", options: _options);
    } catch (e) {
      Log.logPrint("触发预热失败: $e");
    }
  }

  /// 进入直播间；返回房间状态：joined 已加入粉丝团、starGuard 星守护房间
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = "",
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 30),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/enter",
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

  /// 粉丝团每日任务：勋章等级/亲密度 + 当日任务完成情况
  Future<Map<String, dynamic>> getDailyTasks({
    required String accountId,
    required String roomId,
    String webRid = "",
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/tasks",
      data: {
        "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
      },
      options: _options,
    );
    return Map<String, dynamic>.from(res.data["data"] as Map);
  }

  /// 直播状态被动查询：服务端缓存 room_id，不进场、无副作用。
  /// accountId 为空走游客匿名；服务端对拉黑房自动游客复核
  Future<Map<String, dynamic>> getLiveStatus({
    String? accountId,
    String roomId = "",
    String webRid = "",
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/status",
      data: {
        if (accountId != null) "accountId": accountId,
        "roomId": roomId,
        "webRid": webRid,
      },
      options: _options,
    );
    return Map<String, dynamic>.from(res.data["data"] as Map);
  }

  /// 取房间 SSR HTML（供 DouyinSite.htmlFetcher）。accountId 为空走游客匿名；
  /// 非空时服务端对「账号被该房拉黑」自动降级匿名 HTML
  Future<String> fetchRoomHtml({
    required String webRid,
    String? accountId,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/html",
      data: {
        "webRid": webRid,
        if (accountId != null) "accountId": accountId,
      },
      options: _options,
    );
    final body = Map<String, dynamic>.from(res.data as Map);
    if (body["code"] == 4031) {
      final data =
          body["data"] is Map ? Map<String, dynamic>.from(body["data"] as Map)
              : null;
      throw DouyinGuestVerifyRequired(
        data?["webRid"]?.toString() ?? webRid,
      );
    }
    final data = Map<String, dynamic>.from(body["data"] as Map);
    if (data["guest"] == true) {
      Log.logPrint("抖音账号被该房拉黑，已以游客观看 webRid=$webRid");
    }
    return data["html"].toString();
  }

  /// 抖音账号视角取 SSR HTML：本地 accountId 在服务端已失效（404）时，
  /// 重新注册一次再取；与 enterRoom 的 404 自愈保持一致，避免会话丢失后
  /// 账号详情这步先失败、根本走不到进场
  Future<String> fetchDouyinAccountHtml({required String webRid}) async {
    var accountId = await ensureAccount("douyin");
    try {
      return await fetchRoomHtml(webRid: webRid, accountId: accountId);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      final newId = await reregister("douyin");
      if (newId == null) rethrow;
      accountId = newId;
      return fetchRoomHtml(webRid: webRid, accountId: accountId);
    }
  }

  Future<void> saveRoomTrust({
    required String webRid,
    required String cookies,
    required String ua,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
    ));
    final res = await dio.post<dynamic>(
      "/api/room/trust",
      data: {"webRid": webRid, "cookies": cookies, "ua": ua},
      options: _options,
    );
    final body = Map<String, dynamic>.from(res.data as Map);
    if (body["code"] != 0) {
      throw Exception(body["message"]?.toString() ?? "保存验证信息失败");
    }
  }

  Future<Map<String, dynamic>> heartbeat({    required String accountId,
    required String roomId,
    String webRid = "",
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 20),
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
      receiveTimeout: const Duration(seconds: 20),
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
