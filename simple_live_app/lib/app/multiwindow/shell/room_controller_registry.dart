import 'tab_open_request.dart';

/// 标签 tabId → LiveRoomController 实例的注册抽象，
/// 生产实现用 GetX tag 容器，测试用内存假实现
abstract class RoomControllerRegistry {
  void register(String tabId, TabOpenRequest request);
  void unregister(String tabId);
  bool isRegistered(String tabId);
}
