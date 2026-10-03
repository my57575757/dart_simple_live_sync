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
}
