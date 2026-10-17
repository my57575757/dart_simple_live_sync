import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
// ignore: depend_on_referenced_packages
import 'package:wakelock_plus_platform_interface/messages.g.dart' show WakelockPlusApi;

class _FakeDanmaku extends LiveDanmaku {
  int starts = 0;
  int stops = 0;
  final sends = <String>[];
  Object? lastArgs;

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
        // 注：brief 原文写 const，但 simple_live_core 的 DouyinDanmakuArgs
        // 构造非 const（既有同类测试亦无 const），去掉 const 方可编译
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

class _LoggedOutAccount extends DouyinAccountService {
  @override
  RxBool get logined => false.obs;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _LoggedInAccount extends DouyinAccountService {
  @override
  RxBool get logined => true.obs;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakePort implements SubPresencePort {
  final List<(String, Object?)> calls = [];
  Object? claimResult;
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (method == PresenceProtocol.mClaim) {
      return claimResult ?? PresenceProtocol.encodeClaimOk();
    }
    return null;
  }
}

/// 假 PresenceClient：计数 sendDanmaku/sendAction 调用，验证子窗分流。
class _FakeWriteClient implements PresenceClient {
  int sendDanmakuCount = 0;
  int sendActionCount = 0;
  final danmakuContents = <String>[];
  final actions = <String>[];
  PresenceSendResult result = const PresenceSendResult(success: true);

  @override
  Future<PresenceClaimResult> claim() async =>
      const PresenceClaimResult.granted();

  @override
  Future<void> release() async {}

  @override
  Future<void> detach() async {}

  @override
  bool get isClaimed => false;

  @override
  Future<PresenceSendResult> sendDanmaku(String content) async {
    sendDanmakuCount++;
    danmakuContents.add(content);
    return result;
  }

  @override
  Future<PresenceSendResult> sendAction(String action) async {
    sendActionCount++;
    actions.add(action);
    return result;
  }
}

/// 通用假站点：bili/huya/douyu/twitch 子窗发送/凭据测试共用。
class _FakeGenericSite extends LiveSite {
  _FakeGenericSite(this.siteId);
  final String siteId;
  final _FakeDanmaku danmaku = _FakeDanmaku();

  @override
  LiveDanmaku getDanmaku() => danmaku;

  LiveRoomDetail buildDetail({String roomId = '222', Object? danmakuData}) =>
      LiveRoomDetail(
        roomId: roomId,
        title: 't',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 1,
        status: true,
        url: 'https://example.com/$siteId/$roomId',
        danmakuData: danmakuData,
      );

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async =>
      buildDetail(roomId: roomId);
}

class _FakeDouyuAccounts extends DouyuAccountService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeTwitchAccounts extends TwitchAccountService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

void main() {
  setUp(() {
    MultiWindowRole.isSubWindow = true;
  });

  tearDown(() {
    MultiWindowRole.isSubWindow = false;
    Get.reset();
  });

  LiveRoomController makeController({String tabId = 't1'}) {
    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: tabId,
    );
    c.detail.value = site.guestDetail();
    return c;
  }

  IpcPresenceCoordinator putCoordinator(_FakePort port) {
    Get.put<GuardServerService>(_Guard(), permanent: true);
    Get.put<DouyinAccountService>(_LoggedOutAccount(), permanent: true);
    return Get.put<IpcPresenceCoordinator>(
      IpcPresenceCoordinator(
        windowId: 'w1',
        port: port,
        resolveTarget: (_) => null,
        accounts: Get.find<DouyinAccountService>(),
        douyuAccounts: DouyuAccountService(),
        twitchAccounts: TwitchAccountService(),
      ),
      permanent: true,
    );
  }

  LiveRoomController makeSiteController({
    required String siteId,
    required _FakeGenericSite liveSite,
    String tabId = 't1',
    String roomId = '222',
  }) {
    final c = LiveRoomController(
      pSite: Site(id: siteId, name: siteId, logo: '', liveSite: liveSite),
      pRoomId: roomId,
      pShareUrl: 'https://example.com/$siteId/$roomId',
      tabId: tabId,
    );
    c.detail.value = liveSite.buildDetail(roomId: roomId);
    return c;
  }

