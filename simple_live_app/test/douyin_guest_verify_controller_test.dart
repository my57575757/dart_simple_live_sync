import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_controller.dart';

String pageInfo({
  String ready = "complete",
  String title = "主播的直播间",
  String path = "/30000000000",
  int bodyLen = 100,
  bool hasCaptcha = false,
}) {
  return jsonEncode({
    "ready": ready,
    "title": title,
    "path": path,
    "bodyLen": bodyLen,
    "hasCaptcha": hasCaptcha,
  });
}

void main() {
  const webRid = "30000000000";

  test("开播房间：文档加载完、正文充足、无验证码，判定完成", () {
    final result = pageInfo();
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isTrue);
  });

  test("未开播房间：无视频/房间节点但有未开播提示文案，仍判定完成", () {
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
    final result = pageInfo(ready: "interactive", bodyLen: 0);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("白屏：加载结束但正文为空壳，判定未完成", () {
    final result = pageInfo(ready: "complete", bodyLen: 0);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isFalse);
  });

  test("正文长度边界：低于阈值判白屏，达到阈值判完成", () {
    expect(
      DouyinGuestVerifyController.parseVerified(pageInfo(bodyLen: 19), webRid),
      isFalse,
    );
    expect(
      DouyinGuestVerifyController.parseVerified(pageInfo(bodyLen: 20), webRid),
      isTrue,
    );
  });

  test("损坏 JSON：判定未完成而非抛异常", () {
    expect(
      DouyinGuestVerifyController.parseVerified("{not json", webRid),
      isFalse,
    );
  });

  group("isBlankPage", () {
    Map<String, dynamic> infoOf({String ready = "complete", int bodyLen = 100}) {
      return jsonDecode(pageInfo(ready: ready, bodyLen: bodyLen))
          as Map<String, dynamic>;
    }

    test("readyState 非 complete 视为空白", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(infoOf(ready: "loading")),
        isTrue,
      );
    });

    test("complete 且正文达到阈值即非空白（不依赖房间 DOM 节点）", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(infoOf(bodyLen: 20)),
        isFalse,
      );
    });

    test("complete 但正文过短视为空白", () {
      expect(
        DouyinGuestVerifyController.isBlankPage(infoOf(bodyLen: 5)),
        isTrue,
      );
    });
  });

  group("canManualSubmit 手动放行判据", () {
    Map<String, dynamic> infoOf({
      String title = "主播的直播间",
      String path = "/30000000000",
      int bodyLen = 0,
      bool hasCaptcha = false,
    }) {
      return jsonDecode(pageInfo(
        title: title,
        path: path,
        bodyLen: bodyLen,
        hasCaptcha: hasCaptcha,
      )) as Map<String, dynamic>;
    }

    test("开播/未开播甚至空正文都放行：用户主动点击，交由服务端实测", () {
      expect(
        DouyinGuestVerifyController.canManualSubmit(infoOf(), webRid),
        isTrue,
      );
      expect(
        DouyinGuestVerifyController.canManualSubmit(
            infoOf(bodyLen: 0), webRid),
        isTrue,
      );
    });

    test("仍停在验证码中间页：不放行", () {
      expect(
        DouyinGuestVerifyController.canManualSubmit(
            infoOf(title: "验证码中间页"), webRid),
        isFalse,
      );
    });

    test("验证码控件仍在：不放行", () {
      expect(
        DouyinGuestVerifyController.canManualSubmit(
            infoOf(hasCaptcha: true), webRid),
        isFalse,
      );
    });

    test("路径不匹配：不放行", () {
      expect(
        DouyinGuestVerifyController.canManualSubmit(
            infoOf(path: "/other"), webRid),
        isFalse,
      );
    });
  });

  test("probeScript 读取完成判据所需的全部字段", () {
    const script = DouyinGuestVerifyController.probeScript;
    expect(script, contains("readyState"));
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
