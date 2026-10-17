import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_apply_target.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakePort implements SubPresencePort {
  final List<(String, Object?)> calls = [];
  Object? claimResult;
  Object? sendResult;
  final Set<String> throwing = <String>{};

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (throwing.contains(method)) throw StateError('main gone');
    if (method == PresenceProtocol.mClaim) {
      return claimResult ?? PresenceProtocol.encodeClaimOk();
    }
    if (method == PresenceProtocol.mGuardSend) {
      return sendResult ??
          PresenceProtocol.encodeSendResult(
              const PresenceSendResult(success: true));
    }
    return null;
  }
}

class _FakeTarget implements PresenceApplyTarget {
  _FakeTarget(this.detail);

  final LiveRoomDetail detail;
  // 注入账号服务以记录控制器方法被调「当刻」的借用 cookie，锁定
  // 先写后取 / 先清后调的时刻顺序（终态断言发现不了顺序对调）。
  DouyinAccountService? accounts;
  String? cookieAtFetch;
  String? cookieAtYield;
  String? cookieAtSuspended;
  int enters = 0;
  int yields = 0;
  int suspended = 0;
  int detailCalls = 0;
  bool detailThrows = false;
  bool enterThrows = false;
  LiveRoomDetail? lastDetail;
  Map<String, dynamic>? lastStatus;
  bool? lastReentered;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async {
    detailCalls++;
    cookieAtFetch = accounts?.loginCookie;
    if (detailThrows) throw StateError('limited');
    return detail;
  }

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    enters++;
    if (enterThrows) throw StateError('boom');
    lastDetail = accountDetail;
    lastStatus = guardStatus;
    lastReentered = reentered;
  }

  @override
  Future<void> applyYieldToGuest() async {
    cookieAtYield = accounts?.loginCookie;
    yields++;
  }

  @override
  Future<void> applySuspended() async {
    cookieAtSuspended = accounts?.loginCookie;
    suspended++;
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
        cookie: 'sessionid=x',
      ),
    );

