import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeGuard extends GuardServerService {
  int statusCalls = 0;
  int failLeft = 0;
  bool verifyRequired = true;
  bool throwFailure = true;
  final List<String> promptWebRids = [];

  DioException _error503() {
    final requestOptions = RequestOptions(path: '/api/room/status');
    return DioException(
      requestOptions: requestOptions,
      response: Response<dynamic>(
        requestOptions: requestOptions,
        statusCode: 503,
        data: {
          "code": 503,
          "message": "状态预热中",
          "data": {
            if (verifyRequired) "verifyRequired": true,
          },
        },
      ),
    );
  }

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async => null;

  @override
  Future<Map<String, dynamic>> getLiveStatus({
    String? accountId,
    String roomId = "",
    String webRid = "",
  }) async {
    statusCalls++;
    if (throwFailure && failLeft > 0) {
      failLeft--;
      throw _error503();
    }
    return {"living": false};
  }

  @override
  Future<void> syncDouyinWarmRooms(List<String> webRids) async {}
}

class _UnusedSite extends LiveSite {
  @override
  Future<bool> getLiveStatus({required String roomId}) async => false;
}

Future<void> _waitFor(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError("等待条件超时");
}

void main() {
  late Directory tmp;
  late _FakeGuard guard;
  late FollowService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp("sl_verify_test");
    Hive.init(tmp.path);
    void registerAdapter<T>(TypeAdapter<T> adapter) {
      if (!Hive.isAdapterRegistered(adapter.typeId)) {
        Hive.registerAdapter<T>(adapter);
      }
    }

    registerAdapter(FollowUserAdapter());
    registerAdapter(HistoryAdapter());
    registerAdapter(FollowUserTagAdapter());

    var localStorage = LocalStorageService();
    await localStorage.init();
    Get.put(localStorage);
    Get.put(AppSettingsController());

    var db = DBService();
    await db.init();
    Get.put(db);

    var originalDouyin = Sites.allSites[Constant.kDouyin]!;
    Sites.allSites[Constant.kDouyin] = Site(
      id: Constant.kDouyin,
      name: "抖音直播",
      logo: "",
      liveSite: _UnusedSite(),
    );
    addTearDown(() {
      Sites.allSites[Constant.kDouyin] = originalDouyin;
    });

    for (var i = 0; i < 2; i++) {
      var user = FollowUser(
        id: "${Constant.kDouyin}_u$i",
        roomId: "3000000000$i",
        siteId: Constant.kDouyin,
        userName: "主播$i",
        face: "",
        addTime: DateTime.now(),
      );
      await db.followBox.put(user.id, user);
    }

    guard = _FakeGuard();
    Get.put<GuardServerService>(guard);

    service = FollowService();
    service.douyinLaunchInterval = const Duration(milliseconds: 1);
    service.itemRetryDelay = const Duration(milliseconds: 60);
  });

  tearDown(() async {
    // 让所有在途/复核请求成功排空，避免悬空定时器
    guard.throwFailure = false;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    Get.reset();
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('撞游客风控：弹窗一次；完成验证后自动补刷一轮', () async {
    // 首轮两次失败（弹窗），验证完成后的补刷全部成功
    guard.failLeft = 2;
    service.verifyPromptCallback = (webRid) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard.promptWebRids.add(webRid);
      return true;
    };

    await service.loadData(manual: true);
    await _waitFor(() => guard.promptWebRids.length == 1);
    expect(guard.promptWebRids, ["30000000000"]);

    // 完成验证 → 补刷一轮两个房间成功
    await _waitFor(() => guard.statusCalls == 4);
    // 补刷成功不再弹窗
    expect(guard.promptWebRids, ["30000000000"]);

    var byId = {for (var u in service.followList) u.roomId: u};
    expect(byId["30000000000"]!.liveStatus.value, 1);
    expect(byId["30000000001"]!.liveStatus.value, 1);
  });

  test('普通预热503（无verifyRequired）不弹窗，后台复核成功', () async {
    guard.verifyRequired = false;
    guard.failLeft = 4; // 首轮2次 + 首轮复核2次失败，再次复核成功
    service.verifyPromptCallback = (webRid) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard.promptWebRids.add(webRid);
      return false;
    };

    await service.loadData(manual: true);
    await _waitFor(() => guard.statusCalls == 6);
    expect(guard.promptWebRids, isEmpty);
    expect(service.retryTimerCount, 0);
  });

  test('用户取消：本会话重试不再弹窗；切后台再回前台重新提示', () async {
    guard.failLeft = 100000;
    service.verifyPromptCallback = (webRid) async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      guard.promptWebRids.add(webRid);
      return false;
    };

    await service.loadData(manual: true);
    await _waitFor(() => guard.promptWebRids.length == 1);

    // 后台复核继续撞风控，但本会话不再弹窗
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(guard.promptWebRids, ["30000000000"]);

    // 切后台再回前台：补刷并重新提示一次
    service.onAppPaused();
    service.refreshDue = true;
    service.onAppResumed();
    await _waitFor(() => guard.promptWebRids.length == 2);
  });
}
