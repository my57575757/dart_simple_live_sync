import 'dart:async';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/local_presence_client.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];
  final beats = <String>[];
  final reregisters = <String>[];
  final ensureAccounts = <String>[];

  /// 非 null 时 enterRoom 会等在该 Completer 上，用于构造在途 claim
  Completer<void>? enterGate;

  /// 严格时序的事件流水（含 enter/exit），用于断言 exit 先于 fallback enter
  final events = <String>[];

  bool enterThrowsOnce = false;
  bool detailGuardUnconfigured = false;
  Object? heartbeatThrowOnce;
  Map<String, dynamic> heartbeatResult = {'inRoom': true};
  int inRoomFalseBeats = 0;

  final sentDanmaku = <String>[];
  final sentActions = <String>[];
  bool sendDanmakuThrow404Once = false;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => !detailGuardUnconfigured;

  @override
  Future<String?> ensureAccount(String platform) async {
    ensureAccounts.add(platform);
    return 'acct1';
  }

  @override
  Future<String?> reregister(String platform) async {
    reregisters.add(platform);
    return 'acct2';
  }

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    final gate = enterGate;
    if (gate != null) {
      await gate.future;
    }
    if (enterThrowsOnce) {
      enterThrowsOnce = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/api/room/enter'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/room/enter'),
          statusCode: 404,
        ),
      );
    }
    enters.add('$accountId@$roomId');
    events.add('enter:$roomId');
    return {'joined': false, 'starGuard': false, 'badgeActive': true};
  }

  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    final thrown = heartbeatThrowOnce;
    if (thrown != null) {
      heartbeatThrowOnce = null;
      throw thrown;
    }
    beats.add('$accountId@$roomId');
    if (inRoomFalseBeats > 0) {
      inRoomFalseBeats--;
      return {'inRoom': false};
    }
    return heartbeatResult;
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add('$accountId@$roomId');
    events.add('exit:$roomId');
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
    if (sendDanmakuThrow404Once) {
      sendDanmakuThrow404Once = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/api/send'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/send'),
          statusCode: 404,
        ),
      );
    }
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
}

LiveRoomDetail _detail(String webRid, String cookie) => LiveRoomDetail(
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
        userId: 'uid_$webRid',
        cookie: cookie,
      ),
    );

class FakeTab implements DouyinPresenceTab {
  FakeTab(this.id, this.webRid, {this.cookie = 'sessionid=abc'});

  final String id;
  final String webRid;
  final String cookie;

  int detailFetches = 0;
  bool detailThrows = false;
  bool applyThrows = false;
  int yields = 0;
  int suspended = 0;
  final reenteredCalls = <bool>[];
  Map<String, dynamic>? lastStatus;
  String? lastDetailCookie;
  bool closed = false;

  @override
  String get tabId => id;

  @override
  bool get isClosed => closed;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async {
    if (detailThrows) throw CoreError('blocked by host');
    detailFetches++;
    return _detail(webRid, cookie);
  }

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
  }) async {
    reenteredCalls.add(reentered);
    lastStatus = guardStatus;
    final args = accountDetail.danmakuData as DouyinDanmakuArgs;
    lastDetailCookie = args.cookie;
    if (applyThrows) throw StateError('danmaku restart failed');
  }

  @override
  Future<void> applyYieldToGuest() async {
    yields++;
  }

  @override
  void applySuspended() {
    suspended++;
  }
}

