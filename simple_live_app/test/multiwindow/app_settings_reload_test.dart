import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

void main() {
  test('reloadFromStorage：改 KV 后重读刷新 Rx；可重复调用', () {
    final storage = InMemoryLocalStorageService();
    storage.applySnapshot(const WindowSnapshot(
      settings: {'DanmuSize': 16.0},
    ));
    Get.put<LocalStorageService>(storage, permanent: true);
    final settings = AppSettingsController();
    settings.onInit();

    expect(settings.danmuSize.value, 16.0);
    storage.setValue(LocalStorageService.kDanmuSize, 24.0);
    expect(settings.danmuSize.value, 16.0, reason: 'KV 变更本身不刷 Rx');

    settings.reloadFromStorage();
    expect(settings.danmuSize.value, 24.0);
    settings.reloadFromStorage(); // 重复调用安全
    expect(settings.danmuSize.value, 24.0);

    Get.reset();
  });
}
