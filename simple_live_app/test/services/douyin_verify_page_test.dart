import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/douyin_verify_page.dart';

void main() {
  group('isVerified', () {
    test('验证码中间页未通过', () {
      expect(
        DouyinVerifyController.isVerified({'captcha': true, 'len': 900000}),
        isFalse,
      );
    });

    test('非验证码但页面过小（跳转/加载瞬态）不算通过', () {
      expect(
        DouyinVerifyController.isVerified({'captcha': false, 'len': 500}),
        isFalse,
      );
    });

    test('非验证码且页面完整则通过', () {
      expect(
        DouyinVerifyController.isVerified({'captcha': false, 'len': 1300000}),
        isTrue,
      );
    });

    test('null 探针不通过', () {
      expect(DouyinVerifyController.isVerified(null), isFalse);
    });
  });
}
