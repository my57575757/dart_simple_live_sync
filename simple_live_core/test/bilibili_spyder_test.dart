import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  final fixture = File('test/data/spyder.wasm');
  final appAsset = File('../simple_live_app/assets/wasm/spyder.wasm');

  test('app 打包的 spyder.wasm 与 core 测试夹具字节一致', () {
    // 防止 app asset 与测试夹具漂移：生产签名跑的是 app 那份字节
    expect(
      appAsset.existsSync(),
      isTrue,
      reason: 'simple_live_app/assets/wasm/spyder.wasm 必须存在',
    );
    expect(
      sha256.convert(appAsset.readAsBytesSync()).toString(),
      sha256.convert(fixture.readAsBytesSync()).toString(),
    );
  });

  test('spyder 4 个向量与官方页面签名完全一致（含线上抓包黄金锚点）', () async {
    final vectors =
        jsonDecode(
          File('test/data/spyder_vectors.json').readAsStringSync(),
        ) as List<dynamic>;

    final signer = await BiliSpyderSigner.fromBytes(fixture.readAsBytesSync());

    for (final raw in vectors) {
      final v = raw as Map<String, dynamic>;
      final got = signer.sign(
        v['reportJson'] as String,
        (v['rule'] as List<dynamic>).cast<int>(),
      );
      expect(got, v['s'], reason: '向量 ${v['name']}');
      expect(got.length, 128, reason: '向量 ${v['name']}');
    }
  });
}
