import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/follow_service.dart';

FollowUser makeUser(String id, {int status = 0}) {
  final user = FollowUser(
    id: id,
    roomId: id,
    siteId: 'douyin',
    userName: id,
    face: '',
    addTime: DateTime(2026),
  );
  user.liveStatus.value = status;
  return user;
}

void main() {
  late FollowService follow;

  setUp(() {
    follow = FollowService();
  });

  group('关注列表更新通知', () {
    test('一轮结束即使无状态变化：也重排一次，直播中置顶', () async {
      final a = makeUser('a', status: 1);
      final b = makeUser('b', status: 2);
      follow.followList.assignAll([a, b]);

      var events = 0;
      final sub = follow.updatedListStream.listen((_) => events++);
      addTearDown(sub.cancel);

      follow.settleItemForTesting(a, changed: false);
      follow.settleItemForTesting(b, changed: false);
      await Future.delayed(Duration.zero);

      expect(events, 1);
      expect(follow.followList.map((e) => e.id), ['b', 'a']);
      expect(follow.updating.value, false);
    });

    test('状态变化后短防抖：窗口内不通知，超时合并为一次', () {
      fakeAsync((async) {
        final a = makeUser('a', status: 1);
        final b = makeUser('b', status: 1);
        final c = makeUser('c', status: 1);
        follow.followList.assignAll([a, b, c]);

        var events = 0;
        final sub = follow.updatedListStream.listen((_) => events++);
        addTearDown(sub.cancel);

        follow.settleItemForTesting(a, changed: true);
        follow.settleItemForTesting(b, changed: true);

        async.elapse(const Duration(milliseconds: 400));
        expect(events, 0, reason: '防抖窗口内不应通知');

        async.elapse(const Duration(milliseconds: 500));
        expect(events, 1, reason: '窗口内多次变化应合并为一次通知');
      });
    });

    test('一轮全部结束时立即刷新，不等防抖窗口', () async {
      final a = makeUser('a', status: 1);
      final b = makeUser('b', status: 1);
      follow.followList.assignAll([a, b]);

      var events = 0;
      final sub = follow.updatedListStream.listen((_) => events++);
      addTearDown(sub.cancel);

      follow.settleItemForTesting(a, changed: true);
      expect(events, 0);

      follow.settleItemForTesting(b, changed: true);
      // 广播流事件经微任务投递；flush 后应已通知（若误走防抖定时器则仍为 0）
      await Future.delayed(Duration.zero);
      expect(events, 1, reason: '本轮结束应立即通知');
    });
  });

  group('查询失败保留位置', () {
    test('已有上轮状态：失败时保留旧状态与开播时间，不挪位置', () {
      final user = makeUser('a', status: 2);
      user.liveStartTime = '123456';

      follow.applyTransientFailureForTesting(user);

      expect(user.liveStatus.value, 2);
      expect(user.liveStartTime, '123456');
    });

    test('首次查询（未知）：失败保持 0，开播时间清空', () {
      final user = makeUser('a', status: 0);
      user.liveStartTime = '123456';

      follow.applyTransientFailureForTesting(user);

      expect(user.liveStatus.value, 0);
      expect(user.liveStartTime, isNull);
    });
  });
}
