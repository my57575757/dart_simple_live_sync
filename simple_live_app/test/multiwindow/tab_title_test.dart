import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_strip.dart';

void main() {
  group('resolveTabTitle', () {
    test('已关注且有关注名：始终用关注名（即使实时名不同）', () {
      expect(
        resolveTabTitle(
          followed: true,
          followedUserName: '关注时的名字',
          realtimeUserName: '主播改后的新名字',
          roomTitle: '直播间标题',
          fallback: 'r1',
        ),
        '关注时的名字',
      );
    });

    test('未关注：用实时主播名', () {
      expect(
        resolveTabTitle(
          followed: false,
          followedUserName: '不应出现',
          realtimeUserName: '实时主播名',
          roomTitle: '直播间标题',
          fallback: 'r1',
        ),
        '实时主播名',
      );
    });

    test('已关注但关注名为空：回退实时主播名', () {
      expect(
        resolveTabTitle(
          followed: true,
          followedUserName: '',
          realtimeUserName: '实时主播名',
          roomTitle: '直播间标题',
          fallback: 'r1',
        ),
        '实时主播名',
      );
      expect(
        resolveTabTitle(
          followed: true,
          followedUserName: null,
          realtimeUserName: '实时主播名',
          roomTitle: '直播间标题',
          fallback: 'r1',
        ),
        '实时主播名',
      );
    });

    test('实时名为空：回退直播间标题', () {
      expect(
        resolveTabTitle(
          followed: false,
          followedUserName: null,
          realtimeUserName: '',
          roomTitle: '直播间标题',
          fallback: 'r1',
        ),
        '直播间标题',
      );
    });

    test('详情未加载（均为 null）：回退描述符标题', () {
      expect(
        resolveTabTitle(
          followed: false,
          followedUserName: null,
          realtimeUserName: null,
          roomTitle: null,
          fallback: 'r1',
        ),
        'r1',
      );
    });

    test('直播间标题也为空：回退描述符标题', () {
      expect(
        resolveTabTitle(
          followed: false,
          followedUserName: null,
          realtimeUserName: '',
          roomTitle: '',
          fallback: 'r1',
        ),
        'r1',
      );
    });
  });
}
