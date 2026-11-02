import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/data/chat_history_codec.dart';
import 'package:simple_live_core/simple_live_core.dart';

LiveMessage msg({
  String user = 'u',
  String text = 'hi',
  int r = 255,
  int g = 255,
  int b = 255,
  bool self = false,
}) =>
    LiveMessage(
      type: LiveMessageType.chat,
      userName: user,
      message: text,
      color: LiveMessageColor(r, g, b),
      isSelf: self,
    );

void main() {
  group('encodeChatHistory', () {
    test('线格式仅 u/m/c/s 四键，JSON 兼容（不含任何凭据字段）', () {
      final encoded = encodeChatHistory([
        msg(user: '甲', text: '你好', r: 1, g: 2, b: 3, self: true),
      ]);
      expect(encoded.single.keys.toSet(), {'u', 'm', 'c', 's'});
      expect(encoded.single['c'], [1, 2, 3]);
      // 必须能安全过 IPC JSON 通道
      expect(() => jsonEncode(encoded), returnsNormally);
      final wire = jsonDecode(jsonEncode(encoded)) as List;
      expect((wire.single as Map).keys.toSet(), {'u', 'm', 'c', 's'});
    });

    test('多条保序；空输入空列表', () {
      final encoded = encodeChatHistory([msg(text: 'a'), msg(text: 'b')]);
      expect(encoded.map((e) => e['m']), ['a', 'b']);
      expect(encodeChatHistory(const []), isEmpty);
    });
  });

  group('decodeChatHistory', () {
    test('往返还原 user/message/color/isSelf，恒为 chat 类型', () {
      final back = decodeChatHistory(
        encodeChatHistory([
          msg(user: '甲', text: '你好', r: 1, g: 2, b: 3, self: true),
          LiveMessage(
            type: LiveMessageType.chat,
            userName: 'LiveSysMessage',
            message: '欢迎来到直播间',
            color: LiveMessageColor.white,
          ),
        ]),
      );
      expect(back.length, 2);
      expect(back[0].type, LiveMessageType.chat);
      expect(back[0].userName, '甲');
      expect(back[0].message, '你好');
      expect(back[0].color.r, 1);
      expect(back[0].color.g, 2);
      expect(back[0].color.b, 3);
      expect(back[0].isSelf, isTrue);
      expect(back[1].userName, 'LiveSysMessage');
      expect(back[1].color.r, 255);
      expect(back[1].isSelf, isFalse);
    });

    test('顶层非 List 返回空列表（不抛）', () {
      expect(decodeChatHistory(null), isEmpty);
      expect(decodeChatHistory('x'), isEmpty);
      expect(decodeChatHistory({'u': 'x'}), isEmpty);
    });

    test('逐条严格校验：坏条目跳过、好条目保留且保序', () {
      final back = decodeChatHistory([
        {'u': '好', 'm': '保留1', 'c': [1, 2, 3], 's': false},
        'not-a-map',
        {'m': '缺 u', 'c': [1, 2, 3]},
        {'u': 7, 'm': 'u 非字符串', 'c': [1, 2, 3]},
        {'u': 'x', 'm': 8, 'c': [1, 2, 3]},
        {'u': 'x', 'm': 'c 非 List'},
        {'u': 'x', 'm': 'c 长度错', 'c': [1, 2]},
        {'u': 'x', 'm': 'c 含非 num', 'c': [1, '2', 3]},
        {'u': 'x', 'm': 'c 越界', 'c': [1, 256, 3]},
        {'u': 'x', 'm': 'c 负数', 'c': [-1, 2, 3]},
        {'u': 'x', 'm': 's 非 bool', 'c': [1, 2, 3], 's': 'yes'},
        {'u': '好2', 'm': '保留2', 'c': [0, 0, 0]},
      ]);
      expect(back.map((e) => e.message), ['保留1', '保留2']);
      expect(back[1].color.b, 0);
    });

    test('s 缺省为 false；num 颜色（double）按 int 收口', () {
      final back = decodeChatHistory([
        {'u': 'x', 'm': 'y', 'c': [1.0, 2.0, 3.0]},
      ]);
      expect(back.single.isSelf, isFalse);
      expect(back.single.color.r, 1);
    });
  });
}
