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
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    calls.add((windowId, method, arguments));
    if (windowId == throwingWindow) throw StateError('window gone');
    return null;
  }

  @override
  Future<List<String>> listWindowIds() async => const [];

  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();
}

class _ThrowingKvBox<T> extends MemoryKvBox<T> {
  @override
  Future<void> put(Object key, T value) async =>
      throw StateError('disk full');

  @override
  Future<void> delete(Object key) async =>
      throw StateError('disk full');

  @override
  Future<int> clear() async => throw StateError('disk full');
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
    Directory? tempDir;
    Box<String>? hiveBox;
    MainDataPlaneService? hiveSvc;
    try {
      tempDir = await Directory.systemTemp.createTemp('m42_hive_clear');
      final boxName =
          'shield_${DateTime.now().microsecondsSinceEpoch}';
      hiveBox =
          await Hive.openBox<String>(boxName, path: tempDir.path);
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
      hiveSvc = svc;
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
      // openBox 抛异常时 svc/box 可能未初始化，可空判空保证临时目录不泄漏
      hiveSvc?.onClose();
      await Hive.close();
      tempDir?.deleteSync(recursive: true);
    }
  });

  test('远程写 reload 回调抛异常被吞：不阻断后续防抖调度', () async {
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
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'});
    var reloadCalls = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () {
        reloadCalls++;
        if (reloadCalls == 1) throw StateError('reload boom');
      },
    );
    svc.onInit();

    await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 1));
    await flushReloadTimer();
    expect(reloadCalls, 1, reason: '第一次回调抛错已被吞');

    await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuOpacity', 2));
    await flushReloadTimer();
    expect(reloadCalls, 2, reason: '后续远程写仍能调度 reload');
  });

  test('落盘异常：六个写方法返回 false 不抛、不扇出、不发关注事件', () async {
    storage = LocalStorageService()
      ..settingsBox = _ThrowingKvBox<dynamic>()
      ..shieldBox = _ThrowingKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = _ThrowingKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = _ThrowingKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort();
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'});
    final events = <Object?>[];
    final sub = EventBus.instance
        .listen(Constant.kUpdateFollow, (p0) => events.add(p0));
    addTearDown(sub.cancel);
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () {},
    );
    svc.onInit();

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
        await call(
            DataPlaneProtocol.mKvSet,
            DataPlaneProtocol.kvSet(
                DataPlaneProtocol.boxSettings, 'DanmuSize', 1)),
        isFalse);
    expect(
        await call(
            DataPlaneProtocol.mKvDelete,
            DataPlaneProtocol.kvDelete(
                DataPlaneProtocol.boxSettings, 'DanmuSize')),
        isFalse);
    expect(
        await call(
            DataPlaneProtocol.mKvClear,
            DataPlaneProtocol.kvClear(DataPlaneProtocol.boxShield)),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mVolumeSet,
            DataPlaneProtocol.volumeSet('huya_9', 42)),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mFollowSet,
            DataPlaneProtocol.followSet(follow.toJson())),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mFollowRemove,
            DataPlaneProtocol.followRemove('bilibili_3')),
        isFalse);
    expect(changedCalls(), isEmpty, reason: '落盘失败不扇出');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: '落盘失败不发关注更新事件');
  });

  test('真实 Hive：dp_kv_set/delete 落盘、watch 扇出且各触发一次 owner reload',
      () async {
    // MemoryKvBox 为同步广播，测不到真实 Hive watch 的 async 派发与
    // _remoteWrite 标志下的 owner reload；put/delete 路径此前无自动化。
    Directory? tempDir;
    Box<dynamic>? hiveBox;
    MainDataPlaneService? hiveSvc;
    try {
      tempDir = await Directory.systemTemp.createTemp('m42_hive_write');
      final boxName =
          'localstorage_${DateTime.now().microsecondsSinceEpoch}';
      hiveBox =
          await Hive.openBox<dynamic>(boxName, path: tempDir.path);

      storage = LocalStorageService()
        ..settingsBox = HiveKvBox<dynamic>(hiveBox)
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
      hiveSvc = svc;
      svc.onInit();
      port.calls.clear();

      expect(
          await call(
              DataPlaneProtocol.mKvSet,
              DataPlaneProtocol.kvSet(
                  DataPlaneProtocol.boxSettings, 'DanmuSize', 20.0)),
          isTrue);
      expect(storage.getValue('DanmuSize', 0.0), 20.0);
      // Hive watch 为 async broadcast：排空一轮事件后再冲防抖 Timer
      await Future<void>.delayed(Duration.zero);
      await flushReloadTimer();
      expect(reloadCount, 1, reason: '远程写触发一次 owner reload');
      expect(changedCalls().length, 1);

      expect(
          await call(
              DataPlaneProtocol.mKvDelete,
              DataPlaneProtocol.kvDelete(
                  DataPlaneProtocol.boxSettings, 'DanmuSize')),
          isTrue);
      expect(storage.settingsBox.containsKey('DanmuSize'), isFalse);
      await Future<void>.delayed(Duration.zero);
      await flushReloadTimer();
      expect(reloadCount, 2, reason: '两次远程写各调度一次');
      final changed = changedCalls();
      expect(changed.length, 2);
      expect((changed[1].$2! as Map)['deleted'], isTrue);
    } finally {
      hiveSvc?.onClose();
      await Hive.close();
      tempDir?.deleteSync(recursive: true);
    }
  });

  test('未知方法（pr_ 前缀）委托 unhandledMethodHandler 并原样返回；dp_ 方法不触达',
      () async {
    // 独立夹具：不经 bootstrap()，避免触碰 WindowSnapshotBuilder 的 Get 依赖
    final localStorage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    final localDb = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    final delegated = <(String, Object?)>[];
    // 同步赋给共享 svc：本文件 tearDown 统一 onClose/Get.reset，
    // 否则单用例单跑（--plain-name）会触发 late 未初始化
    final localSvc = svc = MainDataPlaneService(
      port: _FakePort(),
      registry: WindowRegistry(mainWindowId: 'main'),
      storage: localStorage,
      db: localDb,
      unhandledMethodHandler: (method, arguments) async {
        delegated.add((method, arguments));
        return 'ok';
      },
    );
    localSvc.onInit();
    try {
      final result =
          await localSvc.handleCall('pr_register', {'tabId': 't1'});
      expect(result, 'ok');
      // record 运行时类型按字段静态类型物化（actual 第二字段为 Object?），
      // 直接与字面量列表比 == 必假，逐字段断言委托入参
      expect(delegated, hasLength(1));
      expect(delegated.single.$1, 'pr_register');
      expect(delegated.single.$2, {'tabId': 't1'});

      // dp_ 已知分支（坏载荷）在本服务内返回 false，不得落到委托
      final badKvSet =
          await localSvc.handleCall(DataPlaneProtocol.mKvSet, null);
      expect(badKvSet, isFalse);
      expect(delegated, hasLength(1), reason: 'dp_ 方法不触达 presence 委托');
    } finally {
      localSvc.onClose();
    }
  });
}