  test('子窗绑定：pr_register 建索引；enterAsAccount 跳过本地登录门走 IPC claim',
      () async {
    final port = _FakePort();
    putCoordinator(port);
    final c = makeController();

    expect(c.bindSubWindowPresence(), isTrue);
    // register 为 unawaited best-effort，排空一轮微任务
    await Future<void>.delayed(Duration.zero);

    final register =
        PresenceProtocol.decodeRegister(port.calls.first.$2)!;
    expect(register.windowId, 'w1');
    expect(register.tabId, 't1');
    expect(register.siteId, Constant.kDouyin);
    expect(register.roomId, '111');
    expect(register.shareUrl, 'https://live.douyin.com/111');

    // 本地抖音登录态恒 false：子窗必须跳过 danmakuLogined 门直接 claim；
    // granted 后乐观置 account（不依赖主端 apply 回调）
    expect(await c.enterAsAccount(), isTrue);
    expect(c.presence.value, RoomPresence.account);

    final claimCall = PresenceProtocol.decodeClaim(
      port.calls.firstWhere((c) => c.$1 == PresenceProtocol.mClaim).$2,
    )!;
    expect(claimCall.windowId, 'w1');
    expect(claimCall.tabId, 't1');
    expect(claimCall.roomId, '111');
    expect(claimCall.shareUrl, 'https://live.douyin.com/111');
    expect(claimCall.guardRoomId, 'room_111',
        reason: 'guard 参数 claim 当刻从详情读取');
    expect(claimCall.guardWebRid, '111');
  });