void main() {
  group('claim 进场', () {
    test('首个 claim：enter 一次、applyAccountEnter、holder 为该 tab',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');

      final r = await gw.claim(a);

      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'A');
      expect(guard.enters, ['acct1@room_111']);
      expect(a.reenteredCalls, [false]);
      expect(a.lastStatus?['badgeActive'], isTrue);
      gw.stopHeartbeatForTesting();
    });

    test('已是 holder 重复 claim：不重复 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(guard.enters.length, 1);
      gw.stopHeartbeatForTesting();
    });

    test('抢占：B 进场成功后 A 被 yield，未发任何 exit', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      final r = await gw.claim(b);
      await Future<void>.value();

      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'B');
      expect(guard.enters, ['acct1@room_111', 'acct1@room_222']);
      expect(guard.exits, isEmpty);
      expect(b.reenteredCalls, [false]);
      expect(a.yields, 1);
      gw.stopHeartbeatForTesting();
    });

    test('账号详情失败：detailFailed=true，仲裁不变、旧 holder 未 yield',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222')..detailThrows = true;
      await gw.claim(a);
      final r = await gw.claim(b);

      expect(r.granted, isFalse);
      expect(r.reason, PresenceFailureReason.detailFailed);
      expect(gw.holderTabId, 'A');
      expect(guard.enters, ['acct1@room_111']);
      expect(a.yields, 0);
      expect(b.reenteredCalls, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('guard 未配置：enter 失败但非 detailFailed，仲裁不变', () async {
      final guard = FakeGuard()..detailGuardUnconfigured = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final r = await gw.claim(a);
      expect(r.granted, isFalse);
      expect(r.reason, PresenceFailureReason.enterFailed);
      expect(gw.holderTabId, isNull);
      gw.stopHeartbeatForTesting();
    });

    test('enterRoom 404：reregister 后重试成功', () async {
      final guard = FakeGuard()..enterThrowsOnce = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(guard.reregisters, [Constant.kDouyin]);
      expect(guard.enters, ['acct2@room_111']);
      gw.stopHeartbeatForTesting();
    });

    test('applyAccountEnter 抛错仍 granted：服务端已进场，仲裁/心跳为准',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111')..applyThrows = true;
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });
  });

  group('唯一心跳（fakeAsync）', () {
    test('抢占后只有新 holder 的房间被续租，旧 holder 不再有心跳', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final b = FakeTab('B', '222');

        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));
        expect(guard.beats, ['acct1@room_111', 'acct1@room_111']);

        gw.claim(b);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));

        expect(
          guard.beats,
          [
            'acct1@room_111',
            'acct1@room_111',
            'acct1@room_222',
            'acct1@room_222',
          ],
        );
        gw.stopHeartbeatForTesting();
      });
    });

    test('claim 失败后旧 holder 心跳恢复', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final b = FakeTab('B', '222')..detailThrows = true;

        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        final before = guard.beats.length;
        expect(before, 1);

        gw.claim(b);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));

        expect(gw.holderTabId, 'A');
        expect(guard.beats.length, before + 1, reason: 'A 的心跳应恢复');
        expect(guard.beats.last, 'acct1@room_111');
        gw.stopHeartbeatForTesting();
      });
    });

    test('心跳 404：reregister 后以新 accountId 续租', () {
      FakeAsync().run((async) {
        final guard = FakeGuard()
          ..heartbeatThrowOnce = DioException(
            requestOptions: RequestOptions(path: '/api/room/heartbeat'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/api/room/heartbeat'),
              statusCode: 404,
            ),
          );
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));
        expect(guard.reregisters, [Constant.kDouyin]);
        expect(guard.beats.last, 'acct2@room_111');
        gw.release('A');
        async.flushMicrotasks();
        expect(guard.exits, ['acct2@room_111'],
            reason: 'accountId 缓存必须随 reregister 同步');
        gw.stopHeartbeatForTesting();
      });
    });

    test('心跳 inRoom!=true：标记 suspended、停心跳、通知标签', () {
      FakeAsync().run((async) {
        final guard = FakeGuard()..inRoomFalseBeats = 1;
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        final beatsAfterSuspend = guard.beats.length;
        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats.length, beatsAfterSuspend, reason: '心跳必须停止');
        expect(gw.holderTabId, isNull);
        expect(a.suspended, 1);
        gw.stopHeartbeatForTesting();
      });
    });

    test('claim 在途时 release 同标签：排队到进场完成后 exit，无孤儿心跳',
        () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final b = FakeTab('B', '222');
        final gate = Completer<void>();
        guard.enterGate = gate;

        PresenceClaimResult? claimResult;
        var releaseDone = false;
        gw.claim(b).then((r) => claimResult = r);
        async.flushMicrotasks(); // claim 停在 enterRoom 闸门
        final releaseFuture = gw.release('B');
        releaseFuture.then((_) => releaseDone = true);
        async.flushMicrotasks(); // release 在串行链上排队
        expect(gw.holderTabId, isNull);
        expect(guard.enters, isEmpty);

        gate.complete();
        async.flushMicrotasks(); // claim 完成 → release 执行 exit

        expect(claimResult?.granted, isTrue);
        expect(releaseDone, isTrue);
        expect(gw.holderTabId, isNull);
        expect(gw.hasClaim('B'), isFalse);
        expect(guard.exits, ['acct1@room_222']);

        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats, isEmpty, reason: '已关闭标签不得留下心跳');
        gw.stopHeartbeatForTesting();
      });
    });

    test('claim 在途时标签已关闭：跳过 apply/心跳，排队 release 仍发 exit 收口',
        () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final b = FakeTab('B', '222');
        final gate = Completer<void>();
        guard.enterGate = gate;

        PresenceClaimResult? claimResult;
        var releaseDone = false;
        gw.claim(b).then((r) => claimResult = r);
        async.flushMicrotasks(); // claim 停在 enterRoom 闸门
        b.closed = true; // 模拟单关路径：控制器已 onClose，release 在链上排队
        final releaseFuture = gw.release('B');
        releaseFuture.then((_) => releaseDone = true);
        async.flushMicrotasks();

        gate.complete();
        async.flushMicrotasks(); // claim 完成（跳过 apply/心跳）→ release 执行 exit
        async.flushMicrotasks();

        expect(claimResult?.granted, isTrue);
        expect(releaseDone, isTrue);
        expect(b.reenteredCalls, isEmpty,
            reason: '已销毁标签不得 apply（不拉起弹幕连接）');
        expect(gw.holderTabId, isNull);
        expect(gw.hasClaim('B'), isFalse);
        expect(guard.exits, ['acct1@room_222'],
            reason: '服务端进场由排队的 release 发 exit 收口');

        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats, isEmpty, reason: '已关闭标签不得留下心跳');
        gw.stopHeartbeatForTesting();
      });
    });

    test('并发 claim 串行：B、C 先后在途，终态 C 为 holder 且心跳只打 C', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final b = FakeTab('B', '222');
        final c = FakeTab('C', '333');

        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));

        final gate = Completer<void>();
        guard.enterGate = gate;
        final fb = gw.claim(b);
        async.flushMicrotasks();
        final fc = gw.claim(c); // 排在 B 之后
        async.flushMicrotasks();
        expect(gw.holderTabId, 'A', reason: 'B 仍卡在闸门');

        gate.complete();
        async.flushMicrotasks(); // B 完成
        async.flushMicrotasks(); // C（gate 已完成）完成
        expect(fb.then((r) => r.granted), completion(isTrue));
        expect(fc.then((r) => r.granted), completion(isTrue));

        expect(
          guard.enters,
          ['acct1@room_111', 'acct1@room_222', 'acct1@room_333'],
        );
        expect(gw.holderTabId, 'C');
        expect(b.yields, 1, reason: 'B 被 C 让位');

        async.elapse(const Duration(milliseconds: 250));
        expect(
          guard.beats.where((s) => s.contains('room_222')),
          isEmpty,
          reason: '中间 claimant B 不得有任何心跳',
        );
        expect(guard.beats.last, 'acct1@room_333');
        gw.stopHeartbeatForTesting();
      });
    });
  });

  group('release / detach', () {
    test('release holder：先 exit 再让次新重新 enter 接管，reentered=true',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.release('B');

      expect(
        guard.events,
        ['enter:room_111', 'enter:room_222', 'exit:room_222', 'enter:room_111'],
        reason: '必须先 exit B 再 fallback enter A',
      );
      expect(guard.exits, ['acct1@room_222']);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      expect(a.reenteredCalls.last, isTrue);
      expect(a.lastDetailCookie, 'sessionid=abc');
      gw.stopHeartbeatForTesting();
    });

    test('release 非持有者：零 HTTP，holder 不变', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.release('A');

      expect(guard.exits, isEmpty);
      expect(guard.enters, isEmpty);
      expect(gw.holderTabId, 'B');
      gw.stopHeartbeatForTesting();
    });

    test('release 未知 tab：无动作', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      await gw.release('X');
      expect(guard.exits, isEmpty);
      expect(gw.holderTabId, isNull);
    });

    test('回退接管 enter 失败：holder 已迁移、心跳暂停（等写动作重试）',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a); // A 首次进场成功
      await gw.claim(b); // B 成为 holder，A 让位
      await Future<void>.value();
      a.detailThrows = true; // 此后回退 A 的重新进场失败

      await gw.release('B');

      expect(gw.holderTabId, 'A', reason: '仲裁已迁移到 A');
      expect(a.reenteredCalls, [false], reason: '回退失败不再 apply');
      gw.stopHeartbeatForTesting();
    });

    test('detach holder：不发 exit，次新接管', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.detach('B');

      expect(guard.exits, isEmpty);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });

    test('LocalPresenceClient 直连网关', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final client = LocalPresenceClient(gw, a);
      final r = await client.claim();
      expect(r.granted, isTrue);
      await client.release();
      expect(gw.holderTabId, isNull);
      gw.stopHeartbeatForTesting();
    });

    test('回退接管失败后写动作再 claim：完整重新进场并恢复心跳归属',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        heartbeatInterval: const Duration(milliseconds: 100),
      );
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      await Future<void>.value();
      a.detailThrows = true;
      await gw.release('B'); // 回退 A 失败：holder=A 但不 ready
      expect(gw.holderTabId, 'A');
      expect(a.reenteredCalls, [false], reason: '回退失败不 apply');

      a.detailThrows = false;
      final yieldsBeforeReclaim = a.yields;
      final r = await gw.claim(a); // 不得命中 holder 短路

      expect(r.granted, isTrue);
      expect(guard.enters.last, 'acct1@room_111', reason: '必须完整重进');
      expect(a.reenteredCalls, [false, false]);
      expect(a.yields, yieldsBeforeReclaim,
          reason: '自我重进不得对自己让位降级');
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });
  });

  group('batchRelease（批量关闭）', () {
    test('全关：只 exit 原 holder 一次、无 fallback；迟到的 release 全 no-op',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'A', 'B'});

      expect(guard.exits, ['acct1@room_222'], reason: '只退 holder B');
      expect(guard.enters, isEmpty, reason: '无幸存者，不回退');
      expect(gw.holderTabId, isNull);

      // 模拟各控制器 onClose 迟到的 release：未知 tab 零 HTTP
      await gw.release('A');
      await gw.release('B');
      expect(guard.exits.length, 1);
      expect(guard.enters, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('关闭其他：受害者含 holder，幸存者 A 只重新 enter 一次并接管', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      final c = FakeTab('C', '333');
      await gw.claim(a);
      await gw.claim(b);
      await gw.claim(c);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'B', 'C'});

      expect(guard.exits, ['acct1@room_333']);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      expect(a.reenteredCalls.last, isTrue);

      // 被销毁标签 onClose 的 release 不产生额外 HTTP
      await gw.release('B');
      await gw.release('C');
      expect(guard.exits.length, 1);
      expect(guard.enters.length, 1);
      gw.stopHeartbeatForTesting();
    });

    test('批内不含 holder：零 HTTP，holder 与心跳归属不变', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'A'});

      expect(guard.exits, isEmpty);
      expect(guard.enters, isEmpty);
      expect(gw.holderTabId, 'B');
      gw.stopHeartbeatForTesting();
    });

    test('空集合 / 全未知：no-op', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      await gw.batchRelease(<String>{});
      await gw.batchRelease({'X'});
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });
  });

  group('holder 写动作串行域', () {
    test('holder 发弹幕：走 guard.sendDanmaku，带 platform=douyin 与 extra',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'hello');

      expect(r.success, isTrue);
      expect(guard.sentDanmaku, ['hello']);
      gw.stopHeartbeatForTesting();
    });

    test('holder 点赞：走 guard.sendAction（无 platform 参数）', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendActionAsHolder(tabId: 'A', action: 'like');

      expect(r.success, isTrue);
      expect(guard.sentActions, ['like']);
      gw.stopHeartbeatForTesting();
    });

    test('非 holder：not_holder 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b); // B 持有，A 让位
      await Future<void>.value();

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'x');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotHolder);
      expect(guard.sentDanmaku, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('未知 tab：not_holder 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);

      final r = await gw.sendActionAsHolder(tabId: 'ZZ', action: 'like');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotHolder);
      expect(guard.sentActions, isEmpty);
    });

    test('holder+ready 但 accountId 缺失：not_login 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      gw.debugDropAccountId('A');

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'x');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotLogin);
      expect(guard.sentDanmaku, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('发弹幕 404：reregister 后重试一次成功', () async {
      final guard = FakeGuard()..sendDanmakuThrow404Once = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'hi');

      expect(r.success, isTrue);
      expect(guard.reregisters, [Constant.kDouyin]);
      expect(guard.sentDanmaku, ['hi']);
      gw.stopHeartbeatForTesting();
    });
  });
}
