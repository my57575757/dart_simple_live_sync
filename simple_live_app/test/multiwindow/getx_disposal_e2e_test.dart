import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeGuard extends GuardServerService {
  int enters = 0;
  int exits = 0;

  @override
  bool get configured => true;

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String? webRid,
    Map<String, dynamic>? extra,
  }) async {
    enters++;
    return {'joined': false, 'starGuard': false};
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String? webRid,
    Map<String, dynamic>? extra,
  }) async {
    exits++;
  }
}

class _FakeTab implements DouyinPresenceTab {
  _FakeTab(this.id, this.webRid);
  final String id;
  final String webRid;
  bool closed = false;

  @override
  String get tabId => id;
  @override
  bool get isClosed => closed;
  @override
  String get guardRoomId => 'room_$webRid';
  @override
  String get guardWebRid => webRid;
  @override
  Map<String, dynamic> guardExtraArgs() => const {};

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async => LiveRoomDetail(
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
          cookie: '',
        ),
      );

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {}

  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {}

  @override
  Future<void> applyYieldToGuest() async {}

  @override
  Future<void> applySuspended() async {}
}

void main() {
  test('逐关两标签：网关摘栈、holder 归 null', () async {
    final guard = _FakeGuard();
    final gw = DouyinPresenceGateway(
      guard,
      heartbeatInterval: const Duration(milliseconds: 100),
    );
    addTearDown(gw.stopHeartbeatForTesting);

    final a = _FakeTab('A', '111');
    final b = _FakeTab('B', '222');
    await gw.claim(a);
    await gw.claim(b);
    expect(gw.holderTabId, 'B');

    await gw.release('A');
    expect(gw.isTrackedTab('A'), isFalse);
    expect(gw.holderTabId, 'B');

    await gw.release('B');
    expect(gw.isTrackedTab('B'), isFalse);
    expect(gw.holderTabId, isNull);
    expect(guard.exits, 1);
  });

  test('batchRelease：一次摘栈清空、holder 归 null、至多一次 exit', () async {
    final guard = _FakeGuard();
    final gw = DouyinPresenceGateway(
      guard,
      heartbeatInterval: const Duration(milliseconds: 100),
    );
    addTearDown(gw.stopHeartbeatForTesting);

    final a = _FakeTab('A', '111');
    final b = _FakeTab('B', '222');
    final c = _FakeTab('C', '333');
    await gw.claim(a);
    await gw.claim(b);
    await gw.claim(c);
    expect(gw.holderTabId, 'C');

    await gw.batchRelease({'A', 'B', 'C'});
    expect(gw.isTrackedTab('A'), isFalse);
    expect(gw.isTrackedTab('B'), isFalse);
    expect(gw.isTrackedTab('C'), isFalse);
    expect(gw.holderTabId, isNull);
    expect(guard.exits, 1);
    gw.stopHeartbeatForTesting();
  });

  test('关闭后心跳 Timer 停止无异常', () async {
    final guard = _FakeGuard();
    final gw = DouyinPresenceGateway(
      guard,
      heartbeatInterval: const Duration(milliseconds: 50),
    );
    addTearDown(gw.stopHeartbeatForTesting);

    final a = _FakeTab('A', '111');
    await gw.claim(a);
    gw.stopHeartbeatForTesting();
    await gw.release('A');
    expect(gw.holderTabId, isNull);
  });
}
