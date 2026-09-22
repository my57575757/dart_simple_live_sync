import 'package:simple_live_core/src/danmaku/douyin_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("buildChatUrl", () {
    var url = DouyinDanmaku.buildChatUrl(
      roomId: "7300000000000000000",
      content: "你好",
      webRid: "123abc",
    );
    test("基础地址", () {
      expect(
        url.startsWith("https://live.douyin.com/webcast/room/chat/?"),
        isTrue,
      );
    });
    test("包含必带参数", () {
      expect(url.contains("room_id=7300000000000000000"), isTrue);
      expect(url.contains("type=0"), isTrue);
      expect(url.contains("aid=6383"), isTrue);
      expect(url.contains("app_name=douyin_web"), isTrue);
    });
    test("内容做 URL 编码", () {
      expect(url.contains("content="), isTrue);
    });
  });
}
