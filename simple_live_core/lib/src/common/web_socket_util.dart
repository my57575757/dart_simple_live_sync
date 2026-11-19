import 'dart:async';

import 'package:web_socket_channel/io.dart';

enum SocketStatus {
  connected,
  failed,
  closed,
}

class WebScoketUtils {
  SocketStatus status = SocketStatus.closed;

  /// 链接
  final String url;

  /// 备用链接
  final String? backupUrl;

  /// 心跳时间
  final int heartBeatTime;

  /// 接收到信息
  final Function(dynamic)? onMessage;

  /// 连接关闭
  final Function(String msg)? onClose;

  /// 尝试重连
  final Function()? onReconnect;

  /// 准备就绪
  final Function()? onReady;

  /// 心跳
  final Function()? onHeartBeat;

  /// 请求头
  Map<String, dynamic>? headers;
  WebScoketUtils({
    required this.url,
    required this.heartBeatTime,
    this.onMessage,
    this.onClose,
    this.onReconnect,
    this.onReady,
    this.onHeartBeat,
    this.headers,
    this.backupUrl,
  });
  IOWebSocketChannel? webSocket;
  Timer? heartBeatTimer;

  /// 重连次数：连续失败次数。握手成功后归零（安静房间没有下行消息，
  /// 不能靠收到消息才归零，否则安静房间几次断线就耗尽预算、连接永久停摆）
  int reconnectTime = 0;
  Timer? reconnectTimer;

  /// 连续失败多少次后改用更低频率重试。连接不设终止态：弹幕连接一旦死掉
  /// 就再也收不到回显，必须能自行恢复。
  int maxReconnectTime = 5;

  /// 重连间隔
  Duration reconnectInterval = const Duration(seconds: 5);

  /// 已提示过连接失败：连续失败期间只提示一次，避免每次重试都刷系统消息
  bool _errorNotified = false;

  /// 用户显式关闭：关闭后不得再自动重连
  bool _manuallyClosed = false;

  StreamSubscription<dynamic>? streamSubscription;

  /// 连接代际：每次 close()/connect() 自增。握手中的 connect 续体醒来后
  /// 若代际已变，说明连接在 await ready 期间被关闭或取代，必须放弃，
  /// 不得 ready()/重试——否则旧连接会僵尸复活，与新连接双收消息。
  int _generation = 0;

  void connect({bool retry = false}) async {
    // 只拆旧连接，不取消重连定时器：connect() 常由重连定时器触发，
    // 在这里 cancel 掉它等于「每次断线只试一次」，一次失败即永久失聪。
    _teardownTransport();
    _manuallyClosed = false;
    final generation = _generation;
    try {
      var wsurl = url;
      if (backupUrl != null && backupUrl!.isNotEmpty && retry) {
        wsurl = backupUrl!;
      }
      webSocket = IOWebSocketChannel.connect(
        wsurl,
        connectTimeout: Duration(seconds: 10),
        headers: headers,
      );

      await webSocket?.ready;
      if (generation != _generation) {
        // 握手挂起期间已被 close() 或新 connect() 取代：关掉刚建立的
        // socket 后退出，不监听、不起心跳、不回调 onReady。
        webSocket?.sink.close();
        return;
      }
      ready();
    } catch (e) {
      if (generation != _generation) return;
      if (!retry) {
        connect(retry: true);
        return;
      }
      onError(e, e);
    }
  }

  /// 连接完成
  void ready() {
    status = SocketStatus.connected;
    // 握手成功即视为重连成功：安静房间可能长时间没有下行消息
    reconnectTime = 0;
    _errorNotified = false;

    streamSubscription = webSocket?.stream.listen(
      (data) => receiveMessage(data),
      onError: (e, s) => onError(e, s),
      onDone: onDone,
    );

    onReady?.call();
    initHeartBeat();
  }

  void initHeartBeat() {
    heartBeatTimer?.cancel();
    heartBeatTimer = Timer.periodic(
      Duration(milliseconds: heartBeatTime),
      (timer) {
        onHeartBeat?.call();
      },
    );
  }

  void receiveMessage(dynamic data) {
    //接受到一条信息也算重连成功
    reconnectTime = 0;
    onMessage?.call(data);
  }

  void onError(e, s) {
    status = SocketStatus.failed;
    if (!_errorNotified) {
      _errorNotified = true;
      onClose?.call(e.toString());
    }
    // 错误也必须走重连：原来这里直接停摆，连接永久失聪
    reconnect();
  }

  void onDone() {
    if (status == SocketStatus.closed) {
      return;
    }
    onReconnect?.call();
    reconnect();
  }

  void sendMessage(dynamic message) {
    if (status == SocketStatus.connected) {
      webSocket?.sink.add(message);
    }
  }

  /// 完全关闭：拆连接 + 取消重连（用户主动关闭 / 换连接）
  void close() {
    _manuallyClosed = true;
    _teardownTransport();
    reconnectTimer?.cancel();
    reconnectTimer = null;
  }

  /// 只拆当前传输层（socket + 订阅 + 心跳），保留重连定时器。
  /// 代际自增让在途握手作废。
  void _teardownTransport() {
    _generation++;
    status = SocketStatus.closed;

    streamSubscription?.cancel();
    streamSubscription = null;

    webSocket?.sink.close();
    webSocket = null;

    heartBeatTimer?.cancel();
    heartBeatTimer = null;
  }

  /// 安排下一次重连。断线链不设终止态：超过最大次数后降频继续重试，
  /// 连接必须最终能恢复，否则弹幕连接死掉就再也不会有回显。
  void reconnect() {
    if (_manuallyClosed) return;
    status = SocketStatus.closed;
    reconnectTime++;
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (reconnectTimer != null) return;
    final interval = reconnectTime > maxReconnectTime
        ? reconnectInterval * 3
        : reconnectInterval;
    reconnectTimer = Timer(interval, () {
      reconnectTimer = null;
      if (_manuallyClosed) return;
      connect();
    });
  }
}
