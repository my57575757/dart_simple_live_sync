import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';

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

  test('InMemoryDBService：子窗内关注写操作只在本窗生效，不触碰 Hive', () async {
    final db = InMemoryDBService();
    await db.addFollow(FollowUser(
      id: 'bili_9',
      roomId: '9',
      siteId: 'bili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://9',
    ));
    expect(db.getFollowExist('bili_9'), isTrue);
    await db.deleteFollow('bili_9');
    expect(db.getFollowExist('bili_9'), isFalse);
    // 历史写入内存不报错、不持久化
    await db.addOrUpdateVolume('huya_r', 12.5);
    expect(db.getVolume('huya_r'), 12.5);
  });
}
