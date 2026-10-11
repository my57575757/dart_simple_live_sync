import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_controller.dart';

String pageInfo({
  String ready = "complete",
  String title = "主播的直播间",
  String path = "/30000000000",
  bool hasRoom = true,
  int bodyLen = 100,
  bool hasCaptcha = false,
}) {
  return jsonEncode({
    "ready": ready,
    "title": title,
    "path": path,
    "hasRoom": hasRoom,
    "bodyLen": bodyLen,
    "hasCaptcha": hasCaptcha,
  });
}

void main() {
  const webRid = "30000000000";

  test("开播房间：房间数据已渲染、无验证码，判定完成", () {
    final result = pageInfo();
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isTrue);
  });

  test("未开播房间：有房间数据标记、正文较短，仍判定完成", () {
    final result = pageInfo(bodyLen: 30);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isTrue);
  });

  test("验证码中间页：title 命中，判定未完成", () {
    final result = pageInfo(title: "验证码中间页");
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("验证码控件仍在：hasCaptcha=true，判定未完成", () {
    final result = pageInfo(hasCaptcha: true);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("路径不匹配：判定未完成", () {
    final result = pageInfo(path: "/other");
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("结果为空：判定未完成", () {
    expect(DouyinGuestVerifyController.parseVerified(null, webRid), isFalse);
  });

  test("白屏：document 仍在加载（readyState 非 complete），判定未完成", () {
    final result = pageInfo(ready: "interactive", bodyLen: 0, hasRoom: false);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("白屏：加载结束但无房间数据标记且正文为空，判定未完成", () {
    final result = pageInfo(ready: "complete", bodyLen: 0, hasRoom: false);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("非房间页（有杂散文本但无房间标记）：判定未完成", () {
    final result = pageInfo(hasRoom: false, bodyLen: 80);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("损坏 JSON：判定未完成而非抛异常", () {
    expect(
      DouyinGuestVerifyController.parseVerified("{not json", webRid),
      isFalse,
    );
  });

  group("isBlankPage", () {
    test("readyState 非 complete 视为空白", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(
          jsonDecode(pageInfo(ready: "loading")) as Map<String, dynamic>,
        ),
        isTrue,
      );
    });

    test("有房间数据标记（RENDER_DATA 等）即非空白，与正文长度无关", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(
          jsonDecode(pageInfo(hasRoom: true, bodyLen: 0))
              as Map<String, dynamic>,
        ),
        isFalse,
      );
    });

    test("complete 且无房间标记、正文过短视为空白", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(
          jsonDecode(pageInfo(hasRoom: false, bodyLen: 5))
              as Map<String, dynamic>,
        ),
        isTrue,
      );
    });
  });

  test("probeScript 读取完成判据所需的全部字段", () {
    const script = DouyinGuestVerifyController.probeScript;
    expect(script, contains("readyState"));
    expect(script, contains("RENDER_DATA"));
    expect(script, contains("bodyLen"));
    expect(script, contains("hasCaptcha"));
  });

  group("buildSettings 桌面标识", () {
    final controller = DouyinGuestVerifyController();

    test("UA 固定为 Windows Chrome，避免移动端下发移动验证页", () {
      final settings = controller.buildSettings();
      expect(settings.userAgent, isNotNull);
      expect(settings.userAgent!, contains("Windows NT 10.0"));
      expect(settings.userAgent!, isNot(contains("Android")));
      expect(settings.userAgent!, isNot(contains("Mobile")));
    });

    test("请求桌面版内容模式", () {
      final settings = controller.buildSettings();
      expect(settings.preferredContentMode, UserPreferredContentMode.DESKTOP);
    });
  });
}
