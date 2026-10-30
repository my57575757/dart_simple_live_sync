import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/bili_watch_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeSettings extends AppSettingsController {
  @override
  final logEnable = false.obs;

  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}

  @override
  void unregister(String tabId) {}

  @override
  bool isRegistered(String tabId) => false;

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;

  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _FakeBiliWatch extends BiliWatchService {
  final starts = <int>[];
  final stops = <int>[];

  @override
  Future<void> start(int roomId) async {
    starts.add(roomId);
  }

  @override
  Future<void> stop(int roomId) async {
    stops.add(roomId);
  }
}

class _LoggedInBiliAccount extends BiliBiliAccountService {
  @override
  final logined = true.obs;

  @override
  // ignore: must_call_super
  void onInit() {}
}

class _LoggedOutBiliAccount extends BiliBiliAccountService {
  @override
  final logined = false.obs;

  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeGuard extends GuardServerService {
  @override
  // ignore: must_call_super
  void onInit() {}
}

LiveRoomDetail _detail({bool live = true}) => LiveRoomDetail(
      roomId: '5050',
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: live,
      url: 'https://live.bilibili.com/5050',
    );

void main() {
  tearDown(Get.reset);

  testWidgets('四重 gate 满足：进房即 start；切走标签 stop，切回 start',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Get.put<AppSettingsController>(_FakeSettings());
    final watch = _FakeBiliWatch();
    Get.put<BiliWatchService>(watch);
    Get.put<BiliBiliAccountService>(_LoggedInBiliAccount());
    final store = TabStore(registry: _FakeRegistry());
    store.activeTabId.value = 't1';
    Get.put<TabStore>(store);

    final controller = LiveRoomController(
      pSite: Site(
        id: Constant.kBiliBili,
        name: 'b',
        logo: '',
        liveSite: BiliBiliSite(),
      ),
      pRoomId: '5050',
      pShareUrl: 'https://live.bilibili.com/5050',
      tabId: 't1',
    );
    controller.detail.value = _detail();
    controller.liveStatus.value = true;
    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();

    controller.initBiliWatchForTesting();
    await tester.pump();

    expect(watch.starts, [5050]);
    expect(watch.stops, isEmpty);
    expect(controller.biliWatchRunningForTesting, isTrue);

    // 切到别的标签：旧会话 stop（tracker 内部走防抖补发）
    store.activeTabId.value = 'other-tab';
    expect(watch.stops, [5050]);
    expect(controller.biliWatchRunningForTesting, isFalse);

    // 防抖窗口内切回：start 延续会话（tracker 内取消补发、不重发 E）
    store.activeTabId.value = 't1';
    expect(watch.starts, [5050, 5050]);
    expect(controller.biliWatchRunningForTesting, isTrue);
  });

  testWidgets('暂停播放 / 直播结束 / 登出：均 stop；恢复后重新 start',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Get.put<AppSettingsController>(_FakeSettings());
    final watch = _FakeBiliWatch();
    Get.put<BiliWatchService>(watch);
    final account = _LoggedInBiliAccount();
    Get.put<BiliBiliAccountService>(account);
    Get.put<TabStore>(TabStore(registry: _FakeRegistry())
      ..activeTabId.value = 't1');

    final controller = LiveRoomController(
      pSite: Site(
        id: Constant.kBiliBili,
        name: 'b',
        logo: '',
        liveSite: BiliBiliSite(),
      ),
      pRoomId: '5050',
      pShareUrl: 'https://live.bilibili.com/5050',
      tabId: 't1',
    );
    controller.detail.value = _detail();
    controller.liveStatus.value = true;
    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();
    controller.initBiliWatchForTesting();
    await tester.pump();
    expect(watch.starts, [5050]);

    controller.biliWatchPlayingOverride = false;
    controller.refreshBiliWatchForTesting();
    expect(watch.stops, [5050]);

    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();
    controller.refreshBiliWatchForTesting();
    expect(watch.starts, [5050, 5050]);

    controller.liveStatus.value = false;
    expect(watch.stops, [5050, 5050]);

    controller.liveStatus.value = true;
    expect(watch.starts, [5050, 5050, 5050]);

    account.logined.value = false;
    expect(watch.stops, [5050, 5050, 5050]);
    account.logined.value = true;
    expect(watch.starts, [5050, 5050, 5050, 5050]);
  });

  testWidgets('控制器 onClose：运行中的会话补 stop', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Get.put<AppSettingsController>(_FakeSettings());
    final watch = _FakeBiliWatch();
    Get.put<BiliWatchService>(watch);
    Get.put<BiliBiliAccountService>(_LoggedInBiliAccount());
    Get.put<TabStore>(TabStore(registry: _FakeRegistry())
      ..activeTabId.value = 't1');

    final controller = LiveRoomController(
      pSite: Site(
        id: Constant.kBiliBili,
        name: 'b',
        logo: '',
        liveSite: BiliBiliSite(),
      ),
      pRoomId: '5050',
      pShareUrl: 'https://live.bilibili.com/5050',
      tabId: 't1',
    );
    controller.detail.value = _detail();
    controller.liveStatus.value = true;
    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();
    controller.initBiliWatchForTesting();
    await tester.pump();

    // onClose 是全量销毁路径，会触达 GuardServerService（真实 app 必注册）
    Get.put<GuardServerService>(_FakeGuard());
    controller.onClose();
    await tester.pump();
    expect(watch.stops, [5050]);
  });

  testWidgets('Android/路由模式（tabId==null，无 TabStore）：恒按前台计时',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Get.put<AppSettingsController>(_FakeSettings());
    final watch = _FakeBiliWatch();
    Get.put<BiliWatchService>(watch);
    Get.put<BiliBiliAccountService>(_LoggedInBiliAccount());

    final controller = LiveRoomController(
      pSite: Site(
        id: Constant.kBiliBili,
        name: 'b',
        logo: '',
        liveSite: BiliBiliSite(),
      ),
      pRoomId: '5050',
      pShareUrl: 'https://live.bilibili.com/5050',
    );
    controller.detail.value = _detail();
    controller.liveStatus.value = true;
    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();
    controller.initBiliWatchForTesting();
    await tester.pump();

    expect(watch.starts, [5050]);
  });

  testWidgets('未登录：不建立观看会话，任何状态变化都不发心跳', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    Get.put<AppSettingsController>(_FakeSettings());
    final watch = _FakeBiliWatch();
    Get.put<BiliWatchService>(watch);
    Get.put<BiliBiliAccountService>(_LoggedOutBiliAccount());

    final controller = LiveRoomController(
      pSite: Site(
        id: Constant.kBiliBili,
        name: 'b',
        logo: '',
        liveSite: BiliBiliSite(),
      ),
      pRoomId: '5050',
      pShareUrl: 'https://live.bilibili.com/5050',
    );
    controller.detail.value = _detail();
    controller.liveStatus.value = true;
    controller.biliWatchPlayingOverride = true;
    controller.biliWatchPlayingStreamOverride = const Stream<bool>.empty();
    controller.initBiliWatchForTesting();
    await tester.pump();

    expect(watch.starts, isEmpty);
    expect(watch.stops, isEmpty);
    expect(controller.biliWatchRunningForTesting, isFalse);
  });
}
