import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test("saveRoomTrust 收到 400 实测拒绝：异常文本透传服务端原因", () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.statusCode = 400;
      request.response.headers.contentType = ContentType.json;
      request.response
          .write('{"code":400,"message":"验证未通过，请重新完成滑块验证"}');
      await request.response.close();
    });

    final service = GuardServerService();
    service.serverUrl = "http://127.0.0.1:${server.port}";
    service.token = "t";

    Object? error;
    try {
      await service.saveRoomTrust(
        webRid: "100",
        cookies: "ttwid=bad",
        ua: "UA",
      );
    } catch (e) {
      error = e;
    }
    expect(error, isNotNull);
    expect(error.toString(), contains("验证未通过，请重新完成滑块验证"));

    await server.close(force: true);
  });

  group("远程验证会话", () {
    Future<GuardServerService> started(
      HttpServer server,
      void Function(HttpRequest request) handler,
    ) async {
      server.listen(handler);
      final service = GuardServerService();
      service.serverUrl = "http://127.0.0.1:${server.port}";
      service.token = "t";
      return service;
    }

    void writeJson(HttpResponse response, int status, Object body) {
      response.statusCode = status;
      response.headers.contentType = ContentType.json;
      response.write(jsonEncode(body));
      response.close();
    }

    test("startVerifySession 解析信封与视口字段", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri uri;
      late String auth;
      late Object body;
      final service = await started(server, (request) async {
        uri = request.uri;
        auth = request.headers.value("Authorization") ?? "";
        body = jsonDecode(await utf8.decoder.bind(request).join());
        writeJson(request.response, 200, {
          "code": 0,
          "data": {
            "sessionId": "vs_1",
            "webRid": "123456",
            "adopted": true,
            "ttlMs": 300000,
            "viewport": {"width": 1280, "height": 800},
            "minFrameMs": 150,
          },
        });
      });

      final session = await service.startVerifySession("123456");
      expect(uri.path, "/api/verify/session");
      expect(auth, "Bearer t");
      expect((body as Map)["webRid"], "123456");
      expect(session.sessionId, "vs_1");
      expect(session.adopted, isTrue);
      expect(session.ttlMs, 300000);
      expect(session.viewWidth, 1280);
      expect(session.viewHeight, 800);
      expect(session.minFrameMs, 150);

      await server.close(force: true);
    });

    test("verifySessionStatus 解析状态字段", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri uri;
      final service = await started(server, (request) async {
        uri = request.uri;
        writeJson(request.response, 200, {
          "code": 0,
          "data": {
            "state": "active",
            "phase": "captcha",
            "webRid": "123456",
            "url": "/123456",
            "title": "抖音",
            "remainingMs": 250000,
            "reason": "",
          },
        });
      });

      final status = await service.verifySessionStatus("vs_1");
      expect(uri.path, "/api/verify/session/vs_1/status");
      expect(status.state, "active");
      expect(status.phase, "captcha");
      expect(status.remainingMs, 250000);
      expect(status.isClosed, isFalse);
      expect(status.isVerifying, isFalse);

      await server.close(force: true);
    });

    test("verifySessionFrame 返回字节并解析帧头", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = await started(server, (request) async {
        final res = request.response;
        res.statusCode = 200;
        res.headers.contentType = ContentType("image", "jpeg");
        res.headers.set("x-frame-seq", "42");
        res.headers.set("x-session-state", "active");
        res.add(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0]));
        await res.close();
      });

      final frame = await service.verifySessionFrame("vs_1");
      expect(frame.bytes, [0xff, 0xd8, 0xff, 0xe0]);
      expect(frame.seq, 42);
      expect(frame.state, "active");
      expect(frame.isEmpty, isFalse);

      await server.close(force: true);
    });

    test("verifySessionFrame 收到 410 抛 isClosed 并解包信封原因", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = await started(server, (request) async {
        writeJson(request.response, 410, {
          "code": 410,
          "message": "会话已关闭（expired）",
        });
      });

      try {
        await service.verifySessionFrame("vs_1");
        fail("应抛 VerifySessionHttpException");
      } on VerifySessionHttpException catch (e) {
        expect(e.status, 410);
        expect(e.isClosed, isTrue);
        expect(e.isBusy, isFalse);
        expect(e.message, "会话已关闭（expired）");
      }

      await server.close(force: true);
    });

    test("verifySessionFrame 收到 503 抛 isBusy", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = await started(server, (request) async {
        writeJson(request.response, 503, {
          "code": 503,
          "message": "FRAME_UNAVAILABLE",
        });
      });

      try {
        await service.verifySessionFrame("vs_1");
        fail("应抛 VerifySessionHttpException");
      } on VerifySessionHttpException catch (e) {
        expect(e.status, 503);
        expect(e.isBusy, isTrue);
        expect(e.isClosed, isFalse);
      }

      await server.close(force: true);
    });

    test("sendVerifyEvents 回传 applied 且 wheel 才带 dx/dy", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      late Uri uri;
      late Object body;
      final service = await started(server, (request) async {
        uri = request.uri;
        body = jsonDecode(await utf8.decoder.bind(request).join());
        writeJson(request.response, 200, {
          "code": 0,
          "data": {"applied": 3},
        });
      });

      final applied = await service.sendVerifyEvents("vs_1", const [
        VerifyPointerEvent("down", x: 10, y: 20),
        VerifyPointerEvent("move", x: 30, y: 40),
        VerifyPointerEvent("wheel", x: 50, y: 60, dx: 0, dy: 120),
      ]);
      expect(uri.path, "/api/verify/session/vs_1/events");
      expect(applied, 3);
      final events = ((body as Map)["events"] as List).cast<Map>();
      expect(events[0], {"type": "down", "x": 10.0, "y": 20.0});
      expect(events[1].containsKey("dx"), isFalse);
      expect(events[2]["dy"], 120.0);

      await server.close(force: true);
    });

    test("sendVerifyEvents 空列表不发请求", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var hits = 0;
      final service = await started(server, (request) async {
        hits++;
        writeJson(request.response, 200, {"code": 0, "data": {}});
      });

      expect(await service.sendVerifyEvents("vs_1", const []), 0);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(hits, 0);

      await server.close(force: true);
    });

    test("reload/cancel 打到对应 POST 路由", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      final service = await started(server, (request) async {
        paths.add(request.uri.path);
        writeJson(request.response, 200, {"code": 0, "data": {}});
      });

      await service.reloadVerifySession("vs_1");
      await service.cancelVerifySession("vs_1");
      expect(paths, [
        "/api/verify/session/vs_1/reload",
        "/api/verify/session/vs_1/cancel",
      ]);

      await server.close(force: true);
    });

    test("startVerifySession 信封 code!=0 抛服务端原因", () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final service = await started(server, (request) async {
        writeJson(request.response, 200, {
          "code": 400,
          "message": "BAD_WEBRID",
        });
      });

      try {
        await service.startVerifySession("abc");
        fail("应抛异常");
      } catch (e) {
        expect(e.toString(), contains("BAD_WEBRID"));
      }

      await server.close(force: true);
    });
  });
}
