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

  group("resolveSelfUid", () {
    test("页面同时含访客身份与 headerUserInfo 时取真实登录 uid", () async {
      var called = false;
      final d = DouyinDanmaku();
      d.htmlProvider = (webRid, cookie) async {
        called = true;
        expect(webRid, "123abc");
        expect(cookie, "sessionid=x");
        return r'... \"user_id\":\"1342966946862\",\"user_type\":12,'
            r'\"user_is_auth\":0,\"user_is_login\":1 ...'
            r'... \"headerUserInfo\":{\"isLogin\":true,\"info\":'
            r'{\"uid\":\"998877\",\"secUid\":\"MS4wLjA\",\"shortId\":\"1\"}} ...';
      };

      await d.resolveSelfUidForTesting(webRid: "123abc", cookie: "sessionid=x");

      expect(called, isTrue, reason: "应走 WebView provider 而非被风控的直连通道");
      expect(d.selfUidForTesting, "998877",
          reason: "user_type:12 的 user_id 是访客身份，真实账号 uid 在 headerUserInfo");
    });

    test("headerUserInfo 未登录时 uid 保持为空", () async {
      final d = DouyinDanmaku();
      d.htmlProvider = (webRid, cookie) async =>
          r'... \"headerUserInfo\":{\"isLogin\":false,\"info\":{}} ...';

      await d.resolveSelfUidForTesting(webRid: "123abc", cookie: "sessionid=x");

      expect(d.selfUidForTesting, isEmpty);
    });

    test("provider 返回验证码页时 uid 保持为空且不抛错", () async {
      final d = DouyinDanmaku();
      d.htmlProvider = (webRid, cookie) async => "<html>captcha</html>";

      await d.resolveSelfUidForTesting(webRid: "123abc", cookie: "sessionid=x");

      expect(d.selfUidForTesting, isEmpty);
    });

    test("provider 调用异常时 uid 保持为空且不抛错", () async {
      final d = DouyinDanmaku();
      d.htmlProvider = (webRid, cookie) async =>
          throw StateError("soft blocked");

      await d.resolveSelfUidForTesting(webRid: "123abc", cookie: "sessionid=x");

      expect(d.selfUidForTesting, isEmpty);
    });
  });
}
