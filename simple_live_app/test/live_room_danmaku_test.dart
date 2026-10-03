import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

LiveRoomDetail buildDetail({dynamic danmakuData}) => LiveRoomDetail(
      roomId: "274889443828",
      title: "",
      cover: "",
      userName: "",
      userAvatar: "",
      online: 0,
      status: false,
      url: "https://live.douyin.com/274889443828",
      danmakuData: danmakuData,
    );

void main() {
  test("抖音骨架占位房间弹幕 roomId 为空时不启动弹幕", () {
    final detail = buildDetail(
      danmakuData: DouyinDanmakuArgs(
        webRid: "274889443828",
        roomId: "",
        userId: "7692364114664212031",
        cookie: "",
      ),
    );
    expect(LiveRoomController.canStartDanmaku(detail), isFalse);
  });

  test("正常抖音房间（含 roomId）弹幕可启动", () {
    final detail = buildDetail(
      danmakuData: DouyinDanmakuArgs(
        webRid: "274889443828",
        roomId: "7690343577918212890",
        userId: "7692364114664212031",
        cookie: "",
      ),
    );
    expect(LiveRoomController.canStartDanmaku(detail), isTrue);
  });

  test("无弹幕参数时不影响其他平台流程", () {
    expect(LiveRoomController.canStartDanmaku(null), isTrue);
  });
}
