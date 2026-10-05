import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('DouyinSite.parseRoomStateFromHtml', () {
    test('空页面抛 CoreError', () {
      expect(
        () => DouyinSite.parseRoomStateFromHtml(""),
        throwsA(isA<CoreError>()),
      );
    });

    test('被风控的非标准页面抛 CoreError', () {
      expect(
        () => DouyinSite.parseRoomStateFromHtml(
            '<!DOCTYPE html><html><body>验证</body></html>'),
        throwsA(isA<CoreError>()),
      );
    });

    test('合法转义页面解析出 state', () {
      var state = DouyinSite.parseRoomStateFromHtml(
        r'prefix {\"state\":{\"appStore\":{},\"roomStore\":{}}}]'
        '\\n suffix',
      );
      expect(state, isA<Map>());
      expect(state.containsKey('roomStore'), isTrue);
    });
  });

  group('DouyinSite.isRoomLiving', () {
    test('status=2 为直播中', () {
      expect(
        DouyinSite.isRoomLiving({
          'roomStore': {
            'roomInfo': {
              'room': {'status': 2}
            }
          }
        }),
        isTrue,
      );
    });

    test('status=4 为未直播', () {
      expect(
        DouyinSite.isRoomLiving({
          'roomStore': {
            'roomInfo': {
              'room': {'status': 4}
            }
          }
        }),
        isFalse,
      );
    });

    test('缺字段安全降级为未直播', () {
      expect(DouyinSite.isRoomLiving({}), isFalse);
    });
  });

  group('DouyinSite SSR 骨架占位房间（roomInfo 无 room 块）', () {
    final skeleton = <String, dynamic>{
      'roomStore': {
        'roomInfo': {'web_rid': '274889443828', 'web_stream_url': null}
      },
      'userStore': {
        'odin': {'user_unique_id': '7691511956330530313'}
      },
    };

    test('hasRoomInfo 对无 room 骨架为 false', () {
      expect(DouyinSite.hasRoomInfo(skeleton), isFalse);
    });

    test('buildOfflineDetail 不崩，按未开播返回', () {
      final detail = DouyinSite.buildOfflineDetail(
        webRid: '274889443828',
        state: skeleton,
        headers: {'cookie': 'c'},
      );
      expect(detail.status, isFalse);
      expect(detail.roomId, '274889443828');
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.webRid, '274889443828');
      expect(args.userId, '7691511956330530313');
    });

    test('无 user_unique_id 时不崩，userId 回退非空', () {
      final detail = DouyinSite.buildOfflineDetail(
        webRid: '274889443828',
        state: {
          'roomStore': {'roomInfo': {'web_rid': '274889443828'}}
        },
        headers: {},
      );
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.userId, isNotEmpty);
    });
  });

  group('DouyinSite 骨架 enter 兜底合成 HTML', () {
    test('合成 HTML 可解析并映射为直播中房间（不打外网）', () async {
      const webRid = '17334779490';
      final room = <String, dynamic>{
        'id_str': '7692964028268104482',
        'status': 2,
        'title': '测试直播',
        'room_view_stats': {'display_value': 17},
        'owner': {
          'id_str': '1300069316832828',
          'sec_uid': 'MS4wLjABAAAAsecuid',
          'nickname': '主播',
          'signature': '',
          'avatar_thumb': {
            'url_list': ['https://example.com/a.jpg']
          },
        },
        'cover': {
          'url_list': ['https://example.com/c.jpg']
        },
        'stream_url': {
          'flv_pull_url': {'HD1': 'http://example.com/live.flv'},
        },
      };
      final state = <String, dynamic>{
        'appStore': <String, dynamic>{},
        'roomStore': {
          'roomInfo': {
            'room': room,
            'anchor': room['owner'],
          },
        },
        'userStore': {
          'odin': {'user_unique_id': '7693012705920124459'},
        },
      };
      // 复刻 guard buildSyntheticStateHtml：JSON 双层转义后追加 ]\n
      final synthetic =
          jsonEncode({'state': state})
                  .replaceAll('\\', '\\\\')
                  .replaceAll('"', '\\"') +
              ']\\n';

      // 合成 HTML 必须先被 parseRoomStateFromHtml 的正则命中
      expect(
        RegExp(r'\{\\"state\\":\{\\"appStore.*?\]\\n', dotAll: true)
            .hasMatch(synthetic),
        isTrue,
      );

      final site = DouyinSite();
      site.htmlFetcher = (rid, cookie) async => synthetic;

      final detail = await site.getRoomDetail(
        roomId: '$webRid;',
        asAccount: false,
      );
      expect(detail.status, isTrue);
      expect(detail.roomId, webRid);
      expect(detail.title, '测试直播');
      expect(detail.userName, '主播');
      expect(detail.userAvatar, 'https://example.com/a.jpg');
      expect(detail.online, 17);
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.webRid, webRid);
      expect(args.roomId, '7692964028268104482');
      expect(args.userId, '7693012705920124459');
    });
  });
}
