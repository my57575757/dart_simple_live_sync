import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

void main() {
  testWidgets('startWebLogin 直接打开抖音登录页并携带滑块验证参数', (
    tester,
  ) async {
    WebLoginArgs? captured;
    final service = DouyinAccountService();

    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: '/',
        getPages: [
          GetPage(name: '/', page: () => const Scaffold(body: Text('home'))),
          GetPage(
            name: RoutePath.kWebLogin,
            page: () {
              captured = Get.arguments as WebLoginArgs;
              return const Scaffold();
            },
          ),
        ],
      ),
    );

    service.startWebLogin();
    await tester.pumpAndSettle();

    expect(captured, isNotNull);
    expect(captured!.startUrl, 'https://live.douyin.com');
    expect(captured!.requiredCookies, contains('sessionid'));
    expect(captured!.userAgent, WebLoginArgs.desktopUserAgent);
  });

  group('setSite 身份解耦', () {
    final site = Sites.allSites['douyin']!.liveSite as DouyinSite;
    late DouyinAccountService service;

    setUp(() {
      service = DouyinAccountService();
    });

    tearDown(() {
      site.cookie = '';
      site.loginCookie = '';
    });

    test('已登录：site.cookie 为设备 ttwid，loginCookie 为登录 cookie', () {
      service.cookie = 'ttwid=device';
      service.loginCookie = 'sessionid=abc';
      service.logined.value = true;

      service.setSite();

      expect(site.cookie, 'ttwid=device');
      expect(site.loginCookie, 'sessionid=abc');
    });

    test('未登录：site.cookie 为设备 ttwid，loginCookie 为空', () {
      service.cookie = 'ttwid=device';
      service.loginCookie = 'sessionid=abc';
      service.logined.value = false;

      service.setSite();

      expect(site.cookie, 'ttwid=device');
      expect(site.loginCookie, '');
    });
  });
}
