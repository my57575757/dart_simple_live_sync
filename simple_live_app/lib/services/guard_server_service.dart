import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart'
    show DanmakuSendResult, DouyinGuestVerifyRequired, DouyinLoginRequired, DouyinRiskControl;
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

  /// /api/send、/api/action 等待响应上限：冷启动进房正常约 10s，服务端更久无响应即判失败
  @visibleForTesting
  Duration requestReceiveTimeout = const Duration(seconds: 60);

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
  final Map<String, Future<String?>> _registerInFlight = {};

  Future<String?> ensureAccount(String platform) async {
    if (!configured) return null;
    final saved = LocalStorageService.instance.getValue(
      _accountIdKey(platform),
      "",
    );
    if (saved.isNotEmpty) return saved;
    return _registerShared(platform);
  }

  /// 用本地保存的 cookie 重新注册并落库新的 accountId
  Future<String?> reregister(String platform) {
    return _registerShared(platform);
  }

  /// 同平台并发注册共享一次请求，避免刷新时连发多个 /api/account
  Future<String?> _registerShared(String platform) async {
    final existing = _registerInFlight[platform];
    if (existing != null) return existing;
    final completer = Completer<String?>();
    _registerInFlight[platform] = completer.future;
    try {
      completer.complete(await _doRegister(platform));
    } catch (e, st) {
      completer.completeError(e, st);
    } finally {
      _registerInFlight.remove(platform);
    }
    return completer.future;
  }

  Future<String?> _doRegister(String platform) async {
    if (!configured) return null;
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

  /// guard HTTP 失败信封（502 {message,errorCode} 或网络层错误）映射为
  /// 发送结果。服务端 errorCode 加 guard_ 前缀，避免与平台业务码混淆；
  /// guard_not_login 由发送流程拦截并弹窗引导重新登录
  static DanmakuSendResult mapHttpError(DioException e) {
    final data = e.response?.data;
    final msg = data is Map ? data["message"] : null;
    final serverCode = data is Map ? data["errorCode"]?.toString() : null;
    return DanmakuSendResult(
      success: false,
      errorCode: (serverCode != null && serverCode.isNotEmpty)
          ? "guard_${serverCode.toLowerCase()}"
          : "guard",
      errorMessage: msg is String && msg.isNotEmpty ? msg : "网络请求失败",
    );
  }

  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = "",
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 30), receiveTimeout: requestReceiveTimeout));
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
    final dio = Dio(BaseOptions(baseUrl: serverUrl, connectTimeout: const Duration(seconds: 30), receiveTimeout: requestReceiveTimeout));
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

  /// 抖音直播搜索：在 guard 受信浏览器环境执行，绕过 verify_check 风控。
  /// 本地 accountId 在服务端失效（404）时重新注册一次再试，与
  /// fetchDouyinAccountHtml 的自愈保持一致
  Future<Map<String, dynamic>> searchDouyin({
    required String keyword,
    int page = 1,
  }) async {
    var accountId = await ensureAccount("douyin");
    if (accountId == null) throw DouyinLoginRequired();
    try {
      return await _postSearch(accountId, keyword, page);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      final newId = await reregister("douyin");
      if (newId == null) rethrow;
      return _postSearch(newId, keyword, page);
    }
  }

  Future<Map<String, dynamic>> _postSearch(
    String accountId,
    String keyword,
    int page,
  ) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
    final res = await dio.post<dynamic>(
      "/api/search",
      data: {"accountId": accountId, "keyword": keyword, "page": page},
      options: _options,
    );
    final body = Map<String, dynamic>.from(res.data as Map);
    if (body["code"] == 4032) {
      throw DouyinLoginRequired(
        body["message"]?.toString() ?? "请先登录抖音账号",
      );
    }
    if (body["code"] == 4033) {
      throw DouyinRiskControl(
        body["message"]?.toString() ?? "抖音风控校验，请稍后再试",
      );
    }
    if (body["code"] != 0) {
      throw Exception(body["message"]?.toString() ?? "抖音搜索失败");
    }
    return Map<String, dynamic>.from(body["data"] as Map);
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
    try {
      final res = await dio.post<dynamic>(
        "/api/room/trust",
        data: {"webRid": webRid, "cookies": cookies, "ua": ua},
        options: _options,
      );
      final body = Map<String, dynamic>.from(res.data as Map);
      if (body["code"] != 0) {
        throw Exception(body["message"]?.toString() ?? "保存验证信息失败");
      }
    } on DioException catch (e) {
      // 服务端落库前实测失败（400：cookie 残缺/仍撞验证页）：透传其原因，
      // 供验证页 toast 引导用户重新滑滑块
      final data = e.response?.data;
      final msg = data is Map ? data["message"]?.toString() : null;
      throw Exception(
        msg != null && msg.isNotEmpty ? msg : "保存验证信息失败",
      );
    }
  }

  // ===== 远程滑块验证会话（用户在 guard 自己的浏览器里滑，App 看截图回传轨迹）=====

  Future<DouyinVerifySession> startVerifySession(String webRid) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 10),
      // 真导航 + 等 DCL，guard 浏览器冷启动时给足
      receiveTimeout: const Duration(seconds: 60),
    ));
    final res = await dio.post<dynamic>(
      "/api/verify/session",
      data: {"webRid": webRid},
      options: _options,
    );
    final data = _unwrapVerifyEnvelope(res.data);
    return DouyinVerifySession.fromJson(data);
  }

  Future<DouyinVerifyStatus> verifySessionStatus(String sessionId) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final res = await dio.get<dynamic>(
      "/api/verify/session/${Uri.encodeComponent(sessionId)}/status",
      options: _options,
    );
    return DouyinVerifyStatus.fromJson(_unwrapVerifyEnvelope(res.data));
  }

  /// 拉一帧 JPEG。410=会话已结束（看 message/reason），503=画面暂不可用（可继续重试）
  Future<VerifyFrame> verifySessionFrame(String sessionId) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
      responseType: ResponseType.bytes,
    ));
    try {
      final res = await dio.get<List<int>>(
        "/api/verify/session/${Uri.encodeComponent(sessionId)}/frame",
        options: _options,
      );
      final headers = res.headers.map.map(
        (k, v) => MapEntry(k.toLowerCase(), v),
      );
      String firstHeader(String name) =>
          (headers[name]?.isNotEmpty ?? false) ? headers[name]!.first : "";
      return VerifyFrame(
        bytes: Uint8List.fromList(res.data ?? const <int>[]),
        seq: int.tryParse(firstHeader("x-frame-seq")) ?? 0,
        state: firstHeader("x-session-state"),
      );
    } on DioException catch (e) {
      throw VerifySessionHttpException(
        status: e.response?.statusCode ?? 0,
        message: _verifyErrorMessage(e.response?.data) ?? "画面获取失败",
      );
    }
  }

  Future<int> sendVerifyEvents(
    String sessionId,
    List<VerifyPointerEvent> events,
  ) async {
    if (events.isEmpty) return 0;
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 15),
    ));
    final res = await dio.post<dynamic>(
      "/api/verify/session/${Uri.encodeComponent(sessionId)}/events",
      data: {
        "events": events.map((e) => e.toJson()).toList(),
      },
      options: _options,
    );
    final data = _unwrapVerifyEnvelope(res.data);
    return (data["applied"] as num?)?.toInt() ?? 0;
  }

  Future<void> reloadVerifySession(String sessionId) =>
      _verifyPost(sessionId, "reload");

  Future<void> cancelVerifySession(String sessionId) =>
      _verifyPost(sessionId, "cancel");

  Future<void> _verifyPost(String sessionId, String action) async {
    final dio = Dio(BaseOptions(
      baseUrl: serverUrl,
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 20),
    ));
    try {
      final res = await dio.post<dynamic>(
        "/api/verify/session/${Uri.encodeComponent(sessionId)}/$action",
        options: _options,
      );
      _unwrapVerifyEnvelope(res.data);
    } on DioException catch (e) {
      // 410（会话已结束）对 cancel 无意义，对 reload 向上抛给 UI 提示
      throw Exception(_verifyErrorMessage(e.response?.data) ?? "操作失败");
    }
  }

  Map<String, dynamic> _unwrapVerifyEnvelope(dynamic body) {
    final map = body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};
    if (map["code"] != 0) {
      throw Exception(map["message"]?.toString() ?? "验证服务异常");
    }
    return Map<String, dynamic>.from(map["data"] as Map? ?? const {});
  }

  /// 二进制响应失败时，body 是 JSON 信封字节（也可能已被解码成字符串/Map）
  String? _verifyErrorMessage(dynamic body) {
    try {
      dynamic decoded = body;
      if (body is List<int>) {
        decoded = json.decode(utf8.decode(body));
      } else if (body is String) {
        decoded = json.decode(body);
      }
      if (decoded is Map && decoded["message"] != null) {
        return decoded["message"].toString();
      }
    } catch (_) {}
    return null;
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

/// POST /api/verify/session 返回：会话 id 与画面/节流参数
class DouyinVerifySession {
  final String sessionId;
  final String webRid;
  final bool adopted;
  final int ttlMs;
  final int viewWidth;
  final int viewHeight;
  final int minFrameMs;

  const DouyinVerifySession({
    required this.sessionId,
    required this.webRid,
    required this.adopted,
    required this.ttlMs,
    required this.viewWidth,
    required this.viewHeight,
    required this.minFrameMs,
  });

  factory DouyinVerifySession.fromJson(Map<String, dynamic> json) {
    final viewport = json["viewport"] is Map
        ? Map<String, dynamic>.from(json["viewport"] as Map)
        : const <String, dynamic>{};
    return DouyinVerifySession(
      sessionId: json["sessionId"]?.toString() ?? "",
      webRid: json["webRid"]?.toString() ?? "",
      adopted: json["adopted"] == true,
      ttlMs: (json["ttlMs"] as num?)?.toInt() ?? 300000,
      viewWidth: (viewport["width"] as num?)?.toInt() ?? 1280,
      viewHeight: (viewport["height"] as num?)?.toInt() ?? 800,
      minFrameMs: (json["minFrameMs"] as num?)?.toInt() ?? 150,
    );
  }
}

class DouyinVerifyStatus {
  /// starting / active / verifying / verified / closed
  final String state;

  /// loading / captcha / interactive
  final String phase;
  final String webRid;
  final String url;
  final String title;
  final int remainingMs;

  /// canceled / expired / browser_disconnected / page_crashed /
  /// load_failed / verify_rejected / self_check_busy
  final String reason;

  const DouyinVerifyStatus({
    required this.state,
    required this.phase,
    required this.webRid,
    required this.url,
    required this.title,
    required this.remainingMs,
    required this.reason,
  });

  bool get isVerified => state == "verified";
  bool get isClosed => state == "closed";
  bool get isVerifying => state == "verifying";

  factory DouyinVerifyStatus.fromJson(Map<String, dynamic> json) {
    return DouyinVerifyStatus(
      state: json["state"]?.toString() ?? "active",
      phase: json["phase"]?.toString() ?? "loading",
      webRid: json["webRid"]?.toString() ?? "",
      url: json["url"]?.toString() ?? "",
      title: json["title"]?.toString() ?? "",
      remainingMs: (json["remainingMs"] as num?)?.toInt() ?? 0,
      reason: json["reason"]?.toString() ?? "",
    );
  }
}

class VerifyFrame {
  final Uint8List bytes;
  final int seq;
  final String state;

  const VerifyFrame({
    required this.bytes,
    required this.seq,
    required this.state,
  });

  bool get isEmpty => bytes.isEmpty;
}

/// 帧请求失败：410 会话终态、503 画面暂不可用、0 网络错误
class VerifySessionHttpException implements Exception {
  final int status;
  final String message;

  VerifySessionHttpException({required this.status, required this.message});

  bool get isClosed => status == 410;
  bool get isBusy => status == 503;

  @override
  String toString() => message;
}

/// 转发给 guard 浏览器的单个指针事件。坐标系为 guard 视口像素
/// （1280x800），由控制器从本地显示坐标线性换算后填入。
class VerifyPointerEvent {
  /// down / up / move / wheel
  final String type;
  final double x;
  final double y;
  final double dx;
  final double dy;

  const VerifyPointerEvent(
    this.type, {
    required this.x,
    required this.y,
    this.dx = 0,
    this.dy = 0,
  });

  Map<String, dynamic> toJson() => {
        "type": type,
        "x": x,
        "y": y,
        if (type == "wheel") "dx": dx,
        if (type == "wheel") "dy": dy,
      };
}
