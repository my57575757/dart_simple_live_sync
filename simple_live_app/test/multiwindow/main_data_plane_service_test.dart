import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/main_data_plane_service.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _FakePort implements SubWindowPort {
  _FakePort({this.throwingWindow});
  final String? throwingWindow;
  final List<(String windowId, String method, Object? args)> calls = [];

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async =>
      const SubWindowHandle('x');

  @override
  Future<void> invoke(String windowId, String method, Object? arguments) async {
    calls.add((windowId, method, arguments));
    if (windowId == throwingWindow) throw StateError('window gone');
  }

  @override
  Future<List<String>> listWindowIds() async => const [];

  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();
}

void main() {
  late LocalStorageService storage;
  late DBService db;
  late _FakePort port;
  late WindowRegistry registry;
  late int reloadCount;
  late MainDataPlaneService svc;

  void bootstrap() {
    storage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort();
    registry = WindowRegistry(mainWindowId: 'main');
    registry.registerChild('w1', {'douyin_r1'});
    reloadCount = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () => reloadCount++,
    );
    svc.onInit();
  }

  tearDown(() {
    svc.onClose();
    Get.reset();
  });

  Future<Object?> call(String method, Object? args) =>
      svc.handleCall(method, args);

  /// 远程写会挂 100ms 防抖 Timer，用例末尾排空避免 pending timer
  Future<void> flushReloadTimer() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  List<(String, Object?)> changedCalls() => port.calls
      .where((c) => c.$2 == DataPlaneProtocol.mChanged)
      .map((c) => (c.$1, c.$3))
      .toList();

  test('dp_ready 返回当前数据面快照（敏感键已过滤）', () async {
    bootstrap();
    await storage.setValue('ThemeMode', 2);
    await storage.setValue('DouyinLoginCookie', 'secret');
    await db.addOrUpdateVolume('douyin_r1', 66.0);

    final raw = (await call(DataPlaneProtocol.mReady, null)) as Map;
    expect(raw['settings']['ThemeMode'], 2);
    expect(raw['settings'].containsKey('DouyinLoginCookie'), isFalse);
    expect((raw['volumes'] as Map)['douyin_r1'], 66.0);
  });

  test('dp_kv_set 落盘并扇出 changed；敏感键与非法载荷拒绝', () async {
    bootstrap();
    final ok = await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 20.0));
    expect(ok, isTrue);
    expect(storage.getValue('DanmuSize', 0.0), 20.0);

    final denied = await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DouyinCookie', 'x'));
    expect(denied, isFalse);
    expect(storage.settingsBox.containsKey('DouyinCookie'), isFalse);

    final bad = await call(DataPlaneProtocol.mKvSet, {'box': 'settings'});
    expect(bad, isFalse);

    final changed = changedCalls();
    expect(changed.length, 1, reason: '仅合法写入扇出一条');
    final payload = changed.single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindKv);
    expect(payload['key'], 'DanmuSize');
    expect(payload['value'], 20.0);
    await flushReloadTimer();
  });

  test('dp_kv_delete 敏感键拒绝；主窗本地写敏感键不扇出（双侧守卫）',
      () async {
    bootstrap();
    await storage.settingsBox.put('DouyinLoginCookie', 'secret');
    port.calls.clear();

    final denied = await call(
        DataPlaneProtocol.mKvDelete,
        DataPlaneProtocol.kvDelete(
            DataPlaneProtocol.boxSettings, 'DouyinLoginCookie'));
    expect(denied, isFalse);
    expect(storage.settingsBox.containsKey('DouyinLoginCookie'), isTrue);

    // 派单 7(a)：非法载荷（缺 key）同样拒绝，不新增 test
    final bad =
        await call(DataPlaneProtocol.mKvDelete, {'box': 'settings'});
    expect(bad, isFalse);

    await storage.settingsBox.put('GuardAccountId_douyin', 'acct');
    expect(changedCalls(), isEmpty);
    expect(reloadCount, 0, reason: '本地写不触发 owner reload');
  });

  test('dp_kv_clear 抑制逐 key 扇出，只发一条 clear 并落盘', () async {
    bootstrap();
    await storage.shieldBox.put('a', 'a');
    await storage.shieldBox.put('b', 'b');
    port.calls.clear();

    final r = await call(
        DataPlaneProtocol.mKvClear,
        DataPlaneProtocol.kvClear(DataPlaneProtocol.boxShield));
    expect(r, isTrue);
    expect(storage.shieldBox.values, isEmpty);

    final changed = changedCalls();
    expect(changed.length, 1);
    final payload = changed.single.$2! as Map;
    expect(payload['clear'], isTrue);
    expect(payload['kind'], DataPlaneProtocol.kindShield);
    await flushReloadTimer();
  });

  test('dp_kv_clear settings 被拒：主窗凭据与普通键都不动、不扇出',
      () async {
    bootstrap();
    await storage.settingsBox.put('DouyinLoginCookie', 'secret');
    await storage.settingsBox.put('DanmuSize', 18.0);
    port.calls.clear();

    final r = await call(
        DataPlaneProtocol.mKvClear,
        DataPlaneProtocol.kvClear(DataPlaneProtocol.boxSettings));
    expect(r, isFalse);
    expect(storage.settingsBox.containsKey('DouyinLoginCookie'), isTrue);
    expect(storage.settingsBox.containsKey('DanmuSize'), isTrue);
    expect(changedCalls(), isEmpty, reason: '拒绝不落盘不扇出');
  });

  test('dp_volume_set 落每房音量并广播 double', () async {
    bootstrap();
    final r = await call(
        DataPlaneProtocol.mVolumeSet,
        DataPlaneProtocol.volumeSet('huya_9', 42));
    expect(r, isTrue);
    expect(db.getVolume('huya_9'), 42.0);
    final payload = changedCalls().single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindVolume);
    expect(payload['value'], 42.0);
    await flushReloadTimer();
  });

  test('dp_follow_set/remove：落盘、广播 shareUrl、发关注更新事件', () async {
    bootstrap();
    final events = <Object?>[];
    final sub = EventBus.instance
        .listen(Constant.kUpdateFollow, (p0) => events.add(p0));
    addTearDown(sub.cancel);

    final follow = FollowUser(
      id: 'bilibili_3',
      roomId: '3',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://3',
    );
    expect(
        await call(DataPlaneProtocol.mFollowSet,
            DataPlaneProtocol.followSet(follow.toJson())),
        isTrue);
    expect(db.getFollowExist('bilibili_3'), isTrue);
    // EventBus 为 async broadcast，事件经事件队列（Timer）投递，
    // await handler 返回后需排空一次事件循环才能观察到监听回调
    await Future<void>.delayed(Duration.zero);
    expect(events, contains('bilibili_3'));

    var payload = changedCalls().single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindFollow);
    expect(payload['key'], 'bilibili_3');
    expect(payload['value'], 'http://3');

    port.calls.clear();
    expect(
        await call(DataPlaneProtocol.mFollowRemove,
            DataPlaneProtocol.followRemove('bilibili_3')),
        isTrue);
    expect(db.getFollowExist('bilibili_3'), isFalse);
    payload = changedCalls().single.$2! as Map;
    expect(payload['deleted'], isTrue);
    await flushReloadTimer();
  });

  test('dp_follow_set 坏 JSON 返回 false 不抛', () async {
    bootstrap();
    final r =
        await call(DataPlaneProtocol.mFollowSet, {'follow': {'id': 1}});
    expect(r, isFalse);
  });

  test('dp_history_add 落盘但不广播', () async {
    bootstrap();
    final r = await call(
        DataPlaneProtocol.mHistoryAdd,
        DataPlaneProtocol.historyAdd(History(
          id: 'douyin_8',
          roomId: '8',
          siteId: 'douyin',
          userName: 'u',
          face: '',
          updateTime: DateTime(2026),
        ).toJson()));
    expect(r, isTrue);
    expect(db.getHistory('douyin_8'), isNotNull);
    expect(changedCalls(), isEmpty);
  });

  test('远程写防抖合并触发一次主窗 reload；本地写不触发', () {
    fakeAsync((async) {
      bootstrap();
      unawaited(svc.handleCall(
          DataPlaneProtocol.mKvSet,
          DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxSettings, 'a', 1)));
      unawaited(svc.handleCall(
          DataPlaneProtocol.mKvSet,
          DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxSettings, 'b', 2)));
      async.elapse(const Duration(milliseconds: 50));
      expect(reloadCount, 0);
      async.elapse(const Duration(milliseconds: 80));
      expect(reloadCount, 1, reason: '100ms 防抖合并为一次');

      // 本地写：扇出但不 reload
      storage.settingsBox.put('c', 3);
      async.elapse(const Duration(milliseconds: 200));
      expect(reloadCount, 1);
    });
  });

  test('扇出途中某窗失败不阻断其余窗', () async {
    storage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort(throwingWindow: 'w1');
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'})
      ..registerChild('w2', {'b'});
    reloadCount = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () => reloadCount++,
    );
    svc.onInit();

    await svc.handleCall(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 1.0));
    await flushReloadTimer();
    final windows = changedCalls().map((c) => c.$1).toSet();
    expect(windows, containsAll({'w1', 'w2'}));
  });

  test('真实 Hive：shield clear 风暴抑制（async broadcast + clear 时序）',
      () async {
    // MemoryKvBox 永远测不出此路径：真实 Hive BoxBaseImpl.clear 先 await
    // backend.clear() 后 keystore.clear()，逐 key notify 经 async broadcast
    // 以 microtask 链式重排，await 链同步坍缩会使 finally 早于事件执行。
    final tempDir = await Directory.systemTemp.createTemp('m42_hive_clear');
    final boxName =
        'shield_${DateTime.now().microsecondsSinceEpoch}';
    final hiveBox =
        await Hive.openBox<String>(boxName, path: tempDir.path);
    try {
      await hiveBox.put('a', 'a');
      await hiveBox.put('b', 'b');
      await hiveBox.put('c', 'c');

      storage = LocalStorageService()
        ..settingsBox = MemoryKvBox<dynamic>()
        ..shieldBox = HiveKvBox<String>(hiveBox);
      Get.put<LocalStorageService>(storage, permanent: true);
      db = DBService()
        ..historyBox = MemoryKvBox<History>()
        ..followBox = MemoryKvBox<FollowUser>()
        ..tagBox = MemoryKvBox<FollowUserTag>()
        ..volumeBox = MemoryKvBox<double>();
      Get.put<DBService>(db, permanent: true);
      port = _FakePort();
      registry = WindowRegistry(mainWindowId: 'main');
      registry.registerChild('w1', {'douyin_r1'});
      reloadCount = 0;
      svc = MainDataPlaneService(
        port: port,
        registry: registry,
        storage: storage,
        db: db,
        onSettingsChanged: () => reloadCount++,
      );
      svc.onInit();
      port.calls.clear();

      final r = await call(
          DataPlaneProtocol.mKvClear,
          DataPlaneProtocol.kvClear(DataPlaneProtocol.boxShield));
      expect(r, isTrue);
      // 再排一个事件轮次兜底；随后 120ms 冲掉防抖 Timer
      await Future<void>.delayed(Duration.zero);
      await flushReloadTimer();

      final changed = changedCalls();
      expect(changed.length, 1, reason: '仅一条 clear:true，无逐 key 风暴');
      final payload = changed.single.$2! as Map;
      expect(payload['kind'], DataPlaneProtocol.kindShield);
      expect(payload['key'], '');
      expect(payload['clear'], isTrue);
      expect(payload.containsKey('deleted'), isFalse);
      expect(hiveBox.values, isEmpty);
    } finally {
      svc.onClose();
      await Hive.close();
      tempDir.deleteSync(recursive: true);
    }
  });
}
