import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class GetxRoomControllerRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {
    final site = Sites.allSites[request.siteId];
    if (site == null) {
      throw ArgumentError('unknown site: ${request.siteId}');
    }
    Get.put(
      LiveRoomController(
        pSite: site,
        pRoomId: request.roomId,
        pShareUrl: request.shareUrl,
        tabId: tabId,
      ),
      tag: tabId,
    );
  }

  @override
  void unregister(String tabId) {
    Get.delete<LiveRoomController>(tag: tabId);
  }

  @override
  bool isRegistered(String tabId) {
    return Get.isRegistered<LiveRoomController>(tag: tabId);
  }
}
