import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  final douyuSite = Sites.allSites['douyu']!.liveSite as DouyuSite;
  final twitchSite = Sites.allSites['twitch']!.liveSite as TwitchSite;
  final biliSite = Sites.allSites['bilibili']!.liveSite as BiliBiliSite;
  final huyaSite = Sites.allSites['huya']!.liveSite as HuyaSite;

  tearDown(() {
    douyuSite.cookie = '';
    twitchSite.oauthToken = '';
    twitchSite.userLogin = '';
    twitchSite.clientId = TwitchSite.kWebClientId;
    biliSite.cookie = '';
    biliSite.userId = 0;
    huyaSite.cookie = '';
  });

  group('BiliBiliAccountService.setBorrowedLoginCookie', () {
    test('纯内存写入并同步 site.cookie/userId，不写 KV、不翻转 logined/name；null 清空',
        () {
      // 不注册 LocalStorageService：借用路径若误触 KV 写入，Get.find 会同步抛错
      final service = BiliBiliAccountService();
      service.setBorrowedLoginCookie(
          'SESSDATA=abc; DedeUserID=44630239; bili_jct=csrf;');

      expect(service.cookie, 'SESSDATA=abc; DedeUserID=44630239; bili_jct=csrf;');
      expect(biliSite.cookie,
          'SESSDATA=abc; DedeUserID=44630239; bili_jct=csrf;',
          reason: 'getRoomPlayInfo/getRoomDetail 读 site.cookie 才解锁登录档位');
      expect(biliSite.userId, 44630239,
          reason: '弹幕 args.uid 从 cookie 的 DedeUserID 恢复');
      expect(service.logined.value, isFalse, reason: '借用不翻转 logined');
      expect(service.name.value, '未登录');

      service.setBorrowedLoginCookie(null);
      expect(service.cookie, '');
      expect(biliSite.cookie, '');
      expect(biliSite.userId, 0);
      expect(service.logined.value, isFalse);
    });
  });

  group('HuyaAccountService.setBorrowedLoginCookie', () {
    test('纯内存写入并同步 site.cookie，不写 KV、不翻转 logined/name；null 清空',
        () {
      // 不注册 LocalStorageService：借用路径若误触 KV 写入，Get.find 会同步抛错
      final service = HuyaAccountService();
      service.setBorrowedLoginCookie(
          'udb_biztoken=abc; yyuid=123456; guid=g1;');

      expect(service.cookie, 'udb_biztoken=abc; yyuid=123456; guid=g1;');
      expect(huyaSite.cookie, 'udb_biztoken=abc; yyuid=123456; guid=g1;',
          reason: 'getRoomDetail 构造 HuyaDanmakuArgs 读 site.cookie');
      expect(service.logined.value, isFalse, reason: '借用不翻转 logined');
      expect(service.name.value, '未登录');

      service.setBorrowedLoginCookie(null);
      expect(service.cookie, '');
      expect(huyaSite.cookie, '');
      expect(service.logined.value, isFalse);
    });
  });

  group('DouyuAccountService.setBorrowedLoginCookie', () {
    test('纯内存写入并同步 site.cookie，不写 KV、不翻转 logined/name；null 清空',
        () {
      // 本测试不注册 LocalStorageService：借用路径若误触 KV 写入，
      // Get.find 会同步抛错使测试失败
      final service = DouyuAccountService();
      service.setBorrowedLoginCookie('acf_uid=1; acf_stk=borrowed');

      expect(service.cookie, 'acf_uid=1; acf_stk=borrowed');
      expect(douyuSite.cookie, 'acf_uid=1; acf_stk=borrowed',
          reason: 'getRoomDetail 构造 DouyuDanmakuArgs 读 site.cookie');
      expect(service.logined.value, isFalse, reason: '借用不翻转 logined');
      expect(service.name.value, '未登录');

      service.setBorrowedLoginCookie(null);
      expect(service.cookie, '');
      expect(douyuSite.cookie, '');
      expect(service.logined.value, isFalse);
    });
  });

  group('TwitchAccountService.setBorrowedLoginCreds', () {
    test('三元组写入并同步 site 字段，clientId 空回落 kWebClientId；null 清空',
        () {
      final service = TwitchAccountService();
      service.setBorrowedLoginCreds({
        'oauthToken': 'oauth-abc',
        'userLogin': 'user1',
        'clientId': 'cid1',
      });

      expect(service.oauthToken, 'oauth-abc');
      expect(service.userLogin, 'user1');
      expect(service.clientId, 'cid1');
      expect(twitchSite.oauthToken, 'oauth-abc',
          reason: 'TwitchSite.getRoomDetail 构造 args 读 site 字段');
      expect(twitchSite.userLogin, 'user1');
      expect(twitchSite.clientId, 'cid1');
      expect(service.configured.value, isFalse,
          reason: '借用不翻转 configured（本地登录态）');

      // clientId 缺失 → kWebClientId
      service.setBorrowedLoginCreds({
        'oauthToken': 'oauth-abc',
        'userLogin': 'user1',
      });
      expect(service.clientId, TwitchSite.kWebClientId);
      expect(twitchSite.clientId, TwitchSite.kWebClientId);

      // null 清空：秘密字段归零；clientId 与 setSite 一致回落 kWebClientId
      service.setBorrowedLoginCreds(null);
      expect(service.oauthToken, '');
      expect(service.userLogin, '');
      expect(twitchSite.oauthToken, '');
      expect(twitchSite.userLogin, '');
      expect(service.configured.value, isFalse);
    });
  });
}