  testWidgets('子窗输入入口不再 toast 拦截，未登录直接弹登录确认框', (tester) async {
    putCoordinator(_FakePort());
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final c = makeController();

    // showDanmakuInputDialog 内部 await showDanmakuLoginDialog → Get.dialog，
    // testWidgets 里先 await 会挂起；持 Future、泵帧渲染后再断言/点确定。
    final inputEntry = c.showDanmakuInputDialog();
    await tester.pump();
    expect(find.text('请在主窗口发送弹幕'), findsNothing,
        reason: '入口不再被 toast 拦截');
    expect(Get.isDialogOpen, isTrue, reason: '未登录直接弹登录确认框');
    expect(
      find.text('子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务'),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsOneWidget,
        reason: '单确认键，无取消键、不导航账号管理');
    expect(find.text('登录后才能发送弹幕，是否前往账号管理？'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(Get.isDialogOpen, isNot(true));
    await inputEntry;
  });

  testWidgets('子窗全屏回车不再 toast 拦截，未登录直接弹登录确认框', (tester) async {
    putCoordinator(_FakePort());
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final c = makeController();

    c.fullScreenState.value = true;
    c.handleKeyboardKey(const KeyDownEvent(
      logicalKey: LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
      // Flutter 3.47 的 KeyDownEvent 要求 timeStamp
      timeStamp: Duration.zero,
    ));
    await tester.pump();
    expect(find.text('请在主窗口发送弹幕'), findsNothing,
        reason: '全屏回车入口同样不再被 toast 拦截');
    expect(Get.isDialogOpen, isTrue, reason: '未登录直接弹登录确认框');
    expect(
      find.text('子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务'),
      findsOneWidget,
    );

    // handleKeyboardKey 未 await showDanmakuInputDialog；关掉对话框让其续体收尾
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(Get.isDialogOpen, isNot(true));
    await tester.pump();
  });

  test('guardActionEnabled 子窗抖音恒可见；非子窗不绑定 IPC 通道', () {
    final port = _FakePort();
    putCoordinator(port);
    final c = makeController();

    expect(c.guardActionEnabled, isTrue,
        reason: '子窗抖音未登录、guard 未配置仍恒可见');

    MultiWindowRole.isSubWindow = false;
    expect(c.guardActionEnabled, isFalse);
    expect(c.bindSubWindowPresence(), isFalse,
        reason: '非子窗不绑定 IPC presence 通道');
    expect(port.calls, isEmpty);
  });

  test('子窗刷新/切房 leave 后重建：再发 register 并立即清借用凭据', () async {
    final port = _FakePort();
    putCoordinator(port);
    final c = makeController();

    expect(c.bindSubWindowPresence(), isTrue);
    // register 为 unawaited best-effort，排空一轮微任务
    await Future<void>.delayed(Duration.zero);

    final accounts = Get.find<DouyinAccountService>();
    accounts.setBorrowedLoginCookie('sessionid=zzz');
    expect(accounts.loginCookie, 'sessionid=zzz');

    await c.debugReRegisterSubWindowAfterLeave();

    final registers =
        port.calls.where((x) => x.$1 == PresenceProtocol.mRegister).toList();
    expect(registers, hasLength(2), reason: 'onInit 一次 + 刷新重建一次');
    final last = PresenceProtocol.decodeRegister(registers.last.$2)!;
    expect(last.tabId, 't1');
    expect(last.roomId, '111');
    expect(accounts.loginCookie, '', reason: '刷新路径立即清借用凭据');
  });

  testWidgets('closeForMove 语义：markMovedAway 后 onClose 不发 pr_release；'
      '普通 onClose 仍发', (tester) async {
    // 提供真实 binding（最简 Scaffold，无 UI 交互不需要 SmartDialog）。
    // 纯 test() 下 onClose 异步链上的 pigeon 通道无 mock，PlatformException
    // 晚到漏入测试 zone 导致 flake；testWidgets + 通道 mock 覆盖。
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));

    // mock wakelock_plus pigeon 通道回成功空信封。
    // 依据 wakelock_plus_platform_interface 1.7.0 messages.g.dart（pigeon v28）：
    //   channel: dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle
    //   codec:   WakelockPlusApi.pigeonChannelCodec（_PigeonCodec）
    //   void 成功返回 wrapResponse(result: null) → <Object?>[null]（List 信封）。
    //   注：brief 猜测的 {'result': null} 为旧版 pigeon async 协议，v28 实为
    //   List 信封（_extractReplyValueOrThrow 对 isNullValid=true 接受 [null]）。
    // handler 在整个用例期间有效（Get.reset 不影响 binding 级 channel mock）。
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async =>
          WakelockPlusApi.pigeonChannelCodec.encodeMessage(<Object?>[null]),
    );

    // 迁移关闭路径
    final movedPort = _FakePort();
    putCoordinator(movedPort);
    final moved = makeController();
    moved.bindSubWindowPresence();
    await tester.pump();
    movedPort.calls.clear();

    moved.markMovedAway();
    moved.onClose();
    await tester.pump();
    await tester.pump();
    expect(
      movedPort.calls.any((c) => c.$1 == PresenceProtocol.mRelease),
      isFalse,
      reason: '迁移关闭不发 leave，心跳/栈由主端 rehome 延续',
    );

    // 普通关闭路径（Get.reset 在 tearDown，手动新建一套）
    Get.reset();
    final normalPort = _FakePort();
    putCoordinator(normalPort);
    final normal = makeController();
    normal.bindSubWindowPresence();
    await tester.pump();
    normalPort.calls.clear();

    normal.onClose();
    await tester.pump();
    await tester.pump();
    expect(
      normalPort.calls.any((c) => c.$1 == PresenceProtocol.mRelease),
      isTrue,
      reason: '普通 onClose 行为不变',
    );
  });

