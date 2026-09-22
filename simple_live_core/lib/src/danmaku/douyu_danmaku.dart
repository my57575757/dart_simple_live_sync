// ignore_for_file: overridden_fields
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../common/binary_writer.dart';

class DouyuDanmakuArgs {
  final int roomId;
  final String cookie;
  DouyuDanmakuArgs({required this.roomId, this.cookie = ""});

  @override
  String toString() => json.encode({"roomId": roomId, "cookie": cookie});
}

class DouyuDanmaku extends LiveDanmaku {
  @override
  int heartbeatTime = 45 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;

  static const String vkSecret =
      "r5*^5;}2#\${XF[h+;'./.Q'1;,-]f'p[";

  late DouyuDanmakuArgs danmakuArgs;

  // 发送连接
  WebSocketChannel? _sendChannel;
  Timer? _keepLiveTimer;
  Completer<void>? _loginCompleter;
  Completer<void>? _pendingAck;
  String? _pendingContent;
  String? _pendingError;
  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// 实例是否已停止；停止后 _initSendChannel 不得再建立连接
  bool _stopped = false;

  @override
  Future start(dynamic args) async {
    danmakuArgs = args is DouyuDanmakuArgs
        ? args
        : DouyuDanmakuArgs(roomId: int.tryParse(args.toString()) ?? 0);
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();

    if (danmakuArgs.cookie.isNotEmpty) {
      unawaited(_initSendChannel());
    }
  }

