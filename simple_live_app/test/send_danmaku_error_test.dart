import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuSendResult result(String code, {bool needEcho = false}) =>
    DanmakuSendResult(
      success: false,
      errorCode: code,
      needLocalEcho: needEcho,
    );

void main() {
  group("danmakuErrorText", () {
    test("未登录", () {
      expect(
        LiveRoomController.danmakuErrorText(
          "bilibili",
          result("not_login"),
        ).contains("登录"),
        isTrue,
      );
    });
    test("B站禁言码1", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("1")),
        "你已被禁言",
      );
    });
    test("频率限制", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("11")),
        "发言太快，请稍后再试",
      );
    });
    test("抖音敏感词", () {
      expect(
        LiveRoomController.danmakuErrorText("douyin", result("50004")),
        "内容包含敏感词",
      );
    });
    test("抖音未登录", () {
      expect(
        LiveRoomController.danmakuErrorText("douyin", result("8")),
        "未登录或登录已失效",
      );
    });
    test("兜底文案", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("999")),
        "弹幕发送失败",
      );
    });
  });
}
