import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

/// 模拟房间页 SSR 片段（\" 转义形式，结尾 ] + 字面 \n）
String roomHtml(int status) =>
    r'x {\"state\":{\"appStore\":{},\"roomStore\":{\"roomInfo\":{\"room\":{\"status\":'
    '$status'
    r'}}}}}]'
    '\\n y';

void main() {
  group('DouyinSite.htmlFetcher 注入', () {
    late DouyinSite site;

    setUp(() {
      site = DouyinSite();
    });

    test('默认未注入时为 null（回退 Dio 契约）', () {
      expect(site.htmlFetcher, isNull);
    });

    test('注入后 getLiveStatus 走 fetcher：status=2 为直播中', () async {
      String? gotWebRid;
      String? gotCookie;
      site.htmlFetcher = (webRid, cookie) async {
        gotWebRid = webRid;
        gotCookie = cookie;
        return roomHtml(2);
      };
      site.cookie = 'a=b';

      expect(await site.getLiveStatus(roomId: '12345678901'), isTrue);
      expect(gotWebRid, '12345678901');
      expect(gotCookie, 'a=b');
    });

    test('status=4 为未直播', () async {
      site.htmlFetcher = (webRid, cookie) async => roomHtml(4);
      expect(await site.getLiveStatus(roomId: '12345678901'), isFalse);
    });

    test('fetcher 抛错时原样上抛', () async {
      site.htmlFetcher = (webRid, cookie) async =>
          throw CoreError('fetcher 失败');
      expect(
        site.getLiveStatus(roomId: '12345678901'),
        throwsA(isA<CoreError>()),
      );
    });
  });
}
