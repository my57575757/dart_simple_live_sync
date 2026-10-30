import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/bili_watch_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _NoHttp implements BiliWatchHttp {
  @override
  Future<BiliRoomInfo> getRoomBaseInfo(int roomId) =>
      throw UnimplementedError();

  @override
  Future<BiliWatchResponse> postEnterRoom(Map<String, dynamic> params) =>
      throw UnimplementedError();

  @override
  Future<BiliWatchResponse> postHeartBeat(Map<String, dynamic> params) =>
      throw UnimplementedError();
}

class _RecordingTracker extends BiliWatchTracker {
  _RecordingTracker()
      : super(http: _NoHttp(), sign: (_, __) => '', buvid: 'b', userAgent: 'ua');

  final List<int> starts = [];
  final List<int> stops = [];

  @override
  Future<bool> start(int roomId) async {
    starts.add(roomId);
    return true;
  }

  @override
  void stop(int roomId) {
    stops.add(roomId);
  }
}

void main() {
  test('tracker 构建未就绪时的 stop 不丢失：就绪后 start/stop 按序送达',
      () async {
    final completer = Completer<BiliWatchTracker?>();
    final tracker = _RecordingTracker();
    final service = BiliWatchService(
      trackerBuilder: () => completer.future,
    );

    // 模拟进房后立刻切走：tracker 仍在异步加载 wasm。
    // start、stop 只入链不 await——它们都要等 tracker 就绪，await 会自锁。
    unawaited(service.start(5050));
    await Future<void>.delayed(Duration.zero);
    unawaited(service.stop(5050));

    // 加载在此刻才完成；用第三个 stop 排空串行链，确认此前两个调用都已送达
    completer.complete(tracker);
    await service.stop(5050);

    expect(tracker.starts, [5050]);
    expect(tracker.stops, [5050, 5050]);
  });
}
