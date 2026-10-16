import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeDanmaku extends LiveDanmaku {
  int starts = 0;
  int stops = 0;
  final cookies = <String?>[];

  @override
  Future<void> start(dynamic args) async {
    starts++;
    if (args is DouyinDanmakuArgs) {
      cookies.add(args.cookie);
    }
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    return DanmakuSendResult(success: true);
  }
}

class FakeDouyinSite extends DouyinSite {
  FakeDouyinSite(this._webRid, this._roomId, this.danmaku);
  final String _webRid;
  final String _roomId;
  final FakeDanmaku danmaku;

  String get webRidPlaceholder => _webRid;

  LiveRoomDetail buildDetail({required bool asAccount}) {
    return LiveRoomDetail(
      roomId: _webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$_webRid',
      danmakuData: DouyinDanmakuArgs(
        webRid: _webRid,
        roomId: _roomId,
        userId: 'uid',
        cookie: asAccount ? 'sessionid=abc' : 'ttwid=guest',
      ),
    );
  }

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async {
    return buildDetail(asAccount: asAccount);
  }
}

class FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<String?> reregister(String platform) async => 'acct1';

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    enters.add(roomId);
    return {'joined': false, 'starGuard': false};
  }

  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    return {'inRoom': true};
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add(roomId);
  }
}

class FakeDouyinAccount extends DouyinAccountService {
  final _logined = true.obs;

  @override
  RxBool get logined => _logined;

  @override
  // ignore: must_call_super
  void onInit() {}
}

LiveRoomController makeController({
  required String tabId,
  required FakeDouyinSite site,
  required DouyinPresenceGateway gateway,
}) {
  final c = LiveRoomController(
    pSite: Site(id: 'douyin', name: '抖音', logo: '', liveSite: site),
    pRoomId: site.webRidPlaceholder,
    pShareUrl: 'https://live.douyin.com/${site.webRidPlaceholder}',
    tabId: tabId,
  );
  c.detail.value = site.buildDetail(asAccount: false);
  c.bindPresenceGateway(gateway);
  return c;
}

void main() {
  late FakeDouyinSite siteA;
  late FakeDouyinSite siteB;
  late FakeGuard guard;

  setUp(() {
    siteA = FakeDouyinSite('111', 'room_111', FakeDanmaku());
    siteB = FakeDouyinSite('222', 'room_222', FakeDanmaku());
    guard = FakeGuard();
  });

  tearDown(() async {
    Get.reset();
  });

  testWidgets('A 进入后 B 进入：A 被让位为游客弹幕，B 账号持有；关闭 B 后 A 自动接管',
      (tester) async {
    // 网关必须在 testWidgets 体内创建：_serialized 的串行链起源于构造时所在
    // zone，setUp（FakeAsync 外）创建会导致体内 await claim 永不完成
    final gateway = DouyinPresenceGateway(guard);

    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<DouyinAccountService>(FakeDouyinAccount());

    final a = makeController(tabId: 'tabA', site: siteA, gateway: gateway);
    final b = makeController(tabId: 'tabB', site: siteB, gateway: gateway);

    // A 显式进入
    var ok = await a.enterAsAccount();
    await tester.pump();
    expect(ok, isTrue);
    expect(a.presence.value, RoomPresence.account);
    expect(guard.enters, ['room_111']);
    expect(siteA.danmaku.cookies.last, 'sessionid=abc');

    // B 显式进入 → A 让位
    ok = await b.enterAsAccount();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(ok, isTrue);
    expect(b.presence.value, RoomPresence.account);
    expect(a.presence.value, RoomPresence.guest);
    expect(guard.enters, ['room_111', 'room_222']);
    expect(guard.exits, isEmpty, reason: '让位不发 exit');
    expect(siteA.danmaku.cookies.last, 'ttwid=guest',
        reason: 'A 重连游客弹幕');

    // 关闭 holder B → A 自动回退接管
    await gateway.release('tabB');
    expect(guard.exits, ['room_222']);
    expect(gateway.holderTabId, 'tabA');
    expect(a.presence.value, RoomPresence.account);
    expect(siteA.danmaku.cookies.last, 'sessionid=abc');

    // 唯一心跳由网关维护；body 结束前取消，避免残留 periodic Timer
    gateway.stopHeartbeatForTesting();
  });

  testWidgets('guard 未配置：claim 失败，控制器回 guest 并 toast', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<DouyinAccountService>(FakeDouyinAccount());
    final unconfigured = _UnconfiguredGuard();
    final gw2 = DouyinPresenceGateway(unconfigured);
    addTearDown(gw2.dispose);
    final c = makeController(tabId: 'tabC', site: siteA, gateway: gw2);

    final ok = await c.enterAsAccount();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    // toast 2s 展示 + 200ms dismiss 收尾：连续短步泵完定时器链
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(ok, isFalse);
    expect(c.presence.value, RoomPresence.guest);
    expect(unconfigured.enters, isEmpty);

    // 失败路径无心跳；显式取消以备实现变化，避免残留 periodic Timer
    gw2.stopHeartbeatForTesting();
  });
}

class _UnconfiguredGuard extends FakeGuard {
  @override
  bool get configured => false;
}
