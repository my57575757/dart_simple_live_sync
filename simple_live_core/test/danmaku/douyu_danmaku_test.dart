import 'dart:typed_data';

import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("escapeStt", () {
    test("@ 与 / 转义", () {
      expect(DouyuDanmaku.escapeStt("a@b/c"), "a@Ab@Sc");
    });
    test("单字符 @、/ 转义", () {
      expect(DouyuDanmaku.escapeStt("@"), "@A");
      expect(DouyuDanmaku.escapeStt("/"), "@S");
    });
    test("@= 转义后不与字段分隔符混淆", () {
      expect(DouyuDanmaku.escapeStt("@="), "@A=");
    });
  });

  group("buildStt", () {
    test("按顺序拼接", () {
      expect(
        DouyuDanmaku.buildStt({"type": "loginreq", "roomid": "123"}),
        "type@=loginreq/roomid@=123/",
      );
    });
    test("值转义", () {
      expect(
        DouyuDanmaku.buildStt({"dfl": "sn@=105/ss@=1"}),
        "dfl@=sn@A=105@Sss@A=1/",
      );
    });
  });

  group("generateVk", () {
    test("MD5 口径固定", () {
      // md5("1700000000" + vk_secret + "did123")
      var vk = DouyuDanmaku.generateVk(1700000000, "did123");
      expect(vk.length, 32);
      expect(RegExp(r"^[0-9a-f]{32}$").hasMatch(vk), isTrue);
    });
    test("固定输入产生固定 MD5（拼接顺序与 vk_secret 锁定）", () {
      // md5("1700000000" + vkSecret + "abcdef0123456789")
      expect(
        DouyuDanmaku.generateVk(1700000000, "abcdef0123456789"),
        "ec00f280db692c8ab9aec64328476757",
      );
    });
  });

  group("frameStt", () {
    test("帧头与现有协议一致（小端 689，length=总长-4）", () {
      var frame = DouyuDanmaku.frameStt("type@=mrkl/");
      var bd = ByteData.sublistView(frame);
      expect(bd.getInt32(0, Endian.little), frame.length - 4);
      expect(bd.getInt32(4, Endian.little), frame.length - 4);
      expect(bd.getInt16(8, Endian.little), 689);
      expect(frame.last, 0);
    });
  });
}
