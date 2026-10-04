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

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    statusCallCount++;
    if (throw444) {
      throw CoreError("", statusCode: 444);
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
    Hive.registerAdapter(FollowUserAdapter());
    Hive.registerAdapter(HistoryAdapter());
    Hive.registerAdapter(FollowUserTagAdapter());

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
    service.douyinRetryDelay = const Duration(milliseconds: 5);
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
}
