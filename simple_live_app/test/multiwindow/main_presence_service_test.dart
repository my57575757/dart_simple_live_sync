import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/main_presence_service.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
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

class _FakeSubWindowPort implements SubWindowPort {
  final List<(String, String, Object?)> invokes = [];
  final List<String> alive = ['main'];
  final StreamController<void> changed =
      StreamController<void>.broadcast();
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

class _FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];
  final ensureAccounts = <String>[];
  final sendDanmakus = <Map<String, Object?>>[];
  final sendActions = <Map<String, Object?>>[];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async {
    ensureAccounts.add(platform);
    return 'acct1';
  }

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
  }) async {
    enters.add('$accountId@$roomId');
    return {'joined': false, 'starGuard': false, 'badgeActive': true};
  }

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
  }) async {
    exits.add('$accountId@$roomId');
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
    sendDanmakus.add({
      'platform': platform,
      'accountId': accountId,
      'roomId': roomId,
      'content': content,
    });
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async {
    sendActions.add({
      'accountId': accountId,
      'roomId': roomId,
      'action': action,
    });
    return {'success': true};
  }
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

void main() {
  late _FakeGuard guard;
  late _FakeSubWindowPort port;
  late WindowRegistry registry;
  late WindowOpenService windowOpenService;
  late DouyinPresenceGateway gateway;
  late MainPresenceService svc;
  late String cookieNow;

  Future<Object?> register(String windowId, String tabId,
          {String siteId = 'douyin', String roomId = '1'}) =>
      svc.handleCall(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(PresenceRegisterCall(
          windowId: windowId,
          tabId: tabId,
          siteId: siteId,
          roomId: roomId,
          shareUrl: '',
        )),
      );

  Future<Object?> claim(
    String windowId,
    String tabId, {
    required String roomId,
    required String guardRoomId,
    required String guardWebRid,
  }) =>
      svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(PresenceClaimCall(
          windowId: windowId,
          tabId: tabId,
          roomId: roomId,
          shareUrl: 'http://s/$tabId',
          guardRoomId: guardRoomId,
          guardWebRid: guardWebRid,
          guardExtra: const <String, Object?>{},
        )),
      );

  setUp(() {
    guard = _FakeGuard();
    port = _FakeSubWindowPort();
    registry = WindowRegistry(mainWindowId: 'main');
    windowOpenService = WindowOpenService(
      port: port,
      store: TabStore(registry: _Registry()),
      registry: registry,
    );
    windowOpenService.onInit();
    cookieNow = 'sessionid=old';
    gateway = DouyinPresenceGateway(guard);
    svc = MainPresenceService(
      gateway: gateway,
      port: port,
      windowOpenService: windowOpenService,
      // claim 在途期间"主窗换号"：fetcher 内改值，apply 当刻必须读到新值
      accountDetailFetcher: (roomId, shareUrl) async {
        cookieNow = 'sessionid=new';
        return _detail(roomId);
      },
      cookieReader: () => cookieNow,
    );
    svc.onInit();
  });

  tearDown(() {
    gateway.stopHeartbeatForTesting();
    svc.onClose();
    windowOpenService.onClose();
  });

  test('register 只建死亡对账索引：不进栈、零 HTTP、零 invoke；非抖音/坏载荷拒绝',
      () async {
    expect(await register('w1', 't1'), isTrue);
    expect(guard.ensureAccounts, isEmpty);
    expect(guard.enters, isEmpty);
    expect(port.invokes, isEmpty);

    expect(await register('w1', 'tb', siteId: 'bilibili'), isFalse);
    expect(await svc.handleCall(PresenceProtocol.mRegister, null), isFalse);

    // 未 register 直接 claim：拒绝，不触达网关
    expect(
      await svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(
          const PresenceClaimCall(
            windowId: 'w1',
            tabId: 'x',
            roomId: '1',
            shareUrl: '',
            guardRoomId: 'r',
            guardWebRid: 'g',
            guardExtra: <String, Object?>{},
          ),
        ),
      ),
      isFalse,
    );
    expect(guard.enters, isEmpty);
  });

  test('远端 claim 成功：进场一次、apply_enter 下行且 cookie 为当刻值', () async {
    await register('w1', 't1');
    port.invokes.clear();
    guard.enters.clear();
    cookieNow = 'sessionid=old';
    final resp = await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    expect(
      PresenceProtocol.decodeClaimResult(resp),
      (ok: true, reason: null),
    );
    expect(guard.ensureAccounts, ['douyin']);
    expect(guard.enters, ['acct1@room_1']);

    expect(port.invokes, hasLength(1));
    final invoke = port.invokes.single;
    expect(invoke.$1, 'w1');
    expect(invoke.$2, PresenceProtocol.mApplyEnter);
    final apply = PresenceProtocol.decodeApplyEnter(invoke.$3)!;
    expect(apply.tabId, 't1');
    expect(apply.cookie, 'sessionid=new', reason: 'cookie 必须 apply 当刻读取');
    expect(apply.status, {'joined': false, 'starGuard': false, 'badgeActive': true});
    expect(apply.reentered, isFalse);
  });

  test('混栈：t2 抢占 t1 收 yield；release t2 后 t1 以 reentered 接管', () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    await register('w2', 't2', roomId: '2');
    await claim('w2', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');

    final yields = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyYield)
        .toList();
    expect(yields, hasLength(1));
    expect(yields.single.$1, 'w1');
    expect(PresenceProtocol.decodeTabApply(yields.single.$3), 't1');

    port.invokes.clear();
    final resp = await svc.handleCall(
      PresenceProtocol.mRelease,
      PresenceProtocol.encodeRelease(
          const PresenceReleaseCall(windowId: 'w2', tabId: 't2')),
    );
    expect(resp, isTrue);
    expect(guard.exits, contains('acct1@room_2'));

    final reenters = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(reenters, hasLength(1));
    expect(reenters.single.$1, 'w1');
    final apply =
        PresenceProtocol.decodeApplyEnter(reenters.single.$3)!;
    expect(apply.tabId, 't1');
    expect(apply.reentered, isTrue);
  });

  test('detach：摘栈不发 exit、不摘索引；同窗重新 claim 再进场；未知 release 幂等',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    port.invokes.clear();
    guard.enters.clear();

    expect(
      await svc.handleCall(
        PresenceProtocol.mDetach,
        PresenceProtocol.encodeRelease(
            const PresenceReleaseCall(windowId: 'w1', tabId: 't1')),
      ),
      isTrue,
    );
    expect(guard.exits, isEmpty, reason: 'detach 不发 exit');
    expect(port.invokes, isEmpty);

    final displaced = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(displaced.code, 'not_holder');

    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    expect(guard.enters, ['acct1@room_1'], reason: '重新 claim 完整再进场一次');
    expect(
      port.invokes.any((i) => i.$2 == PresenceProtocol.mApplyEnter),
      isTrue,
    );

    expect(
      await svc.handleCall(
        PresenceProtocol.mRelease,
        PresenceProtocol.encodeRelease(
            const PresenceReleaseCall(windowId: 'w1', tabId: 'zzz')),
      ),
      isTrue,
      reason: '未知 tab 幂等',
    );
    expect(
      await svc.handleCall(PresenceProtocol.mRelease, null),
      isFalse,
      reason: '坏载荷 false',
    );
  });

  test('batch_release 整批一次 exit；子窗进程死亡经对账批量释放', () async {
    await register('w1', 't1', roomId: '1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    await register('w1', 't2', roomId: '2');
    await claim('w1', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');

    expect(
      await svc.handleCall(
        PresenceProtocol.mBatchRelease,
        PresenceProtocol.encodeBatchRelease(const PresenceBatchReleaseCall(
          windowId: 'w1',
          tabIds: ['t1', 't2'],
        )),
      ),
      isTrue,
    );
    expect(guard.exits, ['acct1@room_2'], reason: '整批仅 holder 一次 exit');

    // 正常开窗登记后 register+claim，再模拟进程被杀（无临终消息）
    registry.registerChild('w2', {'douyin_3'});
    port.alive.add('w2');
    await register('w2', 't3', roomId: '3');
    await claim('w2', 't3',
        roomId: '3', guardRoomId: 'room_3', guardWebRid: '3');

    port.alive.remove('w2');
    port.changed.add(null);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(guard.exits.where((e) => e == 'acct1@room_3').length, 1,
        reason: '死亡对账至多一次 exit');
    final send = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w2',
            tabId: 't3',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(send.code, 'not_holder', reason: '死亡 tab 索引已摘除');
  });

  test('guard_send：holder 弹幕/动作经网关执行；抢占后 not_holder 零 HTTP；坏载荷 false',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');

    final danmaku = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kDanmaku,
            content: 'hello',
          ),
        ),
      ),
    )!;
    expect(danmaku.success, isTrue);
    expect(guard.sendDanmakus.single, containsPair('content', 'hello'));
    expect(guard.sendDanmakus.single, containsPair('platform', 'douyin'));

    final action = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(action.success, isTrue);
    expect(guard.sendActions.single, containsPair('action', 'like'));
    expect(guard.sendActions.single.containsKey('platform'), isFalse,
        reason: 'sendAction 不带 platform');

    await register('w2', 't2', roomId: '2');
    await claim('w2', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');
    guard.sendDanmakus.clear();
    final displaced = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kDanmaku,
            content: 'x',
          ),
        ),
      ),
    )!;
    expect(displaced.code, 'not_holder');
    expect(guard.sendDanmakus, isEmpty);

    expect(
      await svc.handleCall(PresenceProtocol.mGuardSend, null),
      isFalse,
    );
  });

  test('release 摘索引后重 register：同 tabId 刷新后 claim 自愈；不重注则裸 false',
      () async {
    await register('w1', 't1');
    expect(
      PresenceProtocol.decodeClaimResult(
        await claim('w1', 't1',
            roomId: '1', guardRoomId: 'room_1', guardWebRid: '1'),
      ),
      (ok: true, reason: null),
    );

    // 子窗刷新：leave 发 release（摘死亡索引 + 仲裁标签）
    expect(
      await svc.handleCall(
        PresenceProtocol.mRelease,
        PresenceProtocol.encodeRelease(
            const PresenceReleaseCall(windowId: 'w1', tabId: 't1')),
      ),
      isTrue,
    );

    // 不重注册直接 claim：裸 false（钉死故障现象，子端据此映射 ipcFailed）
    expect(
      await claim('w1', 't1',
          roomId: '1', guardRoomId: 'room_1', guardWebRid: '1'),
      isFalse,
    );

    // 刷新后重发 pr_register（幂等纯索引写）
    expect(await register('w1', 't1'), isTrue);

    // 同一 tabId 再 claim：granted（刷新自愈）
    expect(
      PresenceProtocol.decodeClaimResult(
        await claim('w1', 't1',
            roomId: '1', guardRoomId: 'room_1', guardWebRid: '1'),
      ),
      (ok: true, reason: null),
    );

    // 索引重建后 guard_send 恢复 holder 执行（不再 not_holder）
    final send = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(send.success, isTrue);
    expect(guard.sendActions, isNotEmpty);
  });
}
