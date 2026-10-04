import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
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
  bool failFirstWith404 = false;
  String? reregisterResult = 'douyin-2';
  int reregisterCalls = 0;
  final List<Map<String, dynamic>> statusCalls = [];

  @override
  Future<String?> ensureAccount(String platform) async => accountId;

  @override
  Future<String?> reregister(String platform) async {
    reregisterCalls++;
    accountId = reregisterResult;
    return reregisterResult;
  }

  @override
  Future<Map<String, dynamic>> getLiveStatus({
    String? accountId,
    String roomId = '',
    String webRid = '',
  }) async {
    statusCalls.add({'accountId': accountId, 'webRid': webRid});
    if (failFirstWith404) {
      failFirstWith404 = false;
      final ro = RequestOptions(path: '/api/room/status');
      throw DioException(
        requestOptions: ro,
        response: Response<dynamic>(statusCode: 404, requestOptions: ro),
      );
    }
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
    // onInit 会从（返回默认空值的）FakeLocalStorage 重置 serverUrl，故在其后设置
    guard.serverUrl = 'http://guard';
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

  test('游客（未登录）走 guard 匿名查询，不走直连', () async {
    guard.accountId = null;
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
      'accountId': null,
      'webRid': '96252793301',
    });
  });

  test('guard 未配置（无地址）时走直连回退', () async {
    guard.serverUrl = '';
    var fallbackCalled = false;

    final living = await follow.resolveDouyinLiving(
      webRid: '96252793301',
      directFallback: () async {
        fallbackCalled = true;
        return true;
      },
    );

    expect(living, true);
    expect(fallbackCalled, true);
    expect(guard.statusCalls, isEmpty);
  });

  test('旧 accountId 失效(404)：重新注册并重试一次', () async {
    guard.failFirstWith404 = true;

    final living = await follow.resolveDouyinLiving(
      webRid: '96252793301',
      directFallback: () async => false,
    );

    expect(living, true);
    expect(guard.reregisterCalls, 1);
    expect(guard.statusCalls[0]['accountId'], 'douyin-1');
    expect(guard.statusCalls[1]['accountId'], 'douyin-2');
  });
}
