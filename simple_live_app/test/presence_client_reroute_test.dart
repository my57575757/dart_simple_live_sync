import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeDanmaku extends LiveDanmaku {
  @override
  Future<void> start(dynamic args) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<DanmakuSendResult> sendMessage(String message) async =>
      DanmakuSendResult(success: true);
}

class _Site extends DouyinSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();
  @override
  LiveDanmaku getDanmaku() => danmaku;
  LiveRoomDetail guestDetail() => LiveRoomDetail(
        roomId: '111',
        title: 't',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 1,
        status: true,
        url: 'https://live.douyin.com/111',
        danmakuData: DouyinDanmakuArgs(
          webRid: '111',
          roomId: 'room_111',
          userId: 'uid',
          cookie: 'ttwid=guest',
        ),
      );
  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async =>
      guestDetail();
}

class _Guard extends GuardServerService {
  int taskQueries = 0;
  Map<String, dynamic> taskResult = const {
    'level': 1,
    'intimacy': 292,
    'nextIntimacy': 420,
    'medalName': '牌',
    'tasks': [
      {
        'title': '点亮粉丝团恢复勋章',
        'progress': '0/1',
        'reward': '',
        'done': false,
      },
    ],
  };
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  bool get configured => false;
  @override
  Future<String?> ensureAccount(String platform) async => 'acc1';
  @override
  Future<Map<String, dynamic>> getDailyTasks({
    required String accountId,
    required String roomId,
    String webRid = '',
  }) async {
    taskQueries++;
    return Map<String, dynamic>.from(taskResult);
  }
}

class _Account extends DouyinAccountService {
  final _logined = true.obs;
  int refreshCalls = 0;
  bool refreshResult = true;
  @override
  RxBool get logined => _logined;
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  Future<bool> cloudRefreshDouyinIfExpired() async {
    refreshCalls++;
    return refreshResult;
  }
}

class _FakeClient implements PresenceClient {
  int claims = 0;
  int danmakuSends = 0;
  int actionSends = 0;
  bool firstSendNotHolder = true;
  bool firstActionNotHolder = true;
  // 首次动作先回 20003（模拟网关判登录态失效），之后成功
  bool actionExpireOnce = false;
  @override
  bool isClaimed = true;
  @override
  Future<PresenceClaimResult> claim() async {
    claims++;
    return const PresenceClaimResult.granted();
  }
  @override
  Future<PresenceSendResult> sendDanmaku(String content) async {
    danmakuSends++;
    if (firstSendNotHolder) {
      firstSendNotHolder = false;
      return PresenceSendResult.notHolder;
    }
    return const PresenceSendResult(success: true);
  }
  @override
  Future<PresenceSendResult> sendAction(String action) async {
    actionSends++;
    if (actionExpireOnce) {
      actionExpireOnce = false;
      return const PresenceSendResult(
        success: false,
        code: '20003',
        message: '请登录后进入直播间',
      );
    }
    if (firstActionNotHolder) {
      firstActionNotHolder = false;
      return PresenceSendResult.notHolder;
    }
    return const PresenceSendResult(success: true);
  }
  @override
  Future<void> release() async {}
  @override
  Future<void> detach() async {}
}

void main() {
  tearDown(() => Get.reset());

  testWidgets('抖音发送遇 not_holder：强制回 guest → 重新 claim → 重发一次',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<GuardServerService>(_Guard());
    Get.put<DouyinAccountService>(_Account());

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();
    final client = _FakeClient();
    c.debugBindPresenceClient(client);

    await c.sendDanmaku('hello');
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 首次 ensure（进入）claim 一次；not_holder 后强制回 guest 重进再 claim 一次
    expect(client.claims, 2);
    expect(client.danmakuSends, 2, reason: 'not_holder 后只重发一次');
    expect(c.presence.value, RoomPresence.account);
  });

  testWidgets('抖音点赞遇 not_holder：强制回 guest → 重新 claim → 重发一次',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<GuardServerService>(_Guard());
    Get.put<DouyinAccountService>(_Account());

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();
    final client = _FakeClient();
    c.debugBindPresenceClient(client);

    await c.like();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 首次 ensure（进入）claim 一次；not_holder 后强制回 guest 重进再 claim 一次
    expect(client.claims, 2);
    expect(client.actionSends, 2, reason: 'not_holder 后只重发一次');
    expect(c.presence.value, RoomPresence.account);
  });

  testWidgets('抖音点赞遇 20003：云端刷新成功 + 强制重进后重发一次，不弹重登',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<GuardServerService>(_Guard());
    final account = _Account();
    Get.put<DouyinAccountService>(account);

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();
    final client = _FakeClient()
      ..actionExpireOnce = true
      ..firstActionNotHolder = false;
    c.debugBindPresenceClient(client);

    await c.like();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(account.refreshCalls, 1, reason: '只拉一次云端 cookie');
    expect(client.actionSends, 2, reason: '恢复后只重发一次');
    expect(client.claims, 2, reason: '强制重进重新 claim');
    expect(c.presence.value, RoomPresence.account);
    expect(find.text('抖音登录态已过期，是否重新登录？'), findsNothing,
        reason: '恢复成功不引导重登');
  });

  testWidgets('每日任务独立查看：游客态未入团也能查，不 claim 不进场不发动作',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final guard = _Guard();
    Get.put<GuardServerService>(guard);
    Get.put<DouyinAccountService>(_Account());

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();
    final client = _FakeClient();
    c.debugBindPresenceClient(client);

    expect(c.guardJoined.value, false);
    expect(c.presence.value, RoomPresence.guest);

    unawaited(c.showDailyTasks());
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(guard.taskQueries, 1, reason: '只查一次任务');
    expect(find.text('每日任务'), findsOneWidget, reason: '任务面板直接展示');
    expect(find.text('点亮粉丝团恢复勋章'), findsOneWidget);
    expect(client.claims, 0, reason: '查任务不 claim holder');
    expect(client.actionSends, 0, reason: '查任务不发写动作');
    expect(c.presence.value, RoomPresence.guest, reason: '查任务不改变观看身份');

    // 只读面板只有关闭，没有送灯牌主动作
    expect(find.text('送出灯牌'), findsNothing);
    expect(find.text('送出星光'), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pump();
  });

  testWidgets('未入端点加入粉丝团：只弹入团确认，不查任务', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final guard = _Guard();
    Get.put<GuardServerService>(guard);
    Get.put<DouyinAccountService>(_Account());

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();

    unawaited(c.joinFansClub());
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    expect(find.text('加入粉丝团'), findsWidgets, reason: '弹入团确认框');
    expect(guard.taskQueries, 0, reason: '入团路径不再耦合任务查询');

    await tester.tap(find.text('取消'));
    await tester.pump();
  });
}
