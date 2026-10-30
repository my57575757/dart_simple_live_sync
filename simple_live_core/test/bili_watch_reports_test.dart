import 'dart:convert';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('E/X reportData 构造', () {
    test('id / device 是 JSON 字符串（数组元素），不是嵌套数组', () {
      expect(
          BiliWatchReports.id(parentId: 6, areaId: 236, seq: 1, roomId: 5050),
          '[6,236,1,5050]');
      expect(
        BiliWatchReports.device(
          buvid: 'AUTO3317901687841255',
          uuid: 'bfcdd5fb-649f-4057-bc46-4e32bc0dfee4',
        ),
        '["AUTO3317901687841255","bfcdd5fb-649f-4057-bc46-4e32bc0dfee4"]',
      );
    });

    test('X reportJson 字段顺序与官方 JSON.stringify 完全一致（黄金向量）',
        () {
      final reportJson = BiliWatchReports.heartbeatReportJson(
        id: '[6,236,1,5050]',
        device:
            '["AUTO3317901687841255","bfcdd5fb-649f-4057-bc46-4e32bc0dfee4"]',
        ruid: 433351,
        ets: 1793287209,
        benchmark: 'seacasdgyijfhofiuxoannn',
        time: 60,
        tsMs: 1793287269733,
        ua:
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
        trackid: '-99998',
      );

      // spyder 哈希整个 JSON 字符串：字段顺序必须与官方插入顺序一致。
      const golden =
          '{"id":"[6,236,1,5050]","device":"[\\"AUTO3317901687841255\\",\\"bfcdd5fb-649f-4057-bc46-4e32bc0dfee4\\"]","ruid":433351,"ets":1793287209,"benchmark":"seacasdgyijfhofiuxoannn","time":60,"ts":1793287269733,"ua":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36","trackid":"-99998"}';
      expect(reportJson, golden);
      expect(jsonDecode(reportJson)['id'], '[6,236,1,5050]');
    });

    test('X reportJson 保留原始中文字符，不做反斜杠-u 形式的 ASCII 转义', () {
      final reportJson = BiliWatchReports.heartbeatReportJson(
        id: '[6,236,1,5050]',
        device: '["AUTO3317901687841255","u"]',
        ruid: 433351,
        ets: 1793287209,
        benchmark: 'seacasdgyijfhofiuxoannn',
        time: 60,
        tsMs: 1793287269734,
        ua: 'Mozilla/5.0 中文测试 Chrome/156',
        trackid: '-99998',
      );
      // JS JSON.stringify 保留原始非 ASCII 字符，spyder 按 UTF-8 原文哈希；
      // Dart 默认 jsonEncode 会转成反斜杠-u 十六进制，签名会不一致。
      final backslashU = String.fromCharCodes([0x5c, 0x75]);
      expect(reportJson.contains('中文测试'), isTrue);
      expect(reportJson.contains(backslashU), isFalse);
    });

    test('E 参数：无补发时 is_patch=0、heart_beat 为字符串 []，且无 s 签名', () {
      final params = BiliWatchReports.enterParams(
        id: '[6,236,0,5050]',
        device: '["AUTO3317901687841255","u"]',
        ruid: 433351,
        tsMs: 1793287782883,
        ua: 'UA',
      );
      expect(params, {
        'id': '[6,236,0,5050]',
        'device': '["AUTO3317901687841255","u"]',
        'ruid': 433351,
        'ts': 1793287782883,
        'is_patch': 0,
        'heart_beat': '[]',
        'ua': 'UA',
      });
      expect(params.containsKey('s'), isFalse);
      expect(params.keys.toList(), [
        'id',
        'device',
        'ruid',
        'ts',
        'is_patch',
        'heart_beat',
        'ua',
      ]);
    });
  });
}
