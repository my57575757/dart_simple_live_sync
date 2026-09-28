import 'package:simple_live_core/src/model/tars/huya_send_message_req.dart';
import 'package:simple_live_core/src/model/tars/huya_send_message_rsp.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';
import 'package:test/test.dart';

void main() {
  test("SendMessageReq tag0 为 tBody 包装结构，tag11 为 iMessageMode", () {
    var req = HuyaSendMessageReq();
    req.tBody.tUserId = HuyaUserId()
      ..lUid = 123
      ..sHuYaUA = "webh5&2609241143&websocket"
      ..sCookie = "udb_uid=123; udb_biztoken=tok";
    req.tBody.lTid = 456;
    req.tBody.lSid = 789;
    req.tBody.lPid = 789;
    req.tBody.sContent = "你好";
    req.iMessageMode = 0;

    var oos = TarsOutputStream();
    req.writeTo(oos);
    var bytes = oos.toUint8List();

    // 外层：tag0 STRUCT（tBody）
    expect(bytes[0], 0x0a);
    // tBody 内：tag0 STRUCT（tUserId）
    expect(bytes[1], 0x0a);

    var decoded = HuyaSendMessageReq();
    decoded.readFrom(TarsInputStream(bytes));
    expect(decoded.tBody.lTid, 456);
    expect(decoded.tBody.lSid, 789);
    expect(decoded.tBody.lPid, 789);
    expect(decoded.tBody.sContent, "你好");
    expect(decoded.tBody.tUserId.lUid, 123);
    expect(decoded.iMessageMode, 0);
  });

  test("SendMessageReq 默认字段可编码不报错", () {
    var oos = TarsOutputStream();
    HuyaSendMessageReq().writeTo(oos);
    expect(oos.toUint8List().isNotEmpty, isTrue);
  });

  test("WS WupReq tReq 值为 writeTo 字段流，不经 put 的额外 struct 外壳", () {
    // WS liveui.sendMessage 的 tReq 参数值必须直接是 SendMessageReq 的字段流：
    // 以 tag0 tBody struct 开头（0a 0a ...），而非 write(struct,0) 产生的 0a 0a 0a。
    var req = HuyaSendMessageReq();
    req.tBody.tUserId = HuyaUserId()..lUid = 123;
    req.tBody.lTid = 456;
    req.tBody.lSid = 789;
    req.tBody.lPid = 789;
    req.tBody.sContent = "你好";

    var ros = TarsOutputStream();
    req.writeTo(ros);
    var treqBytes = ros.toUint8List();
    expect(treqBytes[0], 0x0a);
    expect(treqBytes[1], 0x0a);
    expect(treqBytes[2], isNot(0x0a));

    // 以 WS 约定放入 newData，整体编解码后 tReq 值可直接 readFrom 还原
    var wup = TarsUniPacket()
      ..servantName = "liveui"
      ..funcName = "sendMessage"
      ..requestId = 1;
    wup.newData["tReq"] = treqBytes;
    var back = TarsUniPacket()..decode(wup.encode());
    expect(back.newData.containsKey("tReq"), isTrue);
    var parsed = HuyaSendMessageReq()
      ..readFrom(TarsInputStream(back.newData["tReq"]!));
    expect(parsed.tBody.lTid, 456);
    expect(parsed.tBody.lSid, 789);
    expect(parsed.tBody.lPid, 789);
    expect(parsed.tBody.sContent, "你好");
    expect(parsed.tBody.tUserId.lUid, 123);
    expect(parsed.iMessageMode, 0);
  });

  test("SendMessageRsp 从嵌套 tStatus 解析 iStatus", () {
    // 构造：tRsp.tag0 struct { tag0 int iStatus }
    var status = HuyaSendMessageStatus()..iStatus = 0;
    var rsp = HuyaSendMessageRsp()..tStatus = status;
    var oos = TarsOutputStream();
    rsp.writeTo(oos);
    var bytes = oos.toUint8List();
    expect(bytes[0], 0x0a);
    expect(bytes[1], 0x0c);

    var parsed = HuyaSendMessageRsp();
    parsed.readFrom(TarsInputStream(bytes));
    expect(parsed.tStatus.iStatus, 0);
  });

  test("SendMessageRsp 非零 iStatus 原样返回", () {
    var rsp = HuyaSendMessageRsp()
      ..tStatus = (HuyaSendMessageStatus()..iStatus = 12345);
    var oos = TarsOutputStream();
    rsp.writeTo(oos);

    var parsed = HuyaSendMessageRsp();
    parsed.readFrom(TarsInputStream(oos.toUint8List()));
    expect(parsed.tStatus.iStatus, 12345);
  });
}
