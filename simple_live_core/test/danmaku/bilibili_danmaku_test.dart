import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("getCsrf", () {
    test("正常提取 bili_jct", () {
      expect(
        BiliBiliDanmaku.getCsrf("SESSDATA=abc; bili_jct=csrf123; foo=bar"),
        "csrf123",
      );
    });
    test("bili_jct 在末尾", () {
      expect(BiliBiliDanmaku.getCsrf("SESSDATA=a;bili_jct=xyz"), "xyz");
    });
    test("缺失返回空串", () {
      expect(BiliBiliDanmaku.getCsrf("SESSDATA=a"), "");
    });
    test("空 cookie 返回空串", () {
      expect(BiliBiliDanmaku.getCsrf(""), "");
    });
  });
}