  group('Task5 发送分流 / client 重绑 / guardActionEnabled', () {
    test('子窗 bili 发弹幕走 writeClient，恰好一次', () async {
      putCoordinator(_FakePort());
      final site = _FakeGenericSite(Constant.kBiliBili);
      final c = makeSiteController(siteId: Constant.kBiliBili, liveSite: site);
      final client = _FakeWriteClient();
      c.debugBindWriteClient(client);

      await c.sendDanmaku('hello');

      expect(client.sendDanmakuCount, 1);
      expect(client.danmakuContents, ['hello']);
      expect(site.danmaku.sends, isEmpty);
    });

    test('子窗 huya 发弹幕走 writeClient，恰好一次', () async {
      putCoordinator(_FakePort());
      final site = _FakeGenericSite(Constant.kHuya);
      final c = makeSiteController(siteId: Constant.kHuya, liveSite: site);
      final client = _FakeWriteClient();
      c.debugBindWriteClient(client);

      await c.sendDanmaku('hi');

      expect(client.sendDanmakuCount, 1);
      expect(client.danmakuContents, ['hi']);
      expect(site.danmaku.sends, isEmpty);
    });

    test('子窗 douyu 发弹幕走 liveDanmaku，不调 writeClient', () async {
      putCoordinator(_FakePort());
      final site = _FakeGenericSite(Constant.kDouyu);
      final c = makeSiteController(siteId: Constant.kDouyu, liveSite: site);
      final client = _FakeWriteClient();
      c.debugBindWriteClient(client);

      await c.sendDanmaku('yo');

      expect(client.sendDanmakuCount, 0);
      expect(site.danmaku.sends, ['yo']);
    });

    test('子窗 bili 点赞走 writeClient.sendAction', () async {
      putCoordinator(_FakePort());
      final site = _FakeGenericSite(Constant.kBiliBili);
      final c = makeSiteController(siteId: Constant.kBiliBili, liveSite: site);
      final client = _FakeWriteClient();
      c.debugBindWriteClient(client);

      await c.like();

      expect(client.sendActionCount, 1);
      expect(client.actions, ['like']);
    });

    test('切房非抖音→抖音：rebind 后 _presenceClient 重建', () {
      final port = _FakePort();
      putCoordinator(port);
      final biliSite = _FakeGenericSite(Constant.kBiliBili);
      final c = makeSiteController(siteId: Constant.kBiliBili, liveSite: biliSite);
      expect(c.bindSubWindowWriteClient(), isTrue);
      expect(c.debugWriteClient, isNotNull);
      expect(c.debugPresenceClient, isNull);

      // 模拟切房到抖音：更新站点身份后动态重绑
      final douyinSite = _Site();
      c.rxSite.value =
          Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: douyinSite);
      c.rxRoomId.value = '333';
      c.rxShareUrl.value = 'https://live.douyin.com/333';
      c.debugRebindSubWindowClients();

      expect(c.debugPresenceClient, isNotNull, reason: '非抖音→抖音后 presence 重建');
      expect(c.debugWriteClient, isNull, reason: '抖音不挂 write client');
    });

    test('切房抖音→bili：rebind 后 _writeClient 重建、_presenceClient 置空',
        () {
      final port = _FakePort();
      putCoordinator(port);
      final c = makeController();
      expect(c.bindSubWindowPresence(), isTrue);
      expect(c.debugPresenceClient, isNotNull);

      // 模拟切房到 bili
      final biliSite = _FakeGenericSite(Constant.kBiliBili);
      c.rxSite.value = Site(
          id: Constant.kBiliBili, name: '哔哩哔哩', logo: '', liveSite: biliSite);
      c.rxRoomId.value = '444';
      c.rxShareUrl.value = 'https://example.com/bilibili/444';
      c.debugRebindSubWindowClients();

      expect(c.debugPresenceClient, isNull);
      expect(c.debugWriteClient, isNotNull, reason: '抖音→bili 后挂 write client');
    });

    test('guardActionEnabled：子窗 bili 恒可见；子窗 huya 不可见（无互动 UI）',
        () {
      putCoordinator(_FakePort());

      final biliSite = _FakeGenericSite(Constant.kBiliBili);
      final bili =
          makeSiteController(siteId: Constant.kBiliBili, liveSite: biliSite);
      expect(bili.guardActionEnabled, isTrue);

      final huyaSite = _FakeGenericSite(Constant.kHuya);
      final huya =
          makeSiteController(siteId: Constant.kHuya, liveSite: huyaSite);
      expect(huya.guardActionEnabled, isFalse);
    });

    test('主窗行为零变化：bili/douyin guardActionEnabled 不放行、不绑 IPC', () {
      final port = _FakePort();
      putCoordinator(port);
      MultiWindowRole.isSubWindow = false;

      final biliSite = _FakeGenericSite(Constant.kBiliBili);
      final bili =
          makeSiteController(siteId: Constant.kBiliBili, liveSite: biliSite);
      expect(bili.guardActionEnabled, isFalse,
          reason: '主窗 bili 未配置/未登录不放行');

      final c = makeController();
      expect(c.guardActionEnabled, isFalse,
          reason: '主窗 douyin 未配置/未登录不放行');
      expect(c.bindSubWindowPresence(), isFalse,
          reason: '非子窗不绑定 IPC presence 通道');
      expect(c.bindSubWindowWriteClient(), isFalse,
          reason: '非子窗不绑定 write client');
      expect(port.calls, isEmpty);
    });

    test('主窗 bili 发弹幕零变化：不走 writeClient，落 liveDanmaku', () async {
      MultiWindowRole.isSubWindow = false;
      putCoordinator(_FakePort());
      final site = _FakeGenericSite(Constant.kBiliBili);
      final c = makeSiteController(siteId: Constant.kBiliBili, liveSite: site);
      final client = _FakeWriteClient();
      c.debugBindWriteClient(client);

      await c.sendDanmaku('hello');

      expect(client.sendDanmakuCount, 0);
      expect(site.danmaku.sends, ['hello']);
    });

    test('主窗 douyin 发弹幕零变化：仍走 presence client', () async {
      MultiWindowRole.isSubWindow = false;
      // 不经 putCoordinator：主窗 douyin 只需 GuardServerService.instance
      // 与 danmakuLogined（登录态过 ensureAccountPresence 门）
      Get.put<GuardServerService>(_Guard(), permanent: true);
      Get.put<DouyinAccountService>(_LoggedInAccount(), permanent: true);
      final c = makeController();
      final client = _FakeWriteClient();
      c.debugBindPresenceClient(client);

      await c.sendDanmaku('hello');

      expect(client.sendDanmakuCount, 1);
      expect(client.danmakuContents, ['hello']);
    });

    test('applyBorrowedCredentials douyu：凭据非空 stop+start 各一次', () async {
      final site = _FakeGenericSite(Constant.kDouyu);
      final c = makeSiteController(siteId: Constant.kDouyu, liveSite: site);
      c.detail.value = site.buildDetail(
        roomId: '222',
        danmakuData: DouyuDanmakuArgs(roomId: 222, cookie: 'guest'),
      );

      final douyuAccounts = _FakeDouyuAccounts();
      douyuAccounts.cookie = 'acf_stk=x; acf_uid=1';
      Get.put<DouyuAccountService>(douyuAccounts, permanent: true);

      await c.applyBorrowedCredentials(Constant.kDouyu);

      expect(site.danmaku.stops, 1);
      expect(site.danmaku.starts, 1);
      final args = site.danmaku.lastArgs;
      expect(args, isA<DouyuDanmakuArgs>());
      expect((args as DouyuDanmakuArgs).cookie, 'acf_stk=x; acf_uid=1');
    });

    test('applyBorrowedCredentials douyu：凭据空不重启弹幕', () async {
      final site = _FakeGenericSite(Constant.kDouyu);
      final c = makeSiteController(siteId: Constant.kDouyu, liveSite: site);
      c.detail.value = site.buildDetail(
        roomId: '222',
        danmakuData: DouyuDanmakuArgs(roomId: 222),
      );

      final douyuAccounts = _FakeDouyuAccounts();
      douyuAccounts.cookie = '';
      Get.put<DouyuAccountService>(douyuAccounts, permanent: true);

      await c.applyBorrowedCredentials(Constant.kDouyu);

      expect(site.danmaku.stops, 0);
      expect(site.danmaku.starts, 0);
    });

    test('applyBorrowedCredentials twitch：凭据非空构造新 args 并 stop+start',
        () async {
      final site = _FakeGenericSite(Constant.kTwitch);
      final c = makeSiteController(siteId: Constant.kTwitch, liveSite: site);
      c.detail.value = site.buildDetail(
        roomId: '222',
        danmakuData: TwitchDanmakuArgs(channel: 'somechannel'),
      );

      final twitchAccounts = _FakeTwitchAccounts();
      twitchAccounts.oauthToken = 'token123';
      twitchAccounts.userLogin = 'user1';
      Get.put<TwitchAccountService>(twitchAccounts, permanent: true);

      await c.applyBorrowedCredentials(Constant.kTwitch);

      expect(site.danmaku.stops, 1);
      expect(site.danmaku.starts, 1);
      final args = site.danmaku.lastArgs;
      expect(args, isA<TwitchDanmakuArgs>());
      expect((args as TwitchDanmakuArgs).channel, 'somechannel');
      expect(args.oauthToken, 'token123');
      expect(args.userLogin, 'user1');
    });
  });
}
