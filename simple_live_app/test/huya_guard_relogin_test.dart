import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

DioException httpError(int? status, Map<String, dynamic>? body) => DioException(
      requestOptions: RequestOptions(path: "/api/send"),
      response: status == null
          ? null
          : Response<dynamic>(
              requestOptions: RequestOptions(path: "/api/send"),
              statusCode: status,
              data: body,
            ),
    );

void main() {
  group("GuardServerService.mapHttpError", () {
    test("502 NOT_LOGIN：透传 guard_not_login 与中文消息，供弹窗引导重登", () {
      final r = GuardServerService.mapHttpError(
        httpError(502, {
          "code": 502,
          "message": "虎牙登录态已失效，请重新登录后再试",
          "errorCode": "NOT_LOGIN",
        }),
      );
      expect(r.success, isFalse);
      expect(r.errorCode, "guard_not_login");
      expect(r.errorMessage, "虎牙登录态已失效，请重新登录后再试");
    });

    test("502 ENTER_TIMEOUT：透传 guard_enter_timeout 与中文消息", () {
      final r = GuardServerService.mapHttpError(
        httpError(502, {
          "code": 502,
          "message": "虎牙页面加载超时，请稍后重试；若持续出现请重新登录虎牙",
          "errorCode": "ENTER_TIMEOUT",
        }),
      );
      expect(r.errorCode, "guard_enter_timeout");
      expect(r.errorMessage, contains("虎牙页面加载超时"));
    });

    test("502 无 errorCode：退化为 guard，不误导成登录失效", () {
      final r = GuardServerService.mapHttpError(
        httpError(502, {"code": 502, "message": "发送失败"}),
      );
      expect(r.errorCode, "guard");
      expect(r.errorMessage, "发送失败");
    });

    test("无响应体（网络断开/超时）：兜底网络请求失败", () {
      final r = GuardServerService.mapHttpError(httpError(null, null));
      expect(r.errorCode, "guard");
      expect(r.errorMessage, "网络请求失败");
    });
  });
}
