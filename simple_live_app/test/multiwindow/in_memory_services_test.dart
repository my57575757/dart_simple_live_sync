import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';

class _RecordingDataPort implements SubDataPlanePort {
  final List<(String, Object?)> calls = [];
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    return null;
  }
}

void main() {
  test('InMemoryLocalStorageService：快照播种后设置与屏蔽词可读', () {
    final storage = InMemoryLocalStorageService();
    storage.applySnapshot(const WindowSnapshot(
      settings: {'kThemeMode': 2, 'kDanmuEnable': false, 'kName': '弹幕'},
      shield: ['垃圾词', 'bad'],
    ));

    expect(storage.getValue('kThemeMode', 0), 2);
    expect(storage.getValue('kDanmuEnable', true), false);
    expect(storage.getValue('kName', ''), '弹幕');
    expect(storage.getValue('kMissing', '默认'), '默认');
    expect(storage.shieldBox.values.toSet(), {'垃圾词', 'bad'});
  });

  test('InMemoryDBService：音量/关注快照、默认音量、空关注列表', () {
    final db = InMemoryDBService();
    db.applySnapshot(const WindowSnapshot(
      volumes: {'douyin_1': 33.0},
      followShareUrls: {'douyin_1': 'http://x', 'douyin_2': ''},
    ));

    expect(db.getVolume('douyin_1'), 33.0);
    expect(db.getVolume('unknown'), 70);
    expect(db.getFollowExist('douyin_1'), isTrue);
    expect(db.getFollowExist('douyin_2'), isTrue, reason: '空 shareUrl 也代表已关注');
    expect(db.getFollowExist('douyin_3'), isFalse);
    expect(db.getFollowShareUrl('douyin_1'), 'http://x');
    expect(db.getFollowShareUrl('douyin_2'), '');
    expect(db.getFollowList(), isEmpty, reason: '子窗不承载完整关注对象');
  });

  test('InMemoryDBService：关注/音量/历史写本地且写穿主窗；无 port 纯内存',
      () async {
    final port = _RecordingDataPort();
    final db = InMemoryDBService(dataPort: port);
    await db.addFollow(FollowUser(
      id: 'bilibili_9',
      roomId: '9',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://9',
    ));
    expect(db.getFollowExist('bilibili_9'), isTrue);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mFollowSet), isTrue);

    await db.deleteFollow('bilibili_9');
    expect(db.getFollowExist('bilibili_9'), isFalse);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mFollowRemove), isTrue);

    await db.addOrUpdateVolume('huya_r', 12.5);
    expect(db.getVolume('huya_r'), 12.5);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mVolumeSet), isTrue);

    await db.addOrUpdateHistory(History(
      id: 'huya_r',
      roomId: 'r',
      siteId: 'huya',
      userName: 'u',
      face: '',
      updateTime: DateTime(2026),
    ));
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mHistoryAdd), isTrue);

    // 无 port 时纯内存不报错
    final dbOffline = InMemoryDBService();
    await dbOffline.addFollow(FollowUser(
      id: 'bilibili_1',
      roomId: '1',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
    ));
    expect(dbOffline.getFollowExist('bilibili_1'), isTrue);
  });
}
