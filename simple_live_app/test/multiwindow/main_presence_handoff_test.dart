import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/main_presence_service.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Registry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _Port implements SubWindowPort {
  final List<(String, String, Object?)> invokes = [];
  final List<String> alive = ['main'];
  final changed = StreamController<void>.broadcast();
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final id = 'w${++_seq}';
    alive.add(id);
    return SubWindowHandle(id);
  }

  @override
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    invokes.add((windowId, method, arguments));
    return null;
  }

  @override
  Future<List<String>> listWindowIds() async => List<String>.of(alive);

  @override
  Stream<void> get windowsChanged => changed.stream;
}

class _Guard extends GuardServerService {
  final sends = <Map<String, Object?>>[];
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
  String? savedAccountId(String platform) => 'acct1';
  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async =>
      {'joined': false, 'starGuard': false, 'badgeActive': true};
  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async =>
      {'inRoom': true};
  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {}
  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    sends.add({'platform': platform, 'roomId': roomId});
    return {'success': true};
  }
  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async =>
      {'success': true};
}

LiveRoomDetail _detail(String webRid) => LiveRoomDetail(
      roomId: webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$webRid',
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: 'room_$webRid',
        userId: 'u_$webRid',
        cookie: 'sessionid=new',
      ),
    );

class _FakeTab implements DouyinPresenceTab {
  _FakeTab(this.id, this.webRid);
  final String id;
  final String webRid;
  int reentered = 0;
  @override
  String get tabId => id;
  @override
  bool get isClosed => false;
  @override
  Future<LiveRoomDetail> fetchAccountDetail() async => _detail(webRid);
  @override
  String get guardRoomId => 'room_$webRid';
  @override
  String get guardWebRid => webRid;
  @override
  Map<String, dynamic> guardExtraArgs() => const {};
  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {}
  @override
  Future<void> applyYieldToGuest() async {}
  @override
  Future<void> applySuspended() async {}
  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    reentered++;
  }
}