  void joinRoom() {
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=loginreq/roomid@=${danmakuArgs.roomId}/"),
    );
    webScoketUtils?.sendMessage(serializeDouyu(
        "type@=joingroup/rid@=${danmakuArgs.roomId}/gid@=-9999/"));
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(serializeDouyu("type@=mrkl/"));
  }

  Future<void> _initSendChannel() async {
    if (_stopped) {
      return;
    }
    var cookie = danmakuArgs.cookie;
    var did = cookieValue(cookie, "dy_did");
    if (did.isEmpty) {
      did = _randomDid();
    }
    var uid = cookieValue(cookie, "acf_uid");

    String url;
    try {
      var resp = await HttpClient.instance.postJson(
        "https://www.douyu.com/lapi/live/gateway/web/${danmakuArgs.roomId}?isH5=1",
        data: "",
        header: {
          "Cookie": cookie,
          "Referer": "https://www.douyu.com/${danmakuArgs.roomId}",
        },
      );
      var info = resp["data"] ?? resp;
      var wssList = info["wss"] as List;
      var pick = wssList[Random().nextInt(wssList.length)];
      url = "wss://${pick["domain"]}:${pick["port"]}";
    } catch (e) {
      CoreLog.error(e);
      return;
    }

    // lapi HTTP 往返期间可能已 stop；不得再赋连接、发 loginreq、起 keeplive Timer
    if (_stopped) {
      return;
    }

    _loginCompleter = Completer<void>();
    _sendChannel = WebSocketChannel.connect(Uri.parse(url));
    unawaited(_sendChannel!.ready);
    _sendChannel!.stream.listen(
      (event) {
        if (event is List<int>) {
          _onSendChannelMessageBytes(Uint8List.fromList(event));
        } else {
          _handleStt(event.toString());
        }
      },
      onError: (e) => CoreLog.error(e),
      onDone: _onSendChannelDone,
    );

    var now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var stt = buildStt({
      "type": "loginreq",
      "roomid": danmakuArgs.roomId.toString(),
      "dfl": "sn@=105/ss@=1",
      "username": uid,
      "password": "",
      "ltkid": cookieValue(cookie, "acf_ltkid"),
      "biz": "1",
      "stk": cookieValue(cookie, "acf_stk"),
      "devid": did,
      "ct": "0",
      "pt": "2",
      "cvr": "0",
      "tvr": "7",
      "apd": "",
      "rt": now.toString(),
      "vk": generateVk(now, did),
      "ver": "20220825",
      "aver": "218101901",
      "dmbt": "chrome",
      "dmbv": "123",
    });
    _sendChannel!.sink.add(frameStt(stt));
  }

  void _onSendChannelMessageBytes(Uint8List bytes) {
    // 发送连接下行帧与 danmuproxy 同为 length(4)+length(4)+689(2)+0(1)+0(1)+STT+\0，
    // body 起始于第 12 字节；直接复用既有标准解析器。
    var stt = deserializeDouyu(bytes);
    if (stt != null) {
      _handleStt(stt);
    }
  }

  void _handleStt(String stt) {
    if (stt.isEmpty) {
      return;
    }
    var fields = _parseStt(stt);
    var type = fields["type"];
    if (type == "loginres") {
      if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
        _loginCompleter!.complete();
      }
      _keepLiveTimer?.cancel();
      _keepLiveTimer = Timer.periodic(
        const Duration(seconds: 45),
        (_) {
          try {
            var tick = DateTime.now().millisecondsSinceEpoch ~/ 1000;
            _sendChannel!.sink.add(frameStt(buildStt({
              "type": "keeplive",
              "vbw": "0",
              "cnd": "hs-h5",
              "tick": tick.toString(),
              "kd": "",
            })));
          } catch (e) {
            _keepLiveTimer?.cancel();
            CoreLog.error(e);
          }
        },
      );
    } else if (type == "chatmsg") {
      if (_pendingAck != null &&
          fields["uid"] == cookieValue(danmakuArgs.cookie, "acf_uid") &&
          fields["txt"] == escapeStt(_pendingContent!) &&
          !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    } else if (type == "newblackres") {
      _pendingError = "muted";
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    } else if (type == "errorrid") {
      _pendingError = fields["result"] ?? "error";
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    }
  }

    void _onSendChannelDone() {
    _keepLiveTimer?.cancel();
    _sendChannel = null;
    if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
      // 先挂一个吸收错误的监听，避免无 await 方时 completeError 成为未捕获错误
      _loginCompleter!.future.catchError((_) {});
      _loginCompleter!.completeError("closed");
    }
    if (_pendingAck != null && !_pendingAck!.isCompleted) {
      _pendingError = "network_error";
      _pendingAck!.complete();
    }
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    var cookie = danmakuArgs.cookie;
    if (cookie.isEmpty ||
        cookieValue(cookie, "acf_stk").isEmpty ||
        cookieValue(cookie, "acf_uid").isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录斗鱼",
      );
    }
    if (_sendChannel == null) {
      // 含连接建立中与已断开两种状态；不做自动重连，重进房间恢复
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "连接已断开，请稍后重试",
      );
    }
    if (DateTime.now().difference(_lastSendTime).inSeconds < 2) {
      return DanmakuSendResult(
        success: false,
        errorCode: "rate_limit",
        errorMessage: "发言太快，请稍后再试",
      );
    }
    try {
      await _loginCompleter!.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      return DanmakuSendResult(
        success: false,
        errorCode: "login_failed",
        errorMessage: "连接登录超时",
      );
    } catch (e) {
      return DanmakuSendResult(
        success: false,
        errorCode: "login_failed",
        errorMessage: "发送登录失败",
      );
    }

    var did = cookieValue(cookie, "dy_did");
    if (did.isEmpty) {
      did = _randomDid();
    }
    var nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var cst = DateTime.now().millisecondsSinceEpoch +
        8000 +
        Random().nextInt(2000);
    var stt = buildStt({
      "type": "chatmessage",
      "pe": "0",
      "content": message,
      "col": "0",
      "dy": did,
      "sender": cookieValue(cookie, "acf_uid"),
      "ifs": "0",
      "nc": "0",
      "dat": "0",
      "rev": "0",
      "tts": nowSec.toString(),
      "admzq": "0",
      "cst": cst.toString(),
    });

    try {
      _sendChannel!.sink.add(frameStt(stt));
    } catch (e) {
      CoreLog.error(e);
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "连接已断开，请稍后重试",
      );
    }

    _pendingAck = Completer<void>();
    _pendingContent = message;
    _pendingError = null;
    _lastSendTime = DateTime.now();

    var timer = Timer(const Duration(seconds: 8), () {
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingError = "timeout";
        _pendingAck!.complete();
      }
    });
    await _pendingAck!.future;
    timer.cancel();

    if (_pendingError != null) {
      return DanmakuSendResult(
        success: false,
        errorCode: _pendingError!,
        errorMessage: _pendingError == "muted" ? "你已被禁言" : "发送失败",
      );
    }
    return DanmakuSendResult(success: true);
  }

  static String generateVk(int currentTimeSecs, String did) {
    return md5
        .convert("$currentTimeSecs$vkSecret$did".codeUnits)
        .toString();
  }

  static String escapeStt(String v) =>
      v.replaceAll("@", "@A").replaceAll("/", "@S");

  static String buildStt(Map<String, String> fields) {
    return fields.entries
        .map((e) => "${escapeStt(e.key)}@=${escapeStt(e.value)}/")
        .join();
  }

  static Uint8List frameStt(String body) {
    var bytes = utf8.encode(body);
    var total = bytes.length + 9;
    var writer = BinaryWriter([]);
    writer.writeInt(total, 4, endian: Endian.little);
    writer.writeInt(total, 4, endian: Endian.little);
    writer.writeInt(689, 2, endian: Endian.little);
    writer.writeInt(0, 1, endian: Endian.little);
    writer.writeInt(0, 1, endian: Endian.little);
    writer.writeBytes(bytes);
    writer.writeInt(0, 1, endian: Endian.little);
    return Uint8List.fromList(writer.buffer);
  }

  static String cookieValue(String cookie, String name) {
    return RegExp("$name=([^;]+)").firstMatch(cookie)?.group(1) ?? "";
  }

  Map<String, String> _parseStt(String stt) {
    var result = <String, String>{};
    for (var field in stt.split("/")) {
      var idx = field.indexOf("@=");
      if (idx <= 0) {
        continue;
      }
      result[field.substring(0, idx)] = field.substring(idx + 2);
    }
    return result;
  }

  String _randomDid() {
    const chars = "0123456789abcdef";
    var rnd = Random();
    return List.generate(32, (_) => chars[rnd.nextInt(16)]).join();
  }

  @override
  Future stop() async {
    _stopped = true;
    onMessage = null;
    onClose = null;
    _keepLiveTimer?.cancel();
    if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
      // 兜底结束等待登录的调用方，避免 stop 后挂起；catchError 吸收无监听方时的错误
      _loginCompleter!.future.catchError((_) {});
      _loginCompleter!.completeError("closed");
    }
    if (_pendingAck != null && !_pendingAck!.isCompleted) {
      _pendingError = "network_error";
      _pendingAck!.complete();
    }
    await _sendChannel?.sink.close();
    _sendChannel = null;
    webScoketUtils?.close();
  }

  void decodeMessage(List<int> data) {
    try {
      String? result = deserializeDouyu(data);
      if (result == null) {
        return;
      }
      var jsonData = sttToJObject(result);

      var type = jsonData["type"]?.toString();
      if (type == "chatmsg") {
        if (jsonData["dms"] == null) {
          return;
        }
        var col = int.tryParse(jsonData["col"].toString()) ?? 0;
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: jsonData["txt"].toString(),
          color: getColor(col),
        );

        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  List<int> serializeDouyu(String body) {
    try {
      List<int> buffer = utf8.encode(body);
      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(689, 2, endian: Endian.little);
      writer.writeInt(0, 1, endian: Endian.little);
      writer.writeInt(0, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    try {
      var reader = BinaryReader(Uint8List.fromList(buffer));
      int fullMsgLength = reader.readInt32(endian: Endian.little);
      reader.readInt32(endian: Endian.little);
      int bodyLength = fullMsgLength - 9;
      reader.readShort(endian: Endian.little);
      reader.readByte(endian: Endian.little);
      reader.readByte(endian: Endian.little);

      var bytes = reader.readBytes(bodyLength);

      reader.readByte(endian: Endian.little);
      return utf8.decode(bytes);
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split("/")) {
        if (field.isEmpty) {
          continue;
        }
        var tokens = field.split("@=");
        result[tokens[0]] = sttToJObject(unscapeSlashAt(tokens[1]));
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}
