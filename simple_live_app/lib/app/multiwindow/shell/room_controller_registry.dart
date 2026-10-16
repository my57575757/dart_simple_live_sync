import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

import 'tab_open_request.dart';

/// 标签 tabId → LiveRoomController 实例的注册抽象，
/// 生产实现用 GetX tag 容器，测试用内存假实现
abstract class RoomControllerRegistry {
  void register(String tabId, TabOpenRequest request);
  void unregister(String tabId);
  bool isRegistered(String tabId);

  /// 按跨窗去重键（siteId_roomId）找本引擎现存房间控制器，无则 null
  LiveRoomController? controllerForRoomKey(String roomKey);
}
