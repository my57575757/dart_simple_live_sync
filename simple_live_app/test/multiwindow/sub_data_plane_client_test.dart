import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_client.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';

class _FakePort implements SubDataPlanePort {
  Object? readyResult;
  bool throwOnReady = false;
  final List<(String, Object?)> calls = [];

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (method == DataPlaneProtocol.mReady) {
      if (throwOnReady) throw StateError('main gone');
      return readyResult;
    }
    return null;
  }
}

class _FakeRegistry implements RoomControllerRegistry {
  LiveRoomController? controller;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => controller;
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
}

void main() {
  tearDown(() {
    Get.reset();
  });

  test('reconcile：dp_ready 快照全量替换并立即 reload 一次（非防抖，R-11）', () {
    fakeAsync((async) {
      final port = _FakePort()
        ..readyResult = {
          'settings': {'DanmuSize': 22.0},
          'shield': ['词'],
          'volumes': {'douyin_1': 11.0},
          'followShareUrls': {'douyin_1': 'http://x'},
        };
      final db = InMemoryDBService();
      final settings =
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
      final shield = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
      var reloads = 0;
      final client = SubDataPlaneClient(
        port: port,
        settings: settings,
        shield: shield,
        db: db,
        registry: _FakeRegistry(),
        onSettingsChanged: () => reloads++,
      );

      // T1 Minor #3（ledger park 项）：reconcile 语义是「全量替换」而非合并——
      // 先播种对账快照里不存在的陈旧键，对账后必须全部消失
      settings.seedPut('StaleK', 1);
      shield.seedPut('旧词', '旧词');
      db.addFollow(FollowUser(
        id: 'bili_old',
        roomId: 'o',
        siteId: 'bilibili',
        userName: 'u',
        face: '',
        addTime: DateTime(2026),
      ));

      client.reconcile();
      async.flushMicrotasks();
      // R-11：reload 必须在 elapse 之前已同步发生（区分立即与防抖）
      expect(reloads, 1, reason: '对账 reload 立即执行，非 100ms 防抖');
      async.elapse(const Duration(milliseconds: 120));

      expect(settings.get('DanmuSize'), 22.0);
      expect(shield.values, contains('词'));
      expect(db.getVolume('douyin_1'), 11.0);
      expect(db.getFollowShareUrl('douyin_1'), 'http://x');
      // 陈旧键全量替换后消失（T1 Minor #3）
      expect(settings.containsKey('StaleK'), isFalse,
          reason: 'settings 为全量替换非合并');
      expect(shield.values, isNot(contains('旧词')));
      expect(db.getFollowExist('bili_old'), isFalse);
      expect(reloads, 1);
      // 播种不产生写穿回环
      expect(port.calls.map((c) => c.$1), [DataPlaneProtocol.mReady]);
    });
  });

  test('reconcile 失败不抛、沿用启动快照', () async {
    final port = _FakePort()..throwOnReady = true;
    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: InMemoryDBService(),
      registry: _FakeRegistry(),
      onSettingsChanged: () {},
    );
    await client.reconcile(); // 不抛
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });

  test('handleChanged：kv/shield 静默落本地、防抖合并 reload、不回发 IPC', () {
    fakeAsync((async) {
      final port = _FakePort();
      final settings =
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
      final shield = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
      var reloads = 0;
      final client = SubDataPlaneClient(
        port: port,
        settings: settings,
        shield: shield,
        db: InMemoryDBService(),
        registry: _FakeRegistry(),
        onSettingsChanged: () => reloads++,
      );

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv, key: 'DanmuSize', value: 18.0));
      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindShield, key: '词', value: '词'));
      expect(settings.get('DanmuSize'), 18.0);
      expect(shield.get('词'), '词');
      async.elapse(const Duration(milliseconds: 120));
      expect(reloads, 1, reason: '两事件防抖合并');

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv, key: 'DanmuSize', deleted: true));
      expect(settings.containsKey('DanmuSize'), isFalse);

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindShield, key: '', clear: true));
      expect(shield.values, isEmpty);
      async.elapse(const Duration(milliseconds: 120));

      expect(port.calls, isEmpty, reason: '接收侧绝不回发 IPC');
    });
  });

  test('handleChanged：volume/follow 分流；follow 定向刷当前房间按钮',
      () {
    final port = _FakePort();
    final db = InMemoryDBService();
    Get.put<DBService>(db, permanent: true);
    final registry = _FakeRegistry();
    // LiveRoomController 构造体会调 DBService.instance 回填 shareUrl，
    // 故必须先注册 DBService；不调 onInit（不进房、不播流、无 Timer）
    final controller = LiveRoomController(
      pSite: Sites.allSites['bilibili']!,
      pRoomId: '5',
      pShareUrl: '',
      tabId: 't1',
    );
    registry.controller = controller;

    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: db,
      registry: registry,
      onSettingsChanged: () {},
    );

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindVolume,
        key: 'bilibili_5',
        value: 33.0));
    expect(db.getVolume('bilibili_5'), 33.0);

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindFollow,
        key: 'bilibili_5',
        value: 'http://5'));
    expect(db.getFollowExist('bilibili_5'), isTrue);
    expect(controller.followed.value, isTrue);

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindFollow,
        key: 'bilibili_5',
        deleted: true));
    expect(db.getFollowExist('bilibili_5'), isFalse);
    expect(controller.followed.value, isFalse);
  });

  test('handleChanged：坏载荷忽略', () {
    final port = _FakePort();
    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: InMemoryDBService(),
      registry: _FakeRegistry(),
      onSettingsChanged: () {},
    );
    client.handleChanged(null);
    client.handleChanged({'kind': 'nope'});
    expect(port.calls, isEmpty);
  });
}
