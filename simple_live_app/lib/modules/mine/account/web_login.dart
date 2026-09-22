import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

class WebLoginArgs {
  final String title;
  final String startUrl;
  final String cookieUrl;
  final List<String> requiredCookies;
  final void Function(String cookie) onSuccess;

  WebLoginArgs({
    required this.title,
    required this.startUrl,
    required this.cookieUrl,
    required this.requiredCookies,
    required this.onSuccess,
  });
}

class WebLoginController extends GetxController {
  WebLoginArgs get args => Get.arguments as WebLoginArgs;
  final CookieManager cookieManager = CookieManager.instance();
  bool _finished = false;

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    if (_finished) {
      return;
    }
    var cookies = await cookieManager.getCookies(
      url: WebUri(args.cookieUrl),
    );
    var names = cookies.map((e) => e.name).toSet();
    if (args.requiredCookies.every(names.contains)) {
      _finished = true;
      var cookieStr = cookies
          .where((e) => e.value.isNotEmpty)
          .map((e) => "${e.name}=${e.value}")
          .join(";");
      args.onSuccess(cookieStr);
      Get.back();
    }
  }
}

class WebLoginPage extends GetView<WebLoginController> {
  const WebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var args = controller.args;
    return Scaffold(
      appBar: AppBar(title: Text(args.title)),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri(args.startUrl)),
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: true,
        ),
        onLoadStop: controller.onLoadStop,
      ),
    );
  }
}
