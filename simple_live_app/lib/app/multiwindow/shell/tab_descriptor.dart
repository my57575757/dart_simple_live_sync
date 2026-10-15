import 'package:get/get.dart';
import 'tab_open_request.dart';

class TabDescriptor {
  TabDescriptor({required this.tabId, required this.request})
      : title = request.roomId.obs,
        hasError = false.obs;

  final String tabId;
  final TabOpenRequest request;
  final RxString title;
  final RxBool hasError;
}
