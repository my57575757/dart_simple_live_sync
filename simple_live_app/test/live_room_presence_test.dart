import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeDanmaku extends LiveDanmaku {
  int starts = 0;
  int stops = 0;
  Object? lastArgs;
  final sends = <String>[];

  @override
  Future<void> start(dynamic args) async {
    starts++;
    lastArgs = args;
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    sends.add(message);
    return DanmakuSendResult(success: true);
  }
}

class FakeDouyinSite extends DouyinSite {
  final FakeDanmaku danmaku = FakeDanmaku();
  bool accountFailsOnDetail = false;
  final asAccountCalls = <bool>[];

  static const _webRid = '12345678901';
  static const _roomId = '7690343577918212890';

  LiveRoomDetail buildDetail({required bool asAccount}) {
    final args = DouyinDanmakuArgs(
      webRid: _webRid,
      roomId: _roomId,
      userId: '7691511956330530313',
      cookie: asAccount ? 'sessionid=abc' : 'ttwid=guest',
    );
    return LiveRoomDetail(
      roomId: _webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$_webRid',
      danmakuData: args,
    );
  }

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async {
    asAccountCalls.add(asAccount);
    if (asAccount && accountFailsOnDetail) {
      throw CoreError('无法以账号身份读取该房间');
    }
    return buildDetail(asAccount: asAccount);
  }
}

class FakeGuard extends GuardServerService {
  bool enterThrows = false;
  final enters = <String>[];
  final exits = <String>[];
  final sentDanmaku = <String>[];
  final sentActions = <String>[];

  final FakeDanmaku Function() danmakuAtEnter;

  FakeGuard(this.danmakuAtEnter);

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<String?> reregister(String platform) async => 'acct2';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    // 时序闸门：guard 真正进场前，游客弹幕不能被停
    if (danmakuAtEnter().stops != 0) {
      throw StateError('guard 进场成功前不得停游客弹幕');
    }
    enters.add(roomId);
    if (enterThrows) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/room/enter'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/room/enter'),
          statusCode: 500,
        ),
      );
    }
    return {'joined': false, 'starGuard': false};
  }

  @override
  Future<Map<String, dynamic>> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add(roomId);
    return {};
  }

  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    sentDanmaku.add(content);
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async {
    sentActions.add(action);
    return {'success': true};
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
}

class FakeDouyinAccount extends DouyinAccountService {
  final _logined = true.obs;

  @override
  RxBool get logined => _logined;

  @override
  // ignore: must_call_super
  void onInit() {}
}

late FakeDouyinSite fakeSite;
late FakeGuard fakeGuard;
late LiveRoomController controller;

/// 运行可能弹 SmartDialog 的动作：调用后先 pump 一帧让 loading 挂载，
/// 再等结果、pump 收尾（失败 toast 需推进到其自动消失）
Future<T> runAction<T>(
  WidgetTester tester,
  Future<T> Function() action, {
  Duration settle = const Duration(milliseconds: 250),
}) async {
  final future = action();
  await tester.pump();
  final result = await future;
  await tester.pump();
  await tester.pump(settle);
  // toast/loading 退场是定时器链，每步触发的回调可能再挂新定时器，连续短步走完
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  controller.stopGuardHeartbeatForTesting();
  return result;
}

Future<void> bootstrap(WidgetTester tester) async {
  fakeSite = FakeDouyinSite();
  final site = Site(
    id: 'douyin',
    name: '抖音',
    logo: '',
    liveSite: fakeSite,
  );
  fakeGuard = FakeGuard(() => fakeSite.danmaku);
  controller = LiveRoomController(
    pSite: site,
    pRoomId: '12345678901',
    pShareUrl: 'https://live.douyin.com/12345678901',
  );
  controller.detail.value = fakeSite.buildDetail(asAccount: false);

  await tester.pumpWidget(
    GetMaterialApp(
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: const Scaffold(body: SizedBox()),
    ),
  );
  Get.put<GuardServerService>(fakeGuard);
  Get.put<DouyinAccountService>(FakeDouyinAccount());
}

