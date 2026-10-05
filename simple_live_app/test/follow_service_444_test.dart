import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeDouyinSite extends LiveSite {
  int statusCallCount = 0;
  bool throw444 = true;
  bool living = false;
  int transientFailures = 0;
  int delayMs = 0;

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    statusCallCount++;
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    if (throw444) {
      throw CoreError("", statusCode: 444);
    }
    if (transientFailures > 0) {
      transientFailures--;
      throw CoreError("临时失败");
    }
    return living;
  }
}

Future<void> _waitFor(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 500; i++) {
    if (await condition()) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError("等待条件超时");
}

void main() {
  late Directory tmp;
  late _FakeDouyinSite fake;
  late FollowService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp("sl_follow_test");
    Hive.init(tmp.path);
    if (!Hive.isAdapterRegistered(1)) {
      Hive.registerAdapter(FollowUserAdapter());
    }
    if (!Hive.isAdapterRegistered(2)) {
      Hive.registerAdapter(HistoryAdapter());
    }
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(FollowUserTagAdapter());
    }

    var localStorage = LocalStorageService();
    await localStorage.init();
    Get.put(localStorage);
    Get.put(AppSettingsController());

    var db = DBService();
    await db.init();
    Get.put(db);

    fake = _FakeDouyinSite();
    var original = Sites.allSites[Constant.kDouyin]!;
    Sites.allSites[Constant.kDouyin] = Site(
      id: Constant.kDouyin,
      name: "抖音直播",
      logo: "",
      liveSite: fake,
    );
    addTearDown(() => Sites.allSites[Constant.kDouyin] = original);

    for (var i = 0; i < 2; i++) {
      var user = FollowUser(
        id: "${Constant.kDouyin}_u$i",
        roomId: "1000000000$i",
        siteId: Constant.kDouyin,
        userName: "主播$i",
        face: "",
        addTime: DateTime.now(),
      );
      await db.followBox.put(user.id, user);
    }

    service = FollowService();
    service.douyinConcurrency = 1;
    service.douyinLaunchInterval = const Duration(milliseconds: 1);
    service.itemRetryDelay = const Duration(milliseconds: 5);
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('444后不自动重试，自动轮询跳过抖音，手动刷新恢复', () async {
    await service.loadData(manual: true);
    await _waitFor(() => !service.updating.value);
    // 串行队列：队头 444 后后续不再请求，仅 1 次状态查询
    expect(fake.statusCallCount, 1);
    expect(service.retryTimerCount, 0);
    expect(
      service.followList.every((u) => u.liveStatus.value == 0),
      isTrue,
    );

    await service.loadData();
    await _waitFor(() => !service.updating.value);
    expect(fake.statusCallCount, 1);
    expect(
      service.followList.every((u) => u.liveStatus.value == 0),
      isTrue,
    );

    fake.throw444 = false;
    fake.living = true;
    await service.loadData(manual: true);
    await _waitFor(() => !service.updating.value);
    // 手动解除：队头重试成功（第 2 次），继续队列第二个（第 3 次）
    expect(fake.statusCallCount, 3);
    expect(
      service.followList.every((u) => u.liveStatus.value == 2),
      isTrue,
    );
  });

  test('临时失败本轮立即结束loading，后台复核成功后自动更新为直播中', () async {
    fake.throw444 = false;
    fake.living = true;
    fake.transientFailures = 2; // 两个关注首次都失败
    service.itemRetryDelay = const Duration(milliseconds: 400);
    await service.loadData(manual: true);
    await _waitFor(() => !service.updating.value);
    // 本轮不再暂停等待：两个都已发起（共 2 次），状态保留初始 0
    expect(fake.statusCallCount, 2);
    expect(
      service.followList.every((u) => u.liveStatus.value == 0),
      isTrue,
    );
    // 后台 ~5ms 复核：两次再请求，状态自动变为直播中
    await _waitFor(
      () => service.followList.every((u) => u.liveStatus.value == 2),
    );
    expect(fake.statusCallCount, 4);
  });

  test('单个房间状态很慢时，loading到硬上限立即结束，不无限等待', () async {
    fake.throw444 = false;
    fake.living = false;
    fake.delayMs = 800; // 每个状态查询都慢
    service.loadingMaxDuration = const Duration(milliseconds: 150);

    final sw = Stopwatch()..start();
    await service.loadData(manual: true);
    for (var i = 0; i < 40; i++) {
      if (!service.updating.value) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    sw.stop();
    expect(service.updating.value, isFalse);
    expect(sw.elapsedMilliseconds, lessThan(500));

    // 等慢请求全部落地，避免悬空 future
    await Future<void>.delayed(const Duration(milliseconds: 2000));
  });
}
