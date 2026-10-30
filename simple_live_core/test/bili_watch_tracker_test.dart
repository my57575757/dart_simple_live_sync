import 'dart:math';

import 'package:fake_async/fake_async.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

class RoomHttp implements BiliWatchHttp {
  RoomHttp({
    this.enterResponse,
    this.heartbeatResponse,
    this.enterFailCount = 0,
    this.throwOnPost = false,
  });

  BiliWatchResponse? enterResponse;
  BiliWatchResponse? heartbeatResponse;
  int enterFailCount;
  bool throwOnPost;
  BiliRoomInfo? roomOverride;
  BiliWatchResponse? failOnceThen;
  bool _failConsumed = false;

  final baseInfoCalls = <int>[];
  final enters = <Map<String, dynamic>>[];
  final beats = <Map<String, dynamic>>[];

  @override
  Future<BiliRoomInfo> getRoomBaseInfo(int roomId) async {
    baseInfoCalls.add(roomId);
    if (roomId == 6060) {
      return roomOverride ??
          (throw StateError('6060 需要 roomOverride'));
    }
    return const BiliRoomInfo(
      roomId: 5050,
      parentAreaId: 6,
      areaId: 236,
      ruid: 433351,
    );
  }

  @override
  Future<BiliWatchResponse> postEnterRoom(Map<String, dynamic> params) async {
    enters.add(Map<String, dynamic>.from(params));
    if (enterFailCount-- > 0) {
      return const BiliWatchResponse(code: 500);
    }
    return enterResponse ?? const BiliWatchResponse(code: 500);
  }

  @override
  Future<BiliWatchResponse> postHeartBeat(
      Map<String, dynamic> params) async {
    beats.add(Map<String, dynamic>.from(params));
    if (throwOnPost) throw StateError('network down');
    if (failOnceThen != null && !_failConsumed) {
      _failConsumed = true;
      return const BiliWatchResponse(code: 1012002);
    }
    return heartbeatResponse ??
        const BiliWatchResponse(code: 0, timestamp: 9999);
  }
}

BiliWatchTracker buildTracker(
  RoomHttp http, {
  DateTime? base,
  required DateTime Function() now,
  Random? random,
  void Function(int reason)? onFail,
  List<String>? signLog,
}) {
  return BiliWatchTracker(
    http: http,
    buvid: 'AUTO3317901687841255',
    deviceId: 'bfcdd5fb-649f-4057-bc46-4e32bc0dfee4',
    userAgent: 'UA',
    now: now,
    random: random,
    onFail: onFail,
    sign: (reportJson, rule) {
      signLog?.add(reportJson);
      return 'sgn-${rule.join('-')}';
    },
  );
}

