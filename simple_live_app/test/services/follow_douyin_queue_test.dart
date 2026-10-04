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

class _FakeSite extends LiveSite {
  final Map<String, int> _failLeft = {};
  final Map<String, bool> _living = {};
  final List<String> callOrder = [];

  void configure(String roomId, {int failTimes = 0, bool living = false}) {
    _failLeft[roomId] = failTimes;
    _living[roomId] = living;
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    final id = roomId.split(';').first;
    callOrder.add(id);
    final left = _failLeft[id] ?? 0;
    if (left > 0) {
      _failLeft[id] = left - 1;
      throw Exception("网络错误");
    }
    return _living[id] ?? false;
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
  late _FakeSite douyinFake;
  late _FakeSite biliFake;
  late FollowService service;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp("sl_queue_test");
    Hive.init(tmp.path);
    void registerAdapter<T>(TypeAdapter<T> adapter) {
      if (!Hive.isAdapterRegistered(adapter.typeId)) {
        Hive.registerAdapter<T>(adapter);
      }
    }

    registerAdapter(FollowUserAdapter());
    registerAdapter(HistoryAdapter());
    registerAdapter(FollowUserTagAdapter());

    var localStorage = LocalStorageService();
    await localStorage.init();
    Get.put(localStorage);
    Get.put(AppSettingsController());

    var db = DBService();
    await db.init();
    Get.put(db);

    douyinFake = _FakeSite();
    biliFake = _FakeSite();
    var originalDouyin = Sites.allSites[Constant.kDouyin]!;
    var originalBili = Sites.allSites[Constant.kBiliBili]!;
    Sites.allSites[Constant.kDouyin] = Site(
      id: Constant.kDouyin,
      name: "抖音直播",
      logo: "",
      liveSite: douyinFake,
    );
    Sites.allSites[Constant.kBiliBili] = Site(
      id: Constant.kBiliBili,
      name: "哔哩哔哩",
      logo: "",
      liveSite: biliFake,
    );
    addTearDown(() {
      Sites.allSites[Constant.kDouyin] = originalDouyin;
      Sites.allSites[Constant.kBiliBili] = originalBili;
    });

    var u0 = FollowUser(
      id: "${Constant.kDouyin}_u0",
      roomId: "10000000000",
      siteId: Constant.kDouyin,
      userName: "抖音主播0",
      face: "",
      addTime: DateTime.now(),
    );
    var u1 = FollowUser(
      id: "${Constant.kDouyin}_u1",
      roomId: "10000000001",
      siteId: Constant.kDouyin,
      userName: "抖音主播1",
      face: "",
      addTime: DateTime.now(),
    );
    var b0 = FollowUser(
      id: "${Constant.kBiliBili}_b0",
      roomId: "20000000000",
      siteId: Constant.kBiliBili,
      userName: "B站主播0",
      face: "",
      addTime: DateTime.now(),
    );
    await db.followBox.put(u0.id, u0);
    await db.followBox.put(u1.id, u1);
    await db.followBox.put(b0.id, b0);

    service = FollowService();
    service.douyinGapForTesting = () => const Duration(milliseconds: 5);
    service.douyinRetryDelay = const Duration(milliseconds: 60);
  });

  tearDown(() async {
    Get.reset();
    await Hive.close();
    await tmp.delete(recursive: true);
  });

  test('抖音串行：队头失败暂停后续不请求，重试成功后继续队列', () async {
    douyinFake.configure("10000000000", failTimes: 2, living: false);
    douyinFake.configure("10000000001", living: true);
    biliFake.configure("20000000000", living: false);

    await service.loadData(manual: true);

    // 队头首次失败：暂停，第二个抖音从未请求；bili 不受影响已落定
    await _waitFor(() => douyinFake.callOrder.where((e) => e == "10000000000").length == 1);
    expect(douyinFake.callOrder, isNot(contains("10000000001")));
    expect(service.updating.value, isTrue);
    expect(service.updatedCount, 1); // 仅 bili 落定

    // 队头重试两次后成功（未开播），随后第二个抖音继续并成功（开播）
    await _waitFor(() => !service.updating.value);
    expect(
      douyinFake.callOrder.where((e) => e == "10000000000").length,
      3,
    );
    expect(douyinFake.callOrder.last, "10000000001");

    var byId = {for (var u in service.followList) u.roomId: u};
    expect(byId["10000000000"]!.liveStatus.value, 1);
    expect(byId["10000000001"]!.liveStatus.value, 2);
    expect(byId["20000000000"]!.liveStatus.value, 1);
  });

  test('抖音全部成功：严格串行，请求间存在间隔', () async {
    douyinFake.configure("10000000000", living: true);
    douyinFake.configure("10000000001", living: true);
    biliFake.configure("20000000000", living: false);

    await service.loadData(manual: true);
    await _waitFor(() => !service.updating.value);

    expect(douyinFake.callOrder, ["10000000000", "10000000001"]);
  });
}
