import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class FakeLocalStorage extends LocalStorageService {
  @override
  T getValue<T>(dynamic key, T defaultValue) => defaultValue;

  @override
  Future<void> setValue<T>(dynamic key, T value) async {}
}

class FakeGuard extends GuardServerService {
  String? accountId = 'douyin-1';
  bool livingResult = true;
  final List<Map<String, dynamic>> statusCalls = [];

  @override
  Future<String?> ensureAccount(String platform) async => accountId;

  @override
  Future<Map<String, dynamic>> getLiveStatus({
    required String accountId,
    String roomId = '',
    String webRid = '',
  }) async {
    statusCalls.add({'accountId': accountId, 'webRid': webRid});
    return {'living': livingResult};
  }
}

void main() {
  late FollowService follow;
  late FakeGuard guard;

  setUp(() {
    Get.put<LocalStorageService>(FakeLocalStorage());
    guard = FakeGuard();
    Get.put<GuardServerService>(guard);
    follow = FollowService();
  });

  tearDown(Get.reset);

  test('抖音状态走 guard：透传 webRid，不触发直连回退', () async {
    var fallbackCalled = false;
    final living = await follow.resolveDouyinLiving(
      webRid: '96252793301',
      directFallback: () async {
        fallbackCalled = true;
        return false;
      },
    );

    expect(living, true);
    expect(fallbackCalled, false);
    expect(guard.statusCalls.single, {
      'accountId': 'douyin-1',
      'webRid': '96252793301',
    });
  });

  test('guard 未配置账号时走直连回退', () async {
    guard.accountId = null;

    final living = await follow.resolveDouyinLiving(
      webRid: '96252793301',
      directFallback: () async => true,
    );

    expect(living, true);
    expect(guard.statusCalls, isEmpty);
  });
}
