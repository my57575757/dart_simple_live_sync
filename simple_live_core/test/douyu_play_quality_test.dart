import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  test('斗鱼画质列表与播放地址随画质切换（房间 24422）', () async {
    final site = DouyuSite();
    final detail = await site.getRoomDetail(roomId: '24422');
    expect(detail.status, isTrue, reason: '房间应处于直播状态');

    final qualities = await site.getPlayQualites(detail: detail);
    final rates = qualities
        .map((q) => (q.data as DouyuPlayData).rate)
        .toList();
    expect(rates, containsAll([4, 3, 2]));

    // 超清（rate=3）走完整线路解析：三条线路都必须是 _2000 码率
    final quality = qualities.firstWhere(
      (q) => (q.data as DouyuPlayData).rate == 3,
    );
    final playUrl = await site.getPlayUrls(detail: detail, quality: quality);
    expect(playUrl.urls, isNotEmpty);
    for (final url in playUrl.urls) {
      expect(
        url.contains('_2000'),
        isTrue,
        reason: 'rate=3 应返回 _2000，实际：$url',
      );
    }
  }, timeout: const Timeout(Duration(seconds: 60)));
}