void main() {
  tearDown(() async {
    controller.stopGuardHeartbeatForTesting();
    Get.reset();
  });

  testWidgets('成功流：guest→entering→account，进场后才停游客弹幕并按账号重连', (
    tester,
  ) async {
    await bootstrap(tester);

    final ok = await runAction<bool>(
      tester,
      controller.enterAsAccount,
    );

    expect(ok, isTrue);
    expect(controller.presence.value, RoomPresence.account);
    expect(fakeSite.asAccountCalls, equals([true]));
    expect(fakeGuard.enters, equals(['7690343577918212890']));
    expect(fakeSite.danmaku.stops, 1);
    expect(fakeSite.danmaku.starts, 1);
    final args = fakeSite.danmaku.lastArgs as DouyinDanmakuArgs;
    expect(args.cookie, 'sessionid=abc');
    expect(controller.messages, isNotEmpty);
  });

  testWidgets('账号详情失败：回 guest，弹幕未停、guard 未进场', (tester) async {
    await bootstrap(tester);
    fakeSite.accountFailsOnDetail = true;

    final ok = await runAction<bool>(
      tester,
      controller.enterAsAccount,
      settle: const Duration(milliseconds: 2100),
    );

    expect(ok, isFalse);
    expect(controller.presence.value, RoomPresence.guest);
    expect(fakeSite.danmaku.stops, 0);
    expect(fakeSite.danmaku.starts, 0);
    expect(fakeGuard.enters, isEmpty);
  });

  testWidgets('guard 进场失败：回 guest，弹幕未停、播放继续', (tester) async {
    await bootstrap(tester);
    fakeGuard.enterThrows = true;

    final ok = await runAction<bool>(
      tester,
      controller.enterAsAccount,
      settle: const Duration(milliseconds: 2100),
    );

    expect(ok, isFalse);
    expect(controller.presence.value, RoomPresence.guest);
    expect(fakeSite.danmaku.stops, 0, reason: '失败时游客资源零改动');
    expect(fakeGuard.enters, isNotEmpty);
  });

  testWidgets('并发进入复用同一 Future，账号详情只取一次', (tester) async {
    await bootstrap(tester);

    final f1 = controller.enterAsAccount();
    final f2 = controller.enterAsAccount();
    await tester.pump();
    final results = await Future.wait<bool>([f1, f2]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(results, equals([true, true]));
    expect(fakeSite.asAccountCalls, equals([true]));
    expect(fakeGuard.enters.length, 1);
    controller.stopGuardHeartbeatForTesting();
  });

  testWidgets('游客态发弹幕：自动进入成功后才经 guard 发送', (tester) async {
    await bootstrap(tester);

    await runAction<void>(tester, () => controller.sendDanmaku('hello'));

    expect(controller.presence.value, RoomPresence.account);
    expect(fakeGuard.sentDanmaku, equals(['hello']));
    expect(fakeSite.danmaku.sends, isEmpty, reason: '抖音弹幕必须走 guard');
  });

  testWidgets('游客态发弹幕：自动进入失败则不发送', (tester) async {
    await bootstrap(tester);
    fakeSite.accountFailsOnDetail = true;

    await runAction<void>(
      tester,
      () => controller.sendDanmaku('hello'),
      settle: const Duration(milliseconds: 2100),
    );

    expect(controller.presence.value, RoomPresence.guest);
    expect(fakeGuard.sentDanmaku, isEmpty);
    expect(fakeSite.danmaku.sends, isEmpty);
  });

  testWidgets('游客态点赞：自动进入成功后才发 action', (tester) async {
    await bootstrap(tester);

    await runAction<void>(tester, controller.like);

    expect(controller.presence.value, RoomPresence.account);
    expect(fakeGuard.sentActions, equals(['like']));
  });

  testWidgets('游客态点赞：自动进入失败则不发 action', (tester) async {
    await bootstrap(tester);
    fakeSite.accountFailsOnDetail = true;

    await runAction<void>(
      tester,
      controller.like,
      settle: const Duration(milliseconds: 2100),
    );

    expect(fakeGuard.sentActions, isEmpty);
    expect(controller.presence.value, RoomPresence.guest);
  });

  testWidgets('未登录：弹登录引导，取消后不进入', (tester) async {
    await bootstrap(tester);
    (Get.find<DouyinAccountService>()).logined.value = false;

    final future = controller.enterAsAccount();
    await tester.pump();
    expect(find.text('登录后才能发送弹幕，是否前往账号管理？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    final ok = await future;
    await tester.pump(const Duration(milliseconds: 250));

    expect(ok, isFalse);
    expect(controller.presence.value, RoomPresence.guest);
    expect(fakeGuard.enters, isEmpty);
  });
}
