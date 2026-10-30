import 'dart:math';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('LIVE_BUVID 生成', () {
    test('格式：AUTO + 0..99 + 13 位毫秒时间戳 + 0..9', () {
      final buvid = BiliBiliSite.generateLiveBuvid(
        now: DateTime.fromMillisecondsSinceEpoch(1790168784125),
        random: Random(1),
      );
      expect(RegExp(r'^AUTO\d{1,2}1790168784125\d$').hasMatch(buvid), isTrue,
          reason: '实际值: $buvid');
    });

    test('固定时间与随机源：结果确定（持久化复现同一设备标识）', () {
      final now = DateTime.fromMillisecondsSinceEpoch(1790168784125);
      final a = BiliBiliSite.generateLiveBuvid(now: now, random: Random(7));
      final b = BiliBiliSite.generateLiveBuvid(now: now, random: Random(7));
      expect(a, b);
    });

    test('真实抓包样本形态（AUTO + 2 位 + 13 位 + 1 位）可由算法产出', () {
      // 浏览器抓到的真值：AUTO3317901687841255
      final buvid = BiliBiliSite.generateLiveBuvid(
        now: DateTime.fromMillisecondsSinceEpoch(1790168784125),
        random: _FixedRandom([33, 5]),
      );
      expect(buvid, 'AUTO3317901687841255');
    });
  });
}

/// 依次返回预设序列（用于产出与抓包样本一致的 AUTO33...5 形态）
class _FixedRandom implements Random {
  _FixedRandom(this._values);

  final List<int> _values;
  var _index = 0;

  @override
  int nextInt(int max) => _values[_index++ % _values.length];

  @override
  double nextDouble() => throw UnimplementedError();

  @override
  bool nextBool() => throw UnimplementedError();
}
