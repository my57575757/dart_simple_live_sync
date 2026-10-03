import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';

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
}
