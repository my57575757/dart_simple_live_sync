import 'dart:convert';

import 'package:simple_live_core/src/danmaku/twitch_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("sanitizeIrcMessage", () {
    test("CRLF 替换为空格", () {
      expect(TwitchDanmaku.sanitizeIrcMessage("hello\r\nworld"), "hello  world");
    });
    test("多行粘贴全部净化", () {
      expect(TwitchDanmaku.sanitizeIrcMessage("a\rb\nc"), "a b c");
    });
    test("NUL 替换为空格", () {
      expect(TwitchDanmaku.sanitizeIrcMessage("a\x00b"), "a b");
    });
    test("普通文本不变", () {
      expect(TwitchDanmaku.sanitizeIrcMessage("just chatting"), "just chatting");
    });
  });

  group("truncateIrcMessage", () {
    test("短文本不截断", () {
      expect(TwitchDanmaku.truncateIrcMessage("abc"), "abc");
    });
    test("ASCII 超长截断到 450 字节", () {
      var result = TwitchDanmaku.truncateIrcMessage("a" * 500);
      expect(utf8.encode(result).length, 450);
      expect(result.length, 450);
    });
    test("中文按码元安全截断", () {
      var result = TwitchDanmaku.truncateIrcMessage("中" * 200);
      expect(utf8.encode(result).length <= 450, isTrue);
      expect(result, "中" * 150);
    });
    test("4 字节 emoji 不切坏代理对", () {
      var result = TwitchDanmaku.truncateIrcMessage("😀" * 200);
      expect(utf8.encode(result).length <= 450, isTrue);
      expect(result, "😀" * 112);
    });
  });

  group("sendMessage", () {
    test("未 start 直接发送返回 network_error 且不本地补显", () async {
      var result = await TwitchDanmaku().sendMessage("hello");
      expect(result.success, isFalse);
      expect(result.errorCode, "network_error");
      expect(result.needLocalEcho, isFalse);
    });
    test("已关闭连接返回 network_error", () async {
      var danmaku = TwitchDanmaku();
      await danmaku.stop();
      var result = await danmaku.sendMessage("hello");
      expect(result.success, isFalse);
      expect(result.errorCode, "network_error");
      expect(result.needLocalEcho, isFalse);
    });
  });
}
