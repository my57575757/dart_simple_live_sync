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
}
