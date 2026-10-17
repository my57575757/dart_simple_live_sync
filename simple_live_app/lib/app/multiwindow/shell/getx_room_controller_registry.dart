import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class GetxRoomControllerRegistry implements RoomControllerRegistry {
  final Map<String, String> _roomKeyToTab = {};

  @override
  void register(String tabId, TabOpenRequest request) {
    final site = Sites.allSites[request.siteId];
    if (site == null) {
      throw ArgumentError('unknown site: ${request.siteId}');
    }
    // permanent: true——标签生命周期独立于任一路由。否则在搜索/历史/工具箱/
    // 分类详情等压栈路由内打开的标签，其控制器会被 GetX 绑定到该路由，
    // 用户侧键退出入口页时被连带 Get.delete（真退房/停心跳/销毁播放器），
    // 而标签描述符与 IndexedStack 中的页面仍在，形成死标签。
    Get.put(
      LiveRoomController(
        pSite: site,
        pRoomId: request.roomId,
        pShareUrl: request.shareUrl,
        tabId: tabId,
      ),
      tag: tabId,
      permanent: true,
    );
    _roomKeyToTab[request.key] = tabId;
  }

  @override
  void unregister(String tabId) {
    // permanent 实例必须 force 才能删除，否则关标签/closeAll 会永久泄漏
    Get.delete<LiveRoomController>(tag: tabId, force: true);
    _roomKeyToTab.removeWhere((key, value) => value == tabId);
  }

  @override
  bool isRegistered(String tabId) {
    return Get.isRegistered<LiveRoomController>(tag: tabId);
  }

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) {
    final tabId = _roomKeyToTab[roomKey];
    if (tabId == null ||
        !Get.isRegistered<LiveRoomController>(tag: tabId)) {
      return null;
    }
    return Get.find<LiveRoomController>(tag: tabId);
  }

  @override
  LiveRoomController? controllerForTabId(String tabId) {
    if (!Get.isRegistered<LiveRoomController>(tag: tabId)) return null;
    return Get.find<LiveRoomController>(tag: tabId);
  }
}
