// ignore_for_file: overridden_fields
import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

import 'proto/douyin.pb.dart';

class DouyinDanmakuArgs {
  final String webRid;
  final String roomId;
  final String userId;
  final String cookie;
  DouyinDanmakuArgs({
    required this.webRid,
    required this.roomId,
    required this.userId,
    required this.cookie,
  });
  @override
  String toString() {
    return json.encode({
      "webRid": webRid,
      "roomId": roomId,
      "userId": userId,
      "cookie": cookie,
    });
  }
}

class DouyinDanmaku extends LiveDanmaku {
  @override
  int heartbeatTime = 10 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://webcast3-ws-web-lq.douyin.com/webcast/im/push/v2/";
  late DouyinDanmakuArgs danmakuArgs;
  WebScoketUtils? webScoketUtils;

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as DouyinDanmakuArgs;
    var ts = DateTime.now().millisecondsSinceEpoch;
    var uuid = danmakuArgs.userId;
    var internalExt =
        "internal_src:dim|wss_push_room_id:${danmakuArgs.roomId}"
        "|wss_push_did:$uuid|first_req_ms:${ts - 1}|fetch_time:$ts"
        "|seq:1|wss_info:0-$ts-0-0";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "wss",
      queryParameters: {
        "app_name": "douyin_web",
        "version_code": "180800",
        "webcast_sdk_version": "1.0.15",
        "update_version_code": "1.0.15",
        "compress": "gzip",
        "device_platform": "web",
        "cookie_enabled": "true",
        "screen_width": "2560",
        "screen_height": "1440",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Mozilla",
        "browser_version": DouyinSite.kDefaultUserAgent.replaceAll(
          "Mozilla/",
          "",
        ),
        "browser_online": "true",
        "tz_name": "Asia/Shanghai",
        "cursor": "u-1_h-1_t-${ts}_r-1_d-1",
        "internal_ext": internalExt,
        "host": "https://live.douyin.com",
        "aid": "6383",
        "live_id": "1",
        "did_rule": "3",
        "endpoint": "live_pc",
        "support_wrds": "1",
        "im_path": "/webcast/im/fetch/",
        "user_unique_id": uuid,
        "identity": "audience",
        "need_persist_msg_count": "15",
        "insert_task_id": "",
        "live_reason": "",
        "room_id": danmakuArgs.roomId,
        "heartbeatDuration": "0",
      },
    );

    var sign = DouyinSign.getSignature(danmakuArgs.roomId, danmakuArgs.userId);

    var url = "$uri&signature=$sign";
    var backupUrl = url.replaceAll("webcast3-ws-web-lq", "webcast5-ws-web-lf");
    webScoketUtils = WebScoketUtils(
      url: url,
      backupUrl: backupUrl,
      headers: {
        "User-Agent": DouyinSite.kDefaultUserAgent,
        "Cookie": danmakuArgs.cookie,
        "Origin": "https://live.douyin.com",
      },
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom(args);
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

  @override
  void heartbeat() {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void decodeMessage(args) {
    // CoreLog.i(args.toString());

    var wssPackage = PushFrame.fromBuffer(args);

    var logId = wssPackage.logId;
    var decompressed = gzip.decode(wssPackage.payload);
    var payloadPackage = Response.fromBuffer(decompressed);
    if (payloadPackage.needAck) {
      sendAck(logId, payloadPackage.internalExt);
      //return;
    }
    for (var msg in payloadPackage.messagesList) {
      if (msg.method == 'WebcastChatMessage') {
        unPackWebcastChatMessage(msg.payload);
      } else if (msg.method == 'WebcastRoomUserSeqMessage') {
        unPackWebcastRoomUserSeqMessage(msg.payload);
      }
    }
  }

  void unPackWebcastChatMessage(List<int> payload) {
    var chatMessage = ChatMessage.fromBuffer(payload);
    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.chat,
        color: LiveMessageColor.white,
        //暂不知道具体怎么转换颜色
        // color: chatMessage.common.fullScreenTextColor.
        //     ? LiveMessageColor.white
        //     : LiveMessageColor.numberToColor(color),
        message: chatMessage.content,
        userName: chatMessage.user.nickName,
      ),
    );
  }

  void unPackWebcastRoomUserSeqMessage(List<int> payload) {
    var roomUserSeqMessage = RoomUserSeqMessage.fromBuffer(payload);

    onMessage?.call(
      LiveMessage(
        type: LiveMessageType.online,
        data: roomUserSeqMessage.totalUser.toInt(),
        color: LiveMessageColor.white,
        message: "",
        userName: "",
      ),
    );
  }

  void sendAck(var logId, String internalExt) {
    var obj = PushFrame();
    obj.payloadType = 'ack';
    obj.logId = logId;
    obj.payload = utf8.encode(internalExt);
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  void joinRoom(args) {
    var obj = PushFrame();
    obj.payloadType = 'hb';
    webScoketUtils?.sendMessage(obj.writeToBuffer());
  }

  String? _extractMsToken(String raw) {
    final match =
        RegExp(r'(?:^|;\s*)msToken=([^;]+)').firstMatch(raw);
    if (match == null) {
      return null;
    }
    final value = match.group(1)!.trim();
    if (value.isEmpty) {
      return null;
    }
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  Future<String?> _fetchMsToken() async {
    final response = await HttpClient.instance.getResponse(
      "https://live.douyin.com/${danmakuArgs.webRid}",
      header: {
        "User-Agent": DouyinSite.kDefaultUserAgent,
        "Cookie": danmakuArgs.cookie,
      },
    );
    for (final cookie in response.headers['set-cookie'] ?? <String>[]) {
      final token = _extractMsToken(cookie);
      if (token != null) {
        return token;
      }
    }
    return null;
  }

  static String buildChatUrl({
    required String roomId,
    required String content,
    required String webRid,
  }) {
    var params = <String, String>{
      "room_id": roomId,
      "content": content,
      "type": "0",
      "rtf_content": "",
      "emoji_id": "0",
      "camera_id": "",
      "team_id": "",
      "paste_edit_method": "0",
      "aid": "6383",
      "app_name": "douyin_web",
      "live_id": "1",
      "device_platform": "web",
      "language": "zh-CN",
      "enter_from": "web_live",
      "cookie_enabled": "true",
      "screen_width": "1920",
      "screen_height": "1080",
      "browser_name": "Mozilla",
      "browser_version": "180800",
      "os_name": "Windows",
      "os_version": "10",
      "web_rid": webRid,
    };
    var query = params.entries
        .map((e) =>
            "${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}")
        .join("&");
    return "https://live.douyin.com/webcast/room/chat/?$query";
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    if (!danmakuArgs.cookie.contains("sessionid")) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录抖音",
      );
    }
    try {
      var msToken = _extractMsToken(danmakuArgs.cookie);
      msToken ??= await _fetchMsToken();
      if (msToken == null) {
        return DanmakuSendResult(
          success: false,
          errorCode: "ms_token_failed",
          errorMessage: "获取msToken失败",
        );
      }
      var url = buildChatUrl(
        roomId: danmakuArgs.roomId,
        content: message,
        webRid: danmakuArgs.webRid,
      );
      url = DouyinSign.getAbogusUrl(
        url,
        DouyinSite.kDefaultUserAgent,
        msToken: msToken,
      );
      var result = await HttpClient.instance.getJson(
        url,
        header: {
          "User-Agent": DouyinSite.kDefaultUserAgent,
          "Referer": "https://live.douyin.com/${danmakuArgs.webRid}",
          "Cookie": danmakuArgs.cookie,
        },
      );
      var code = result["status_code"];
      if (code == 0) {
        return DanmakuSendResult(success: true);
      }
      var msg = result["data"]?["message"]?.toString() ?? "";
      return DanmakuSendResult(
        success: false,
        errorCode: code.toString(),
        errorMessage: msg,
      );
    } catch (e) {
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "网络请求失败",
      );
    }
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    webScoketUtils?.close();
  }
}
