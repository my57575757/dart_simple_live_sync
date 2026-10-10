import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

void main() {
  for (final entry in const [
    ("/api/send", "send"),
    ("/api/action", "action"),
  ]) {
    test("${entry.$2} 超过 receiveTimeout 仍无响应时抛超时异常", () async {
      final hold = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        try {
          await hold.future;
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"code":0,"data":{"success":true}}');
          await request.response.close();
        } catch (_) {}
      });

      final service = GuardServerService();
      service.serverUrl = "http://127.0.0.1:${server.port}";
      service.token = "t";
      service.requestReceiveTimeout = const Duration(milliseconds: 150);

      Object? error;
      final sw = Stopwatch()..start();
      try {
        if (entry.$2 == "send") {
          await service.sendDanmaku(
            platform: "huya",
            accountId: "huya_x",
            roomId: "",
            content: "hi",
          );
        } else {
          await service.sendAction(
            accountId: "a_x",
            roomId: "",
            action: "like",
          );
        }
      } catch (e) {
        error = e;
      }
      sw.stop();

      expect(error, isA<DioException>());
      expect((error as DioException).type, DioExceptionType.receiveTimeout);
      expect(sw.elapsedMilliseconds, lessThan(3000));

      hold.complete();
      await server.close(force: true);
    });
  }
}
