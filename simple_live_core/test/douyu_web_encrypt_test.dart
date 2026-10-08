import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  group('DouyuWebEncrypt.calcAuth', () {
    test('复现抓包的 getH5PlayV1 auth（enc_time=1）', () {
      final auth = DouyuWebEncrypt.calcAuth(
        randStr: 'obR8K4GdwqmA41P0',
        key: 'V4YOZcehshjqrLFGr75z424170',
        encTime: 1,
        roomId: '24422',
        ts: 1791457713,
      );
      expect(auth, '7d8a1179d373533b7181ce7d9a3b38e4');
    });

    test('多次迭代（enc_time=3）', () {
      final auth = DouyuWebEncrypt.calcAuth(
        randStr: 'abc123XYZ',
        key: 'SecretKEYzzz',
        encTime: 3,
        roomId: '288016',
        ts: 1790000000,
      );
      expect(auth, 'edb267a26b9d1f3ee120809e2bc94647');
    });
  });
}