void main() {
  late _FakePort port;
  late DouyinAccountService accounts;
  final site = Sites.allSites['douyin']!.liveSite as DouyinSite;

  IpcPresenceCoordinator coord(
    Map<String, PresenceApplyTarget> targets,
  ) =>
      IpcPresenceCoordinator(
        windowId: 'w1',
        port: port,
        resolveTarget: (tabId) => targets[tabId],
        accounts: accounts,
      );

  PresenceClaimArgs args({String guardRoomId = 'room_1'}) =>
      PresenceClaimArgs(
        roomId: '1',
        shareUrl: 'http://s',
        guardRoomId: guardRoomId,
        guardWebRid: '1',
        guardExtra: const <String, Object?>{'k': 'v'},
      );

  setUp(() {
    port = _FakePort();
    accounts = DouyinAccountService();
  });

  tearDown(() {
    site.loginCookie = '';
  });

  test('apply_enter：写借用 cookie（logined 不翻转）→ 自取详情 → apply 透传',
      () async {
    final detail = _detail('1');
    final target = _FakeTarget(detail)..accounts = accounts;
    final c = coord({'t1': target});

    final result = await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        const PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: <String, Object?>{
            'joined': false,
            'starGuard': false,
            'badgeActive': true,
          },
          reentered: true,
        ),
      ),
    );

    expect(result, isNull);
    expect(accounts.loginCookie, 'sessionid=zzz');
    expect(site.loginCookie, 'sessionid=zzz');
    expect(accounts.logined.value, isFalse, reason: '借用不翻转 logined');
    expect(target.detailCalls, 1);
    expect(target.cookieAtFetch, 'sessionid=zzz',
        reason: 'fetchAccountDetail 被调当刻 cookie 已写入（先写后取）');
    expect(target.enters, 1);
    expect(identical(target.lastDetail, detail), isTrue,
        reason: '传入的是子端自取详情，不是下发对象');
    expect(target.lastStatus, {
      'joined': false,
      'starGuard': false,
      'badgeActive': true,
    });
    expect(target.lastReentered, isTrue);
  });

  test('yield/suspended：先清 cookie 再调控制器；坏载荷 false', () async {
    final target = _FakeTarget(_detail('1'))..accounts = accounts;
    final c = coord({'t1': target});

    await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        const PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(accounts.loginCookie, 'sessionid=zzz');

    expect(
      await c.handleCall(
          PresenceProtocol.mApplyYield,
          PresenceProtocol.encodeTabApply('t1')),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: 'yield 先清 cookie');
    expect(site.loginCookie, '');
    expect(target.cookieAtYield, '',
        reason: 'applyYieldToGuest 被调当刻 cookie 已清空（先清后调）');
    expect(target.yields, 1);
    expect(target.suspended, 0);

    await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        const PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=again',
          status: <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(
      await c.handleCall(
          PresenceProtocol.mApplySuspended,
          PresenceProtocol.encodeTabApply('t1')),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: 'suspended 先清 cookie');
    expect(target.cookieAtSuspended, '',
        reason: 'applySuspended 被调当刻 cookie 已清空（先清后调）');
    expect(target.suspended, 1);

    expect(await c.handleCall(PresenceProtocol.mApplyYield, null), isFalse);

    // nit-4：enter 坏载荷返 false；未知 method 默认 null
    expect(await c.handleCall(PresenceProtocol.mApplyEnter, null), isFalse,
        reason: 'enter 坏载荷返 false');
    expect(await c.handleCall('pr_xxx', null), isNull,
        reason: '未知 method 默认 null');
  });

  test('target 已销毁（查无控制器）：静默返回，不写 cookie、不抛', () async {
    final c = coord(<String, PresenceApplyTarget>{});
    expect(
      await c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          const PresenceApplyEnterCall(
            tabId: 'gone',
            cookie: 'sessionid=zzz',
            status: <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: '无目标不写 cookie');
    expect(
      await c.handleCall(
          PresenceProtocol.mApplyYield,
          PresenceProtocol.encodeTabApply('gone')),
      isNull,
    );
  });

  test('自取详情失败不抛回主端、不调 applyAccountEnter；apply 抛错也被吞',
      () async {
    final target = _FakeTarget(_detail('1'))
      ..detailThrows = true
      ..enterThrows = true;
    final c = coord({'t1': target});

    await expectLater(
      c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          const PresenceApplyEnterCall(
            tabId: 't1',
            cookie: 'sessionid=zzz',
            status: <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      completes,
    );
    expect(target.enters, 0, reason: '自取失败不调 apply');
    expect(accounts.loginCookie, 'sessionid=zzz',
        reason: 'cookie 已写，等待失效点清理');

    // 恢复取详情；applyAccountEnter 自身抛错同样不外逸
    target.detailThrows = false;
    await expectLater(
      c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          const PresenceApplyEnterCall(
            tabId: 't1',
            cookie: 'sessionid=zzz',
            status: <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      completes,
    );
    expect(target.enters, 1);
  });

  test('per-tab proxy：claim 载荷当刻读取、成功/业务失败/IPC 失败映射；release/detach',
      () async {
    var guardRoomId = 'room_1';
    final c = coord(<String, PresenceApplyTarget>{});
    final client = c.clientForTab(
      tabId: 't1',
      args: () => args(guardRoomId: guardRoomId),
    );

    var r = await client.claim();
    expect(r.granted, isTrue);
    expect(client.isClaimed, isTrue);
    final claimCall =
        PresenceProtocol.decodeClaim(port.calls.last.$2)!;
    expect(claimCall.windowId, 'w1');
    expect(claimCall.tabId, 't1');
    expect(claimCall.roomId, '1');
    expect(claimCall.guardRoomId, 'room_1');
    expect(claimCall.guardExtra, {'k': 'v'});

    // args 提供者在再次 claim 当刻读到新值
    guardRoomId = 'room_2';
    r = await client.claim();
    expect(PresenceProtocol.decodeClaim(port.calls.last.$2)!.guardRoomId,
        'room_2');

    port.claimResult =
        PresenceProtocol.encodeClaimFailure(PresenceFailureReason.notConfigured);
    r = await client.claim();
    expect(r.granted, isFalse);
    expect(r.reason, PresenceFailureReason.notConfigured);
    expect(client.isClaimed, isFalse);

    port.claimResult = 'junk';
    r = await client.claim();
    expect(r.reason, PresenceFailureReason.ipcFailed);

    port.claimResult = null;
    port.throwing.add(PresenceProtocol.mClaim);
    r = await client.claim();
    expect(r.reason, PresenceFailureReason.ipcFailed);
    expect(client.isClaimed, isFalse);
    port.throwing.clear();

    expect(await client.claim(), isA<PresenceClaimResult>());
    expect(client.isClaimed, isTrue);
    await client.release();
    final releaseCall =
        PresenceProtocol.decodeRelease(port.calls.last.$2)!;
    expect(releaseCall.windowId, 'w1');
    expect(releaseCall.tabId, 't1');
    expect(port.calls.last.$1, PresenceProtocol.mRelease);
    expect(client.isClaimed, isFalse);

    port.throwing.add(PresenceProtocol.mRelease);
    await expectLater(client.release(), completes);
    port.throwing.clear();

    final client2 = c.clientForTab(tabId: 't2', args: args);
    await client2.detach();
    expect(port.calls.last.$1, PresenceProtocol.mDetach);
  });

  test('guard_send 载荷/结果往返；IPC 失败码与文案；register/batch/onClose',
      () async {
    final c = coord(<String, PresenceApplyTarget>{});
    final client = c.clientForTab(tabId: 't1', args: args);

    final ok = await client.sendDanmaku('hi');
    expect(ok.success, isTrue);
    var send = PresenceProtocol.decodeGuardSend(port.calls.last.$2)!;
    expect(send.windowId, 'w1');
    expect(send.tabId, 't1');
    expect(send.kind, PresenceProtocol.kDanmaku);
    expect(send.content, 'hi');

    await client.sendAction('like');
    send = PresenceProtocol.decodeGuardSend(port.calls.last.$2)!;
    expect(send.kind, PresenceProtocol.kAction);
    expect(send.action, 'like');

    port.throwing.add(PresenceProtocol.mGuardSend);
    var failed = await client.sendDanmaku('x');
    expect(failed.success, isFalse);
    expect(failed.code, kPresenceCodeIpcFailed);
    expect(failed.message, '主窗口服务无响应，请重试');
    port.throwing.clear();

    port.sendResult = 'junk';
    failed = await client.sendAction('like');
    expect(failed.code, kPresenceCodeIpcFailed);
    expect(failed.message, '主窗口服务无响应，请重试');

    await c.registerRemoteTab(
        tabId: 't9', siteId: 'douyin', roomId: '9', shareUrl: '');
    final reg = PresenceProtocol.decodeRegister(port.calls.last.$2)!;
    expect(reg.windowId, 'w1');
    expect(reg.tabId, 't9');
    expect(reg.siteId, 'douyin');
    expect(reg.roomId, '9');
    port.throwing.add(PresenceProtocol.mRegister);
    await expectLater(
      c.registerRemoteTab(
          tabId: 't9', siteId: 'douyin', roomId: '9', shareUrl: ''),
      completes,
    );
    port.throwing.clear();

    final callsBefore = port.calls.length;
    await c.batchRelease(<String>{});
    expect(port.calls.length, callsBefore, reason: '空集不发 IPC');
    await c.batchRelease({'t1', 't2'});
    final batch =
        PresenceProtocol.decodeBatchRelease(port.calls.last.$2)!;
    expect(batch.windowId, 'w1');
    expect(batch.tabIds.toSet(), {'t1', 't2'});
    port.throwing.add(PresenceProtocol.mBatchRelease);
    await expectLater(c.batchRelease({'t1'}), completes);
    port.throwing.clear();

    // onClose 是第三个 cookie 失效点
    final target = _FakeTarget(_detail('1'));
    final c2 = IpcPresenceCoordinator(
      windowId: 'w1',
      port: port,
      resolveTarget: (_) => target,
      accounts: accounts,
    );
    await c2.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        const PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(accounts.loginCookie, 'sessionid=zzz');
    c2.onClose();
    expect(accounts.loginCookie, '');
    expect(site.loginCookie, '');
  });
}