void main() {
  const enterOk = BiliWatchResponse(
    code: 0,
    heartbeatInterval: 60,
    secretKey: 'seacasdgyijfhofiuxoannn',
    secretRule: [2, 5, 1, 4],
    timestamp: 1000,
  );

  test('E 成功：seq 从 0 起，参数无 s；60s 后首个 X seq=1', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final http = RoomHttp(
        enterResponse: enterOk,
        heartbeatResponse:
            const BiliWatchResponse(code: 0, timestamp: 1060),
      );
      final signLog = <String>[];
      final tracker =
          buildTracker(http, now: now, random: Random(0), signLog: signLog);

      expect(await tracker.start(5050), isTrue);

      expect(http.baseInfoCalls, [5050]);
      expect(http.enters, hasLength(1));
      final e = http.enters.single;
      expect(e['id'], '[6,236,0,5050]');
      expect(e['device'],
          '["AUTO3317901687841255","bfcdd5fb-649f-4057-bc46-4e32bc0dfee4"]');
      expect(e['ruid'], 433351);
      expect(e['is_patch'], 0);
      expect(e['heart_beat'], '[]');
      expect(e.containsKey('s'), isFalse);

      self.elapse(const Duration(seconds: 50));
      self.flushMicrotasks();
      expect(http.beats, isEmpty);

      self.elapse(const Duration(seconds: 10));
      self.flushMicrotasks();
      expect(http.beats, hasLength(1));
      final x = http.beats.single;
      expect(x['id'], '[6,236,1,5050]');
      expect(x['ets'], 1000);
      expect(x['benchmark'], 'seacasdgyijfhofiuxoannn');
      expect(x['time'], 60);
      expect(x['trackid'], '-999998');
      expect(x['s'], 'sgn-2-5-1-4');
      expect(signLog.single, contains('"id":"[6,236,1,5050]"'));
      tracker.dispose();
    });
  });

  test('X 响应无 timestamp：下一轮 ets 按 interval 本地递推', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final http = RoomHttp(
        enterResponse: enterOk,
        heartbeatResponse: const BiliWatchResponse(code: 0),
      );
      final tracker = buildTracker(http, now: now, random: Random(0));

      await tracker.start(5050);
      self.elapse(const Duration(seconds: 60));
      self.flushMicrotasks();
      self.elapse(const Duration(seconds: 60));
      self.flushMicrotasks();

      expect(http.beats, hasLength(2));
      expect(http.beats[0]['ets'], 1000);
      expect(http.beats[1]['ets'], 1060);
      tracker.dispose();
    });
  });

  test('stop：防抖窗口结束后按实际观看秒数补发最后一个 X，随后销毁会话',
      () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final http = RoomHttp(
        enterResponse: enterOk,
        heartbeatResponse:
            const BiliWatchResponse(code: 0, timestamp: 2000),
      );
      final tracker = buildTracker(http, now: now, random: Random(0));
      final expectedDelayMs = 1000 * (Random(0).nextInt(51) + 10);

      await tracker.start(5050);
      self.elapse(const Duration(seconds: 30));
      tracker.stop(5050);

      self.elapse(Duration(milliseconds: expectedDelayMs - 1));
      self.flushMicrotasks();
      expect(http.beats, isEmpty);

      self.elapse(const Duration(milliseconds: 1));
      self.flushMicrotasks();
      expect(http.beats, hasLength(1));
      final rawWatch = (30000 + expectedDelayMs) / 1000;
      final stopWatchSeconds = rawWatch.ceil().clamp(0, 60);
      expect(http.beats.single['time'], stopWatchSeconds);
      expect(http.beats.single['id'], '[6,236,1,5050]');

      // 会话已销毁：之后不再有周期心跳
      self.elapse(const Duration(minutes: 5));
      self.flushMicrotasks();
      expect(http.beats, hasLength(1));
      tracker.dispose();
    });
  });

  test('防抖窗口内重新进入同一房间：取消补发、不重发 E，会话延续', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final http = RoomHttp(
        enterResponse: enterOk,
        heartbeatResponse:
            const BiliWatchResponse(code: 0, timestamp: 2000),
      );
      final tracker = buildTracker(http, now: now, random: Random(0));
      final expectedDelayMs = 1000 * (Random(0).nextInt(51) + 10);

      await tracker.start(5050);
      self.elapse(const Duration(seconds: 30));
      tracker.stop(5050);
      self.elapse(Duration(milliseconds: expectedDelayMs - 1000));
      expect(await tracker.start(5050), isTrue);

      // 防抖点过后没有补发
      self.elapse(const Duration(minutes: 2));
      self.flushMicrotasks();
      expect(http.enters, hasLength(1));
      // 会话延续：没有重新 E，节拍照常，seq 从 1 连续递增
      expect(http.beats.map((e) => e['id']), [
        '[6,236,1,5050]',
        '[6,236,2,5050]',
      ]);
      tracker.dispose();
    });
  });

  test('切房间：旧房间防抖补发与新房间 E/X 互不串话', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final http = RoomHttp(
        enterResponse: enterOk,
        heartbeatResponse:
            const BiliWatchResponse(code: 0, timestamp: 2000),
      );
      // 第二个房间用不同的 ruid
      http.roomOverride = const BiliRoomInfo(
        roomId: 6060,
        parentAreaId: 2,
        areaId: 654,
        ruid: 27598077,
      );
      final tracker = buildTracker(http, now: now, random: Random(0));
      final expectedDelayMs = 1000 * (Random(0).nextInt(51) + 10);

      await tracker.start(5050);
      self.elapse(const Duration(seconds: 30));
      tracker.stop(5050);
      await tracker.start(6060);

      expect(http.enters.map((e) => e['id']), [
        '[6,236,0,5050]',
        '[2,654,0,6060]',
      ]);

      self.elapse(Duration(milliseconds: expectedDelayMs));
      self.flushMicrotasks();
      // 旧房间补发携带旧房间字段
      final stopBeat = http.beats.firstWhere((e) => e['ruid'] == 433351);
      expect(stopBeat['id'], '[6,236,1,5050]');

      self.elapse(const Duration(seconds: 60));
      self.flushMicrotasks();
      final newRoomBeat = http.beats.firstWhere((e) => e['ruid'] == 27598077);
      expect(newRoomBeat['id'], '[2,654,1,6060]');
      tracker.dispose();
    });
  });

  test('X 返回可容忍错误码：onFail(11) 且当拍立即重试一次', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final fails = <int>[];
      final http = RoomHttp(
        enterResponse: enterOk,
        throwOnPost: false,
      );
      http.heartbeatResponse = null;
      http.failOnceThen = const BiliWatchResponse(code: 0, timestamp: 1060);
      final tracker =
          buildTracker(http, now: now, random: Random(0), onFail: fails.add);

      await tracker.start(5050);
      self.elapse(const Duration(seconds: 60));
      self.flushMicrotasks();

      expect(http.beats, hasLength(2));
      expect(fails, [11]);
      tracker.dispose();
    });
  });

  test('E 最多重试 3 次；全部失败时 onFail(10) 且不启动节拍', () {
    fakeAsync((self) async {
      final base = DateTime(2026);
      DateTime now() => base.add(self.elapsed);
      final fails = <int>[];
      final http = RoomHttp();
      final tracker =
          buildTracker(http, now: now, random: Random(0), onFail: fails.add);

      expect(await tracker.start(5050), isFalse);
      expect(http.enters, hasLength(3));
      expect(fails, [10]);

      self.elapse(const Duration(minutes: 5));
      self.flushMicrotasks();
      expect(http.beats, isEmpty);
      tracker.dispose();
    });
  });
}