void main() {
  late _Port port;
  late _Guard guard;
  late WindowRegistry registry;
  late WindowOpenService wos;
  late DouyinPresenceGateway gateway;
  late MainPresenceService svc;

  Future<Object?> register(String windowId, String tabId,
          {String roomId = '1'}) =>
      svc.handleCall(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(PresenceRegisterCall(
          windowId: windowId,
          tabId: tabId,
          siteId: Constant.kDouyin,
          roomId: roomId,
          shareUrl: '',
        )),
      );

  Future<Object?> claim(String windowId, String tabId, String webRid) =>
      svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(PresenceClaimCall(
          windowId: windowId,
          tabId: tabId,
          roomId: webRid,
          shareUrl: 'http://s/$tabId',
          guardRoomId: 'room_$webRid',
          guardWebRid: webRid,
          guardExtra: const <String, Object?>{},
        )),
      );

  Future<void> flush([int times = 5]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<PresenceSendResult> guardSend(String windowId, String tabId) async {
    return PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(PresenceGuardSendCall(
          windowId: windowId,
          tabId: tabId,
          kind: PresenceProtocol.kDanmaku,
          content: 'hi',
        )),
      ),
    )!;
  }

  setUp(() {
    port = _Port();
    guard = _Guard();
    registry = WindowRegistry(mainWindowId: 'main');
    wos = WindowOpenService(
      port: port,
      store: TabStore(registry: _Registry()),
      registry: registry,
    );
    wos.onInit();
    gateway = DouyinPresenceGateway(guard);
    svc = MainPresenceService(
      gateway: gateway,
      port: port,
      windowOpenService: wos,
      // 接缝必传：handoff 路径新建的 RemotePresenceTab 在 claim/rehome
      // applyReentered 当刻取详情/cookie；留空会落到 Sites.allSites 真实联网
      accountDetailFetcher: (roomId, shareUrl) async => _detail(roomId),
      cookieReader: () => 'sessionid=new',
    );
    svc.onInit();
  });

  tearDown(() {
    gateway.stopHeartbeatForTesting();
    svc.onClose();
    wos.onClose();
  });

  test('非跟踪 tab：prepareHandoff 返回 null（纯壳迁移不等）', () {
    expect(svc.prepareHandoff('none', 'w1'), isNull);
  });

  test('10s 超时：completer completeError 且条目清理（register 不再触发 rehome）',
      () {
    fakeAsync((async) {
      gateway.bindTab(_FakeTab('t1', '1'));
      final future = svc.prepareHandoff('t1', 'w1')!;
      // fakeAsync：监听者必须先于 elapse 挂接，否则 completeError 当刻
      // 零监听者即按未捕获异步错误上报（与 gateway rehome 测试同范式）
      Object? captured;
      future.then((_) {}, onError: (Object e) {
        captured = e;
      });
      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();
      expect(captured, isA<HandoffTimeoutException>());

      // 条目已清：迟到 register 走普通路径，不产生 apply invoke
      register('w1', 't1');
      async.flushMicrotasks();
      expect(port.invokes, isEmpty);
    });
  });

  test('主→子：register 命中 handoff，guard 三元组从网关旧端口复制，'
      'rehome 复刻下行且 guard_send 经新 windowId 成功', () async {
    // 主窗本地标签先经网关完整进场成为 holder+ready（生产中由主窗控制器
    // onInit bindTab + enterAsAccount 完成）：否则 rehome 的 holderReady
    // 判定不成立，currentGuardArgsFor 也读不到 guard 三元组
    final local = _FakeTab('t1', '1');
    gateway.bindTab(local);
    expect((await gateway.claim(local)).granted, isTrue);
    port.invokes.clear();

    final future = svc.prepareHandoff('t1', 'w1')!;
    await register('w1', 't1');
    await flush();
    await future; // 成功结算

    final apply = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(apply.single.$1, 'w1');
    expect(PresenceProtocol.decodeApplyEnter(apply.single.$3)!.reentered,
        isTrue);

    final send = await guardSend('w1', 't1');
    expect(send.success, isTrue);
    expect(guard.sends.single['roomId'], 'room_1',
        reason: '主→子新 RemoteTab 的 guard 来自 currentGuardArgsFor');
  });

  test('子→子：旧 RemoteTab guard 复制到新 tab，复刻发往新窗，旧窗 guard 被拒',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    port.invokes.clear();

    final future = svc.prepareHandoff('t1', 'w2')!;
    await register('w2', 't1');
    await flush();
    await future;

    final apply = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(apply.single.$1, 'w2');
    expect(PresenceProtocol.decodeApplyEnter(apply.single.$3)!.reentered,
        isTrue);

    final send = await guardSend('w2', 't1');
    expect(send.success, isTrue);
    expect(guard.sends.single['roomId'], 'room_1');
    expect((await guardSend('w1', 't1')).code, 'not_holder');
  });

  test('rehomeLocal（子→主）：摘远端索引、网关换到本地端口复刻；旧窗 guard 被拒',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    final local = _FakeTab('t1', '1');
    gateway.bindTab(local); // 主窗新控制器 onInit bindTab

    svc.prepareHandoff('t1', 'main');
    await svc.rehomeLocal('t1');

    expect(local.reentered, 1);
    expect((await guardSend('w1', 't1')).code, 'not_holder',
        reason: '索引已摘，旧窗迟到 guard 裸拒');
  });

  test('handoff 在途源窗死亡：失败结算 HandoffSourceClosedException', () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    // 生产中开窗必经 registry.registerChild 且端口存活列表含 w1；
    // 否则 reconcile 不产出 removed（对齐既有死亡对账测试夹具）
    registry.registerChild('w1', {'douyin_1'});
    port.alive.add('w1');
    final future = svc.prepareHandoff('t1', 'w2')!;
    // 监听者先挂：completeError 当刻零监听者会被 zone 记为未捕获异步错误
    final expectation = expectLater(
        future, throwsA(isA<HandoffSourceClosedException>()));

    port.alive.remove('w1');
    port.changed.add(null);
    await flush(10);

    await expectation;
  });

  test('handoff 在途目标窗死亡：失败结算 HandoffTargetClosedException', () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    // 源窗与目标窗均须 registerChild + 端口存活，reconcile 才能产出 removed；
    // t1 仍挂源窗 w1 名下（register 未改挂），故源路径摘不到它，靠 destWindowId 命中
    registry.registerChild('w1', {'douyin_1'});
    registry.registerChild('w2', {'douyin_2'});
    port.alive.add('w1');
    port.alive.add('w2');
    final future = svc.prepareHandoff('t1', 'w2')!;
    // 监听者先挂：completeError 当刻零监听者会被 zone 记为未捕获异步错误
    final expectation = expectLater(
        future, throwsA(isA<HandoffTargetClosedException>()));

    // 仅目标窗死亡（源窗 w1 仍存活）→ 立即失败结算，不等 10s 超时
    port.alive.remove('w2');
    port.changed.add(null);
    await flush(10);

    await expectation;
  });
}
