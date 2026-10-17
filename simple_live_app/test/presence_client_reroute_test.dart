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
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  bool get configured => false;
}

class _Account extends DouyinAccountService {
  final _logined = true.obs;
  @override
  RxBool get logined => _logined;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeClient implements PresenceClient {
  int claims = 0;
  int danmakuSends = 0;
  bool firstSendNotHolder = true;
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
  Future<PresenceSendResult> sendAction(String action) async =>
      const PresenceSendResult(success: true);
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
}
