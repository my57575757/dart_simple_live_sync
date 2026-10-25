import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
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
  group('buildCredentialAutofillScript', () {
    const douyu = LoginCredential(
      account: '',
      password: '',
      onSave: _noop,
      onClear: _noopClear,
    );
    const huya = LoginCredential(
      account: '',
      password: '',
      onSave: _noop,
      onClear: _noopClear,
      accountHint: '手机号 / 虎牙号',
      passwordTabText: '',
      injectHost: 'aq.huya.com',
      accountSelector: '#username',
      passwordSelector: '#password',
      bootstrapScript: _huyaBootstrap,
    );

    test('斗鱼默认选择器保持不变（回归保护）', () {
      final js =
          buildCredentialAutofillScript(cred: douyu, account: 'a', password: 'p');
      expect(js, contains(jsonEncode('input[name="nicknameOrPhone"]')));
      expect(js, contains(jsonEncode('input[type=password][name="password"]')));
      expect(js, isNot(contains('udbSdkWeb')));
    });

    test('虎牙：向壳页 postMessage 握手，且只发一次', () {
      final js =
          buildCredentialAutofillScript(cred: huya, account: 'a', password: 'p');
      expect(js, contains('udbSdkWeb'));
      expect(js, contains("fnName:'login'"));
      expect(js, contains('__huyaLoginBoot'));
      // 幂等：bootstrap 以「已引导则 return」开头，轮询重复执行不会二次初始化
      expect(js.indexOf('if(window.__huyaLoginBoot)') < js.indexOf('postMessage'),
          isTrue);
    });

    test('虎牙：填充 #username/#password，监听登录成功跳回主站', () {
      final js =
          buildCredentialAutofillScript(cred: huya, account: 'acc', password: 'pw');
      expect(js, contains(jsonEncode('#username')));
      expect(js, contains(jsonEncode('#password')));
      expect(js, contains(jsonEncode('acc')));
      expect(js, contains(jsonEncode('pw')));
      expect(js, contains('_loginSuccess'));
      expect(js, contains('https://www.huya.com/'));
    });
  });

  group('HuyaAccountService 凭据记忆', () {
    late _FakeKv kv;
    setUp(() {
      kv = _FakeKv();
      Get.put<LocalStorageService>(kv);
    });
    tearDown(Get.reset);

    test('onInit 从 KV 读回账号密码', () {
      kv.store[LocalStorageService.kHuyaLoginAccount] = '13800000000';
      kv.store[LocalStorageService.kHuyaLoginPassword] = 'secret';
      final service = HuyaAccountService()..onInit();
      expect(service.loginAccount, '13800000000');
      expect(service.loginPassword, 'secret');
    });

    test('onSave 经 saveCredential 持久化到虎牙专用 key', () {
      final service = HuyaAccountService();
      service.saveCredential('huya123', 'pw2');
      expect(kv.store[LocalStorageService.kHuyaLoginAccount], 'huya123');
      expect(kv.store[LocalStorageService.kHuyaLoginPassword], 'pw2');
      expect(service.loginAccount, 'huya123');
    });

    test('onClear 清空账号密码', () {
      final service = HuyaAccountService();
      service.saveCredential('huya123', 'pw2');
      service.clearCredential();
      expect(kv.store[LocalStorageService.kHuyaLoginAccount], '');
      expect(kv.store[LocalStorageService.kHuyaLoginPassword], '');
      expect(service.loginPassword, '');
    });

    test('setSyncedCredential：非空字段覆盖，null 字段保留本地值', () {
      final service = HuyaAccountService()
        ..loginAccount = 'local'
        ..loginPassword = 'localPw';
      service.setSyncedCredential('cloud', null);
      expect(service.loginAccount, 'cloud');
      expect(service.loginPassword, 'localPw');
      expect(kv.store[LocalStorageService.kHuyaLoginAccount], 'cloud');
      expect(kv.store.containsKey(LocalStorageService.kHuyaLoginPassword), false);
    });

    test('setSyncedCredential：空串显式清空（对端取消记住）', () {
      final service = HuyaAccountService()
        ..loginAccount = 'local'
        ..loginPassword = 'localPw';
      service.setSyncedCredential('', '');
      expect(service.loginAccount, '');
      expect(service.loginPassword, '');
      expect(kv.store[LocalStorageService.kHuyaLoginAccount], '');
      expect(kv.store[LocalStorageService.kHuyaLoginPassword], '');
    });

    test('buildWebLoginArgs 直达虎牙登录壳页并携带凭据配置', () {
      final service = HuyaAccountService()
        ..loginAccount = 'acc'
        ..loginPassword = 'pw';

      final args = service.buildWebLoginArgs();

      expect(args.startUrl, 'https://aq.huya.com/p/udb_login.html');
      expect(args.cookieUrl, 'https://www.huya.com');
      expect(args.requiredCookies, contains('udb_biztoken'));
      expect(args.useShouldOverrideUrlLoading, isFalse);
      final cred = args.credential;
      expect(cred, isNotNull);
      expect(cred!.injectHost, 'aq.huya.com');
      expect(cred.account, 'acc');
      expect(cred.password, 'pw');
      expect(cred.accountSelector, '#username');
      expect(cred.passwordSelector, '#password');
      expect(cred.bootstrapScript, isNotEmpty);
    });
  });
}

void _noop(String account, String password) {}

void _noopClear() {}

const _huyaBootstrap = '''
(function(){
  if(window.__huyaLoginBoot) return;
  window.__huyaLoginBoot = 1;
  window.addEventListener('message', function(ev){
    try { var m = JSON.parse(ev.data); } catch (e) { return; }
    if (m && (m.fnName === '_loginSuccess' || m.fnName === '_loginAuthSuccess')) {
      location.href = 'https://www.huya.com/';
    }
  });
  window.postMessage(JSON.stringify({origin:'udbSdkWeb', opt:{appid:'5002'}, fnName:'login'}), '*');
})();
''';
