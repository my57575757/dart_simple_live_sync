import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

TabOpenRequest req(String site, String room, [String share = '']) =>
    TabOpenRequest(siteId: site, roomId: room, shareUrl: share);

class FakeRegistry implements RoomControllerRegistry {
  final registered = <String, TabOpenRequest>{};
  @override
  void register(String tabId, TabOpenRequest request) =>
      registered[tabId] = request;
  @override
  void unregister(String tabId) => registered.remove(tabId);
  @override
  bool isRegistered(String tabId) => registered.containsKey(tabId);
}

class FakeSubWindowPort implements SubWindowPort {
  final Map<String, String> created = {};
  final List<(String, String, Object?)> invocations = [];
  final List<String> alive = ['main'];
  final StreamController<void> changedController =
      StreamController<void>.broadcast();
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final id = 'w${++_seq}';
    created[id] = argumentsJson;
    alive.add(id);
    return SubWindowHandle(id);
  }

  @override
  Future<void> invoke(String windowId, String method, Object? arguments) async {
    invocations.add((windowId, method, arguments));
  }

  @override
  Future<List<String>> listWindowIds() async => List<String>.of(alive);

  @override
  Stream<void> get windowsChanged => changedController.stream;
}

void main() {
  late FakeSubWindowPort port;
  late TabStore store;
  late WindowRegistry registry;
  late WindowOpenService service;

  setUp(() {
    Get.put<LocalStorageService>(InMemoryLocalStorageService(), permanent: true);
    Get.put<DBService>(InMemoryDBService(), permanent: true);
    port = FakeSubWindowPort();
    store = TabStore(registry: FakeRegistry());
    registry = WindowRegistry(mainWindowId: 'main');
    service = WindowOpenService(port: port, store: store, registry: registry);
    service.onInit();
  });

  tearDown(() async {
    service.onClose();
    Get.reset();
  });

  test('WindowRegistry：登记/查询/对账', () {
    registry.registerChild('w1', {'douyin_a'});
    registry.registerChild('w2', {'douyin_b', 'bili_c'});
    expect(registry.childCount, 2);
    expect(registry.childWindowIds, ['w1', 'w2']);
    expect(registry.windowForTab('douyin_b'), 'w2');
    expect(registry.windowForTab('douyin_x'), isNull);
    expect(registry.tabsOf('w1'), {'douyin_a'});

    registry.reconcile(['main', 'w2']);
    expect(registry.childCount, 1);
    expect(registry.windowForTab('douyin_a'), isNull);
  });

  test('卡片新窗口：全新房间创建子窗，参数为 room_shell JSON', () async {
    await service.openInNewWindow(req('douyin', 'a', 'http://a'));

    expect(port.created.length, 1);
    final args = RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.siteId, 'douyin');
    expect(args.tabs.single.roomId, 'a');
    expect(registry.childCount, 1);
  });

  test('全局去重：主窗已有的 key 只激活标签，不建窗', () async {
    final tab = store.open(req('douyin', 'a'));
    store.activateHome();
    await service.openInNewWindow(req('douyin', 'a', 'http://a'));

    expect(port.created, isEmpty);
    expect(store.activeTabId.value, tab.tabId);
  });

  test('全局去重：子窗已有的 key 置前该窗并 IPC 激活，不建第二窗', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    await service.openInNewWindow(req('douyin', 'a'));

    expect(port.created.length, 1);
    expect(port.invocations, contains(('w1', 'focus_tab', 'douyin_a')));
  });

  test('移到新窗口：创建子窗后关闭本窗标签', () async {
    final tab = store.open(req('douyin', 'a', 'http://a'));
    await service.moveTabToNewWindow(tab.tabId);

    expect(port.created.length, 1);
    final args = RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.shareUrl, 'http://a');
    expect(store.tabs, isEmpty);
  });

  test('onWindowsChanged：窗口消失后注册表自动对账摘除', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    expect(registry.childCount, 1);

    port.alive.remove('w1');
    port.changedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(registry.childCount, 0);
    expect(registry.windowForTab('douyin_a'), isNull);
  });

  test('requestCloseAllChildren：对每个子窗发 close_window，单点失败不阻断', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    await service.openInNewWindow(req('douyin', 'b'));
    await service.requestCloseAllChildren();

    expect(
      port.invocations,
      containsAll([('w1', 'close_window', null), ('w2', 'close_window', null)]),
    );
  });

  test('常规打开：本窗无重复时按 background 语义开主窗标签', () async {
    await service.openLocallyWithGlobalDedup(req('douyin', 'a'),
        background: true);
    expect(store.tabs.length, 1);
    expect(store.activeTabId.value, isNull, reason: '后台打开不激活');

    await service.openLocallyWithGlobalDedup(req('douyin', 'b'));
    expect(store.tabs.length, 2);
    expect(store.activeTabId.value, store.tabs.last.tabId);
  });

  test('常规打开命中子窗已有房间：只 IPC 置前，主窗不新增标签', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    port.invocations.clear();

    await service.openLocallyWithGlobalDedup(req('douyin', 'a'),
        background: true);
    expect(port.invocations, contains(('w1', 'focus_tab', 'douyin_a')));
    expect(store.tabs, isEmpty);
  });

  test('常规打开命中主窗已有标签：不发 IPC，并激活该标签', () async {
    final tab = store.open(req('douyin', 'a'), activate: false);
    store.activateHome();

    await service.openLocallyWithGlobalDedup(req('douyin', 'a'));
    expect(port.invocations, isEmpty);
    expect(store.activeTabId.value, tab.tabId);
  });

  test('快照剥离登录凭据/guard 配置，保留外观播放设置与屏蔽词', () {
    final storage =
        Get.find<LocalStorageService>() as InMemoryLocalStorageService;
    storage.settingsBox.put('DouyinLoginCookie', 'sessionid=secret');
    storage.settingsBox.put('DouyinCookie', 'ttwid=x');
    storage.settingsBox.put('GuardServerUrl', 'http://guard');
    storage.settingsBox.put('GuardServerToken', 'tok');
    storage.settingsBox.put('GuardAccountId_douyin', 'acct1');
    storage.settingsBox.put('BilibiliCookie', 'sess=b');
    storage.settingsBox.put('DouyuLoginPassword', 'pw');
    storage.settingsBox.put('kWebDAVPassword', 'wp');
    storage.settingsBox.put('ThemeMode', 2);
    storage.settingsBox.put('DanmuEnable', true);
    storage.settingsBox.put('PlayerVolume', 66.0);
    storage.shieldBox.put('垃圾词', '垃圾词');

    final args = WindowSnapshotBuilder.build([req('douyin', 'a')]);

    expect(args.snapshot.settings, containsPair('ThemeMode', 2));
    expect(args.snapshot.settings, containsPair('DanmuEnable', true));
    expect(args.snapshot.settings, containsPair('PlayerVolume', 66.0));
    for (final key in [
      'DouyinLoginCookie',
      'DouyinCookie',
      'GuardServerUrl',
      'GuardServerToken',
      'BilibiliCookie',
      'DouyuLoginPassword',
      'kWebDAVPassword',
    ]) {
      expect(args.snapshot.settings, isNot(contains(key)),
          reason: '$key 不得跨窗传播');
    }
    expect(
      args.snapshot.settings.keys
          .any((k) => k.startsWith('GuardAccountId_')),
      isFalse,
    );
    expect(args.snapshot.shield, contains('垃圾词'));
  });

  test('快照安全回归：全部敏感键逐名剥离、非基础类型拒绝、显式 null 保留', () {
    final storage =
        Get.find<LocalStorageService>() as InMemoryLocalStorageService;

    // 锚定清单规模：删键会失败提醒评审，加键由下方遍历自动纳入断言
    expect(DataPlaneProtocol.sensitiveKeys.length, 17);
    for (final key in DataPlaneProtocol.sensitiveKeys) {
      storage.settingsBox.put(key, 'secret-$key');
    }
    storage.settingsBox.put('GuardAccountId_douyin', 'acct1');
    storage.settingsBox.put('GuardAccountId_bilibili', 'acct2');

    // 类型白名单：List/Map 不得进快照，显式 null 属于允许的基础类型
    storage.settingsBox.put('ListSetting', <String>['a', 'b']);
    storage.settingsBox.put('MapSetting', <String, dynamic>{'k': 1});
    storage.settingsBox.put('NullSetting', null);
    storage.settingsBox.put('NumSetting', 1);
    storage.settingsBox.put('BoolSetting', false);

    final settings =
        WindowSnapshotBuilder.build([req('douyin', 'a')]).snapshot.settings;

    for (final key in DataPlaneProtocol.sensitiveKeys) {
      expect(settings, isNot(contains(key)),
          reason: '$key 不得跨窗传播');
    }
    expect(
      settings.keys.any((k) => k.startsWith('GuardAccountId_')),
      isFalse,
      reason: 'GuardAccountId_ 前缀键不得跨窗传播',
    );
    expect(settings, isNot(contains('ListSetting')),
        reason: 'List 类型值不得进快照');
    expect(settings, isNot(contains('MapSetting')),
        reason: 'Map 类型值不得进快照');
    expect(settings, containsPair('NullSetting', null),
        reason: '显式 null 是白名单基础类型，键保留且值为 null');
    expect(settings, containsPair('NumSetting', 1));
    expect(settings, containsPair('BoolSetting', false));
  });

  test('build：mainWindowId 透传；buildDataSnapshot 与 build 同源', () {
    final storage =
        Get.find<LocalStorageService>() as InMemoryLocalStorageService;
    storage.settingsBox.put('ThemeMode', 2);
    storage.shieldBox.put('垃圾词', '垃圾词');

    final args = WindowSnapshotBuilder.build(
      [req('douyin', 'r1')],
      mainWindowId: '42',
    );
    expect(args.mainWindowId, '42');
    expect(args.snapshot.settings['ThemeMode'], 2);
    expect(args.snapshot.shield, contains('垃圾词'));

    final snap = WindowSnapshotBuilder.buildDataSnapshot();
    expect(snap.settings['ThemeMode'], 2);
    expect(snap.shield, contains('垃圾词'));
    expect(snap.volumes, args.snapshot.volumes);
    expect(snap.followShareUrls, args.snapshot.followShareUrls);
  });
}
