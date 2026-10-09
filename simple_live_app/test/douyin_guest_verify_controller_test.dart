import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_controller.dart';

String pageInfo({
  String title = "主播的直播间",
  String path = "/30000000000",
  bool hasVideo = false,
  bool hasCaptcha = false,
}) {
  return jsonEncode({
    "title": title,
    "path": path,
    "hasVideo": hasVideo,
    "hasCaptcha": hasCaptcha,
  });
}

void main() {
  const webRid = "30000000000";

  test("开播房间：有视频、无验证码，判定完成", () {
    final result = pageInfo(hasVideo: true);
    expect(DouyinGuestVerifyController.parseVerified(result, webRid), isTrue);
  });

  test("未开播房间：无视频但无验证码，仍判定完成", () {
    final result = pageInfo(hasVideo: false);
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
