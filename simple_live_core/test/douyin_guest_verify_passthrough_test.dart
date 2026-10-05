import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('getRoomDetail 游客验证信号透传', () {
    late DouyinSite site;

    setUp(() {
      site = DouyinSite();
      site.htmlFetcher = (webRid, cookie) async =>
          throw DouyinGuestVerifyRequired(webRid);
    });

    test('带 shareUrl 时不被直连兜底吞掉，原样上抛', () async {
      expect(
        site.getRoomDetail(
          roomId: '17334779490;https://live.douyin.com/17334779490',
        ),
        throwsA(isA<DouyinGuestVerifyRequired>()),
      );
    });

    test('无 shareUrl 时原样上抛', () async {
      expect(
        site.getRoomDetail(roomId: '17334779490'),
        throwsA(isA<DouyinGuestVerifyRequired>()),
      );
    });

    test('普通失败仍走 shareUrl 兜底（兜底契约不回归）', () async {
      var site2 = DouyinSite();
      site2.htmlFetcher = (webRid, cookie) async =>
          throw CoreError('取页失败');
      // shareUrl 解析出同一 webRid，但该路径不再带 shareUrl，最终上抛 CoreError
      expect(
        site2.getRoomDetail(
          roomId: '17334779490;https://live.douyin.com/17334779490',
        ),
        throwsA(isA<CoreError>()),
      );
    });
  });
}
