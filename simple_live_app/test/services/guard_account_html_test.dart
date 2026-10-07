import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

class RecoverGuard extends GuardServerService {
  final calls = <String?>[];
  int failCount = 1;
  int failureStatus = 404;
  String? reregisterResult = 'acct2';
  bool reregistered = false;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<String?> reregister(String platform) async {
    reregistered = true;
    return reregisterResult;
  }

  @override
  Future<String> fetchRoomHtml({
    required String webRid,
    String? accountId,
  }) async {
    calls.add(accountId);
    if (accountId == 'acct1' && failCount-- > 0) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/room/html'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/room/html'),
          statusCode: failureStatus,
        ),
      );
    }
    return '<html/>';
  }
}

void main() {
  test('accountId 失效 404：重新注册后用新 id 重试成功', () async {
    final guard = RecoverGuard();

    final html = await guard.fetchDouyinAccountHtml(webRid: '890779695421');

    expect(html, '<html/>');
    expect(guard.reregistered, isTrue);
    expect(guard.calls, equals(['acct1', 'acct2']));
  });

  test('非 404 错误：直接抛出，不重新注册', () async {
    final guard = RecoverGuard()..failureStatus = 500;

    await expectLater(
      guard.fetchDouyinAccountHtml(webRid: 'x'),
      throwsA(isA<DioException>()),
    );
    expect(guard.reregistered, isFalse);
    expect(guard.calls, equals(['acct1']));
  });

  test('重新注册返回 null：抛出原错误，不重试', () async {
    final guard = RecoverGuard()..reregisterResult = null;

    await expectLater(
      guard.fetchDouyinAccountHtml(webRid: 'x'),
      throwsA(isA<DioException>()),
    );
    expect(guard.calls, equals(['acct1']));
  });
}
