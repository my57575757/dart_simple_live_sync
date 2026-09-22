import 'dart:convert';

import 'package:simple_live_core/src/model/tars/huya_send_message_req.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:test/test.dart';

void main() {
  test("SendMessageReq 编码包含 content 与 tag 结构", () {
    var req = HuyaSendMessageReq();
    req.tUserId = HuyaUserId()
      ..lUid = 123
      ..sHuYaUA = "webh5&2004231432&websocket"
      ..sCookie = "udb_uid=123; udb_biztoken=tok";
    req.lTid = 456;
    req.lSid = 456;
    req.lPid = 456;
    req.sContent = "你好";

    var oos = TarsOutputStream();
    req.writeTo(oos);
    var bytes = oos.toUint8List();

    expect(bytes.isNotEmpty, isTrue);
    // tag0 tUserId：首字节 head = (tag << 4) | type，高 4 位 tag = 0
    expect((bytes.first >> 4) & 0x0F, 0);
    // sContent 以 UTF-8 字节存储，断言字节序列存在
    var contentBytes = utf8.encode("你好");
    var found = false;
    for (var i = 0; i <= bytes.length - contentBytes.length; i++) {
      if (contentBytes
          .asMap()
          .entries
          .every((e) => bytes[i + e.key] == e.value)) {
        found = true;
        break;
      }
    }
    expect(found, isTrue);
  });

  test("SendMessageReq 默认字段可编码不报错", () {
    var oos = TarsOutputStream();
    HuyaSendMessageReq().writeTo(oos);
    expect(oos.toUint8List().isNotEmpty, isTrue);
  });
}
