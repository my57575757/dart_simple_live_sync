import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 内存 KV：重写 get/set/remove，避免 Hive 初始化
class _FakeKv extends LocalStorageService {
  final Map<Object, Object?> store = {};
  @override
  T getValue<T>(dynamic key, T defaultValue) =>
      store.containsKey(key) ? store[key] as T : defaultValue;
  @override
  Future<void> setValue<T>(dynamic key, T value) async {
    store[key] = value;
  }
  @override
  Future<void> removeValue<T>(dynamic key) async {
    store.remove(key);
  }
}

void main() {
  late _FakeKv kv;

  setUp(() {
    kv = _FakeKv();
    Get.put<LocalStorageService>(kv);
    // configured=false：setLoginCookie 的 guard 注册在网络请求前返回，
    // 既不抛 Get.find 也不发起 HTTP
    Get.put<GuardServerService>(GuardServerService());
  });
  tearDown(Get.reset);

  group('buildWebLoginArgs / 自动填充脚本', () {
    test('直达 live.douyin.com、密码登录 tab、手机号/密码选择器与凭据', () {
      final service = DouyinAccountService()
        ..loginAccount = '13800000000'
        ..loginPassword = 'secret';

      final args = service.buildWebLoginArgs();

      expect(args.startUrl, 'https://live.douyin.com');
      expect(args.cookieUrl, 'https://live.douyin.com');
      expect(args.requiredCookies, contains('sessionid'));
      expect(args.userAgent, WebLoginArgs.desktopUserAgent);
      final cred = args.credential!;
      expect(cred.account, '13800000000');
      expect(cred.password, 'secret');
      expect(cred.accountHint, '手机号');
      expect(cred.passwordTabText, '密码登录');
      expect(cred.injectHost, 'live.douyin.com');
      expect(cred.accountSelector, 'input#normal-input[type="tel"]');
      expect(cred.passwordSelector, 'input#normal-input[type="password"]');
    });

    test('填充脚本会先点「密码登录」tab 再填两个输入框', () {
      final service = DouyinAccountService()
        ..loginAccount = 'acc'
        ..loginPassword = 'pw';
      final js = buildCredentialAutofillScript(
        cred: service.buildWebLoginArgs().credential!,
        account: 'acc',
        password: 'pw',
      );
      // 切到密码登录 tab
      expect(js, contains(jsonEncode('密码登录')));
      expect(js, contains('.click()'));
      // 精确命中手机号/密码两个输入框（页面上两个 id 同名，靠 type 区分）
      expect(js, contains(jsonEncode('input#normal-input[type="tel"]')));
      expect(js, contains(jsonEncode('input#normal-input[type="password"]')));
      expect(js, contains(jsonEncode('acc')));
      expect(js, contains(jsonEncode('pw')));
      // 抖音无自定义壳页握手
      expect(js, isNot(contains('__huyaLoginBoot')));
    });
  });

  group('DouyinAccountService 凭据记忆', () {
    test('onInit 从 KV 读回账号密码', () {
      kv.store[LocalStorageService.kDouyinLoginAccount] = '13800000000';
      kv.store[LocalStorageService.kDouyinLoginPassword] = 'secret';
      final service = DouyinAccountService()..onInit();
      expect(service.loginAccount, '13800000000');
      expect(service.loginPassword, 'secret');
    });

    test('saveCredential 持久化到抖音专用 key', () {
      final service = DouyinAccountService();
      service.saveCredential('13800000000', 'pw2');
      expect(kv.store[LocalStorageService.kDouyinLoginAccount], '13800000000');
      expect(kv.store[LocalStorageService.kDouyinLoginPassword], 'pw2');
      expect(service.loginAccount, '13800000000');
    });

    test('clearCredential 清空账号密码但保留登录态', () {
      final service = DouyinAccountService()
        ..loginAccount = '13800000000'
        ..loginPassword = 'pw';
      service.clearCredential();
      expect(kv.store[LocalStorageService.kDouyinLoginAccount], '');
      expect(kv.store[LocalStorageService.kDouyinLoginPassword], '');
      expect(service.loginPassword, '');
    });

    test('setSyncedCredential：null 保留本地值，空串显式清空', () {
      final service = DouyinAccountService()
        ..loginAccount = 'local'
        ..loginPassword = 'localPw';
      service.setSyncedCredential('cloud', null);
      expect(service.loginAccount, 'cloud');
      expect(service.loginPassword, 'localPw');
      expect(kv.store[LocalStorageService.kDouyinLoginAccount], 'cloud');
      expect(
        kv.store.containsKey(LocalStorageService.kDouyinLoginPassword),
        isFalse,
      );

      service.setSyncedCredential('', '');
      expect(service.loginAccount, '');
      expect(service.loginPassword, '');
      expect(kv.store[LocalStorageService.kDouyinLoginPassword], '');
    });
  });

  group('applyCloudLoginData 云端恢复判定', () {
    test('云端含有效 sessionid 且与本地不同：写入登录态+凭据并返回 true', () {
      final service = DouyinAccountService();
      final ok = service.applyCloudLoginData(
        {
          'douyinData': 'sessionid=newsess; ttwid=x',
          'douyinAccount': '13800000000',
          'douyinPassword': 'pw',
        },
        requireDifferent: true,
      );
      expect(ok, isTrue);
      expect(service.logined.value, isTrue);
      expect(service.loginCookie, 'sessionid=newsess; ttwid=x');
      expect(kv.store[LocalStorageService.kDouyinLoginCookie],
          'sessionid=newsess; ttwid=x');
      expect(service.loginAccount, '13800000000');
    });

    test('云端 cookie 无 sessionid：判定无效，不动本地', () {
      final service = DouyinAccountService()..loginCookie = 'sessionid=old';
      final ok = service.applyCloudLoginData(
        {'douyinData': 'ttwid=onlydevice'},
        requireDifferent: true,
      );
      expect(ok, isFalse);
      expect(service.loginCookie, 'sessionid=old');
    });

    test('requireDifferent：云端与本地是同一份（云端也已失效）返回 false', () {
      final service = DouyinAccountService()
        ..loginCookie = 'sessionid=same'
        ..logined.value = true;
      final ok = service.applyCloudLoginData(
        {'douyinData': 'sessionid=same'},
        requireDifferent: true,
      );
      expect(ok, isFalse);
    });

    test('本地未登录时不要求差异：云端任一份有效 cookie 即可恢复', () {
      final service = DouyinAccountService();
      final ok = service.applyCloudLoginData(
        {'douyinData': 'sessionid=abc'},
        requireDifferent: false,
      );
      expect(ok, isTrue);
      expect(service.logined.value, isTrue);
    });
  });
}
