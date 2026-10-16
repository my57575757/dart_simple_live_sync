import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';

void main() {
  group('载荷构造与解析往返', () {
    test('kvSet/kvDelete/kvClear', () {
      final set = DataPlaneProtocol.kvSet(
          DataPlaneProtocol.boxSettings, 'DanmuSize', 18.0);
      final w = DataPlaneProtocol.decodeKvSet(set);
      expect(w?.box, DataPlaneProtocol.boxSettings);
      expect(w?.key, 'DanmuSize');
      expect(w?.value, 18.0);

      expect(
          DataPlaneProtocol.decodeKvSet(DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxShield, 'w', '词')),
          isNotNull,
          reason: 'shield 的 String 值合法');

      final del =
          DataPlaneProtocol.kvDelete(DataPlaneProtocol.boxShield, 'w');
      final d = DataPlaneProtocol.decodeKvDelete(del);
      expect(d?.box, DataPlaneProtocol.boxShield);
      expect(d?.key, 'w');

      expect(
          DataPlaneProtocol.kvBoxOf(
              DataPlaneProtocol.kvClear(DataPlaneProtocol.boxSettings)),
          DataPlaneProtocol.boxSettings);
    });

    test('changed 构造/解析：普通、删除、清空', () {
      final e = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindVolume, key: 'douyin_1', value: 80.0),
      );
      expect(e?.kind, DataPlaneProtocol.kindVolume);
      expect(e?.key, 'douyin_1');
      expect(e?.value, 80.0);
      expect(e?.deleted, isFalse);
      expect(e?.clear, isFalse);

      final removed = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindFollow,
            key: 'bilibili_2',
            deleted: true),
      );
      expect(removed?.deleted, isTrue);
      expect(removed?.value, isNull);

      final cleared = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindShield, key: '', clear: true),
      );
      expect(cleared?.clear, isTrue);
    });
  });

  group('非法载荷拒绝', () {
    test('box 白名单', () {
      expect(DataPlaneProtocol.kvBoxOf({'box': 'history'}), isNull);
      expect(DataPlaneProtocol.kvBoxOf('x'), isNull);
      expect(DataPlaneProtocol.kvBoxOf(null), isNull);
    });

    test('kvSet 值类型白名单', () {
      expect(
          DataPlaneProtocol.decodeKvSet({'box': 'settings', 'key': 'k'}),
          isNull,
          reason: '缺 value');
      expect(
          DataPlaneProtocol.decodeKvSet({
            'box': 'settings',
            'key': 'k',
            'value': ['a']
          }),
          isNull,
          reason: 'List 拒绝');
      expect(
          DataPlaneProtocol.decodeKvSet({
            'box': 'settings',
            'key': 'k',
            'value': {'a': 1}
          }),
          isNull,
          reason: 'Map 拒绝');
      expect(
          DataPlaneProtocol.decodeKvSet(
              {'box': 'shield', 'key': 'k', 'value': 1}),
          isNull,
          reason: 'shield 只接受 String');
      expect(DataPlaneProtocol.decodeKvSet('x'), isNull);
      expect(
          DataPlaneProtocol.decodeKvSet({'box': 'settings', 'key': 1}), isNull,
          reason: 'key 必须是 String');
    });

    test('decodeChanged kind 白名单与 key 类型', () {
      expect(
          DataPlaneProtocol.decodeChanged({'kind': 'history', 'key': 'a'}),
          isNull);
      expect(DataPlaneProtocol.decodeChanged({'kind': 'kv', 'key': 1}), isNull);
      expect(DataPlaneProtocol.decodeChanged(null), isNull);
    });

    test('白名单接受 null/num/String/bool', () {
      for (final v in [null, 0, 1.5, 's', true, false]) {
        expect(
            DataPlaneProtocol.decodeKvSet(DataPlaneProtocol.kvSet(
                DataPlaneProtocol.boxSettings, 'k', v)),
            isNotNull,
            reason: '$v 应合法');
      }
    });
  });

  group('敏感键', () {
    test('17 个具名键全部被识别且数量锚定', () {
      expect(DataPlaneProtocol.sensitiveKeys.length, 17);
      for (final key in DataPlaneProtocol.sensitiveKeys) {
        expect(DataPlaneProtocol.isSensitiveKey(key), isTrue, reason: key);
      }
    });

    test('GuardAccountId_ 前缀与普通键', () {
      expect(DataPlaneProtocol.isSensitiveKey('GuardAccountId_douyin'),
          isTrue);
      expect(DataPlaneProtocol.isSensitiveKey('DanmuSize'), isFalse);
    });
  });
}
