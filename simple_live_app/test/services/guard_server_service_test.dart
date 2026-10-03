import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

void main() {
  late GuardServerService service;
  late HttpServer server;
  late int port;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    service = GuardServerService();
    service.serverUrl = 'http://127.0.0.1:$port';
    service.token = 'tk';
  });

  tearDown(() => server.close(force: true));

  test('getLiveStatus: 带鉴权 POST accountId/webRid，解析 living', () async {
    late Map<String, dynamic> received;
    server.listen((req) async {
      expect(req.uri.path, '/api/room/status');
      expect(req.headers.value('Authorization'), 'Bearer tk');
      received = jsonDecode(await utf8.decoder.bind(req).join());
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'code': 0,
        'message': 'ok',
        'data': {'living': true},
      }));
      await req.response.close();
    });

    expect(
      await service.getLiveStatus(
        accountId: 'douyin-1',
        webRid: '96252793301',
      ),
      {'living': true},
    );
    expect(received['accountId'], 'douyin-1');
    expect(received['webRid'], '96252793301');
  });

  test('getLiveStatus: 服务端 500 时抛异常', () async {
    server.listen((req) async {
      req.response.statusCode = 502;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode({
        'code': 502,
        'message': '直播状态查询失败',
      }));
      await req.response.close();
    });

    expect(
      () => service.getLiveStatus(accountId: 'douyin-1', webRid: 'r'),
      throwsA(isA<DioException>()),
    );
  });
}
