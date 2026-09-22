// ignore_for_file: overridden_fields
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/model/tars/huya_danmaku.dart';
import 'package:simple_live_core/src/model/tars/huya_send_message_req.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:simple_live_core/src/model/tars/huya_verify_cookie.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';

class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;
  final String cookie;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
    this.cookie = "",
  });
  @override
  String toString() {
    return json.encode({
      "ayyuid": ayyuid,
      "topSid": topSid,
      "subSid": subSid,
      "cookie": cookie,
    });
  }
}

class HuyaDanmaku extends LiveDanmaku {
  @override
  int heartbeatTime = 60 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://cdnws.api.huya.com";

  WebScoketUtils? webScoketUtils;

  final heartbeatData = base64.decode("ABQdAAwsNgBM");

  late HuyaDanmakuArgs danmakuArgs;

  static const String kHuyaUA = "webh5&2004231432&websocket";

  int _requestId = 0;
  bool _verified = false;
  final Map<int, Completer<int>> _pendingWup = {};
  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);

  String get _uidStr {
    var m = RegExp(r"(?:yyuid|udb_uid)=([^;]+)").firstMatch(
      danmakuArgs.cookie,
    );
    return m?.group(1) ?? "";
  }

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as HuyaDanmakuArgs;
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
  }

  void joinRoom() {
    var joinData =
        getJoinData(danmakuArgs.ayyuid, danmakuArgs.topSid, danmakuArgs.topSid);
    webScoketUtils?.sendMessage(joinData);
    if (danmakuArgs.cookie.isNotEmpty) {
      verifyCookie();
    }
  }

  void verifyCookie() {
    var req = HuyaVerifyCookieReq()
      ..lUid = int.tryParse(_uidStr) ?? 0
      ..sUA = kHuyaUA
      ..sCookie = danmakuArgs.cookie
      ..sGuid = "";
    var oos = TarsOutputStream();
    req.writeTo(oos);

    var cmd = TarsOutputStream();
    cmd.write(10, 0);
    cmd.write(oos.toUint8List(), 1);
    webScoketUtils?.sendMessage(cmd.toUint8List());
  }

  List<int> getJoinData(int ayyuid, int tid, int sid) {
    try {
      var oos = TarsOutputStream();
      oos.write(ayyuid, 0);
      oos.write(true, 1);
      oos.write("", 2);
      oos.write("", 3);
      oos.write(tid, 4);
      oos.write(sid, 5);
      oos.write(0, 6);
      oos.write(0, 7);

      var wscmd = TarsOutputStream();
      wscmd.write(1, 0);
      wscmd.write(oos.toUint8List(), 1);
      return wscmd.toUint8List();
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(heartbeatData);
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    if (danmakuArgs.cookie.isEmpty || _uidStr.isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录虎牙",
      );
    }
    if (DateTime.now().difference(_lastSendTime).inSeconds < 20) {
      return DanmakuSendResult(
        success: false,
        errorCode: "rate_limit",
        errorMessage: "发言太快，请稍后再试",
      );
    }
    if (!_verified) {
      var waited = 0;
      while (!_verified && waited < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited++;
      }
      if (!_verified) {
        return DanmakuSendResult(
          success: false,
          errorCode: "login_failed",
          errorMessage: "虎牙登录校验失败",
        );
      }
    }

    var req = HuyaSendMessageReq();
    req.tUserId = HuyaUserId()
      ..lUid = int.tryParse(_uidStr) ?? 0
      ..sHuYaUA = kHuyaUA
      ..sCookie = danmakuArgs.cookie
      ..sDeviceInfo = "Chrome";
    req.lTid = danmakuArgs.ayyuid;
    req.lSid = danmakuArgs.ayyuid;
    req.lPid = danmakuArgs.ayyuid;
    req.sContent = message;

    var wup = TarsUniPacket();
    wup.servantName = "liveui";
    wup.funcName = "sendMessage";
    var id = ++_requestId;
    wup.requestId = id;
    wup.put("tReq", req);
    var vData = wup.encode();

    var cmd = TarsOutputStream();
    cmd.write(3, 0);
    cmd.write(vData, 1);

    var completer = Completer<int>();
    _pendingWup[id] = completer;
    _lastSendTime = DateTime.now();
    webScoketUtils?.sendMessage(cmd.toUint8List());

    var timer = Timer(const Duration(seconds: 10), () {
      _pendingWup.remove(id);
      if (!completer.isCompleted) {
        completer.complete(-999);
      }
    });
    var status = await completer.future;
    timer.cancel();

    if (status == 0) {
      return DanmakuSendResult(success: true);
    }
    if (status == -999) {
      return DanmakuSendResult(
        success: false,
        errorCode: "timeout",
        errorMessage: "发送超时",
      );
    }
    return DanmakuSendResult(
      success: false,
      errorCode: status.toString(),
      errorMessage: "发送失败",
    );
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    _verified = false;
    for (var c in _pendingWup.values) {
      if (!c.isCompleted) {
        c.complete(-999);
      }
    }
    _pendingWup.clear();
    webScoketUtils?.close();
  }

  void decodeMessage(List<int> data) {
    try {
      var stream = TarsInputStream(Uint8List.fromList(data));
      var type = stream.read(0, 0, false);
      if (type == 11) {
        var inner = TarsInputStream(
          stream.readBytes(1, false),
        );
        var rsp = HuyaVerifyCookieRsp();
        rsp.readFrom(inner);
        if (rsp.iValidate == 0) {
          _verified = true;
        }
        return;
      }
      if (type == 4) {
        var bytes = stream.readBytes(1, false);
        var packet = TarsUniPacket();
        packet.decode(bytes);
        var id = packet.requestId;
        var completer = _pendingWup[id];
        if (completer == null) {
          return;
        }
        try {
          var rsp = packet.getByClass("tReq", HuyaSendMessageRsp());
          _pendingWup.remove(id);
          if (!completer.isCompleted) {
            completer.complete(rsp.iStatus);
          }
        } catch (e) {
          CoreLog.error(e);
          _pendingWup.remove(id);
          if (!completer.isCompleted) {
            completer.complete(-1);
          }
        }
        return;
      }
      if (type == 7) {
        stream = TarsInputStream(stream.readBytes(1, false));
        HYPushMessage wSPushMessage = HYPushMessage();
        wSPushMessage.readFrom(stream);
        if (wSPushMessage.uri == 1400) {
          HYMessage messageNotice = HYMessage();
          messageNotice
              .readFrom(TarsInputStream(Uint8List.fromList(wSPushMessage.msg)));
          var uname = messageNotice.userInfo.nickName;
          var content = messageNotice.content;

          var color = messageNotice.bulletFormat.fontColor;

          onMessage?.call(
            LiveMessage(
              type: LiveMessageType.chat,
              color: color <= 0
                  ? LiveMessageColor.white
                  : LiveMessageColor.numberToColor(color),
              message: content,
              userName: uname,
            ),
          );
        } else if (wSPushMessage.uri == 8006) {
          int online = 0;
          var s = TarsInputStream(Uint8List.fromList(wSPushMessage.msg));
          online = s.read(online, 0, false);
          onMessage?.call(
            LiveMessage(
              type: LiveMessageType.online,
              data: online,
              color: LiveMessageColor.white,
              message: "",
              userName: "",
            ),
          );
        }
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }
}
