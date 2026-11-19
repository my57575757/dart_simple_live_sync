import 'dart:async';
import 'dart:io';

import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/danmaku/douyin_danmaku.dart';
import 'package:test/test.dart';

/// 计数型本地 WS 服务器：记录接受的升级次数与被对端关闭的连接数
Future<HttpServer> _countingServer({
  Duration? firstCloseAfter,
  void Function(WebSocket ws)? onWs,
}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  var accepts = 0;
  server.listen((HttpRequest req) async {
    accepts++;
    final ws = await WebSocketTransformer.upgrade(req);
    onWs?.call(ws);
    ws.add('hello');
    if (firstCloseAfter != null && accepts == 1) {
      await Future<void>.delayed(firstCloseAfter);
      await ws.close();
    }
  });
  return server;
}

void main() {
  test('正常连接可就绪并收到消息', () async {
    final server = await _countingServer();
    final gotMessage = Completer<void>();
    final ready = Completer<void>();
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
      onReady: ready.complete,
      onMessage: (_) => gotMessage.complete(),
    );

    u.connect();
    await ready.future;
    expect(u.status, SocketStatus.connected);
    await gotMessage.future;

    u.close();
    await server.close(force: true);
  });

  test('握手挂起期间 close,握手完成后连接不得复活', () async {
    // 服务器故意延迟 500ms 才响应升级，模拟抖音 WS 首连慢/排队
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add('late');
    });
    var readyCount = 0;
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
      onReady: () => readyCount++,
    );

    u.connect();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // 直播控制器在游客 WS 握手挂起期间 stop() 切换账号连接
    u.close();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    expect(readyCount, 0, reason: '已 close 的在途握手不得回调 onReady');
    expect(u.status, SocketStatus.closed);

    await server.close(force: true);
  });

  test('首连失败前已 close,不得换备用域名重试', () async {
    // 主服务器拒绝升级,备用服务器可正常连接
    final primary = await HttpServer.bind('127.0.0.1', 0);
    primary.listen((HttpRequest req) {
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.close();
    });
    var backupHits = 0;
    final backup = await HttpServer.bind('127.0.0.1', 0);
    backup.listen((HttpRequest req) async {
      backupHits++;
      final ws = await WebSocketTransformer.upgrade(req);
      ws.add('bk');
    });
    var readyCount = 0;
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${primary.port}/',
      backupUrl: 'ws://127.0.0.1:${backup.port}/',
      heartBeatTime: 60000,
      onReady: () => readyCount++,
    );

    u.connect();
    u.close();
    await Future<void>.delayed(const Duration(seconds: 1));

    expect(readyCount, 0, reason: '已 close 的失败连接不得换备用域名复活');
    expect(backupHits, 0);

    await primary.close(force: true);
    await backup.close(force: true);
  });

  test('服务端断开后仍自动重连(正常重连路径不回归)', () async {
    final server = await _countingServer(
      firstCloseAfter: const Duration(milliseconds: 200),
    );
    var readyCount = 0;
    var reconnectSignalled = false;
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
      onReady: () => readyCount++,
      onMessage: (_) {},
      onReconnect: () => reconnectSignalled = true,
    );

    u.connect();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(reconnectSignalled, isTrue);
    // 重连定时器周期 5s,第二次握手完成后 onReady 应为 2
    await Future<void>.delayed(const Duration(milliseconds: 5200));
    expect(readyCount, 2);

    u.close();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(seconds: 10)));

  test('握手连续失败必须持续重试,不得一次失败即永久死亡', () async {
    // 抖音 WS 偶发握手失败/排队。旧实现里 connect() 会把触发它的重连
    // 定时器自己 cancel 掉,等于「每次断线只试一次」——一次失败即永久失聪,
    // 弹幕再也不回显。
    var attempts = 0;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) {
      attempts++;
      req.response.statusCode = HttpStatus.internalServerError;
      req.response.close();
    });    var closeNotices = 0;
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
      onClose: (_) => closeNotices++,
    );
    u.reconnectInterval = const Duration(milliseconds: 100);

    u.connect();
    await Future<void>.delayed(const Duration(milliseconds: 1500));

    expect(
      attempts,
      greaterThanOrEqualTo(5),
      reason: '握手失败后必须持续重试,不得第一次失败即永久停摆',
    );
    expect(
      closeNotices,
      lessThanOrEqualTo(1),
      reason: '连续失败期间不得反复刷「连接失败」提示',
    );

    u.close();
    await server.close(force: true);
  });

  test('安静房间反复断开不得耗尽重连预算', () async {
    // 冷门直播间长期没有下行消息。旧实现只靠「收到消息」把重连计数归零,
    // 安静房间几次断线就耗尽预算 -> 提示「重连超过最大次数」后永久断开。
    var accepts = 0;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) async {
      accepts++;
      final ws = await WebSocketTransformer.upgrade(req);
      // 升级成功但一个字节都不发
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
    });
    var readyCount = 0;
    var closeNotices = 0;
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
      onReady: () => readyCount++,
      onClose: (_) => closeNotices++,
    );    u.reconnectInterval = const Duration(milliseconds: 100);

    u.connect();
    await Future<void>.delayed(const Duration(seconds: 3));

    expect(
      readyCount,
      greaterThanOrEqualTo(8),
      reason: '握手成功即应归零重连预算,安静房间连续断开不得导致永久停摆',
    );
    expect(closeNotices, lessThanOrEqualTo(1), reason: '反复断开不得刷屏提示');
    expect(accepts, greaterThanOrEqualTo(8), reason: '服务端必须看到多次重连尝试');
    expect(
      u.reconnectTime,
      lessThanOrEqualTo(1),
      reason: '握手成功必须把连续失败计数归零,否则降频重连被误触发',
    );

    u.close();
    await server.close(force: true);
  }, timeout: const Timeout(Duration(seconds: 15)));

  test('显式 close 后不得再自动重连', () async {
    var accepts = 0;
    final server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((HttpRequest req) async {
      accepts++;
      final ws = await WebSocketTransformer.upgrade(req);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await ws.close();
    });
    final u = WebScoketUtils(
      url: 'ws://127.0.0.1:${server.port}/',
      heartBeatTime: 60000,
    );
    u.reconnectInterval = const Duration(milliseconds: 100);

    u.connect();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    u.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final seen = accepts;
    await Future<void>.delayed(const Duration(milliseconds: 800));

    expect(accepts, seen, reason: '显式关闭后不得再自动重连');

    // 迟到的错误回调（旧 socket 残留事件）也不得复活连接
    u.onError('late error', 'late error');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(accepts, seen, reason: 'close 之后不得再发起新连接');

    await server.close(force: true);
  });

  test('DouyinDanmaku 重复 start 会关闭上一条连接', () async {
    // 注入探针实例：start 一开头就必须 close 旧 WebScoketUtils，
    // 不能只覆盖字段（否则握手中的旧 socket 会僵尸复活）。
    final old = _CloseProbeUtils();
    final danmaku = DouyinDanmaku();
    danmaku.webScoketUtils = old;
    // 指向拒绝端口：start 内会被改写为 wss,握手立即失败且不起任何 Timer
    danmaku.serverUrl = 'ws://127.0.0.1:1/push';
    final args = DouyinDanmakuArgs(
      webRid: '123abc',
      roomId: '7300000000000000000',
      userId: '0',
      cookie: '',
    );

    await danmaku.start(args);

    expect(old.closed, isTrue);
  });
}

class _CloseProbeUtils extends WebScoketUtils {
  _CloseProbeUtils() : super(url: 'ws://127.0.0.1:1/', heartBeatTime: 60000);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}
