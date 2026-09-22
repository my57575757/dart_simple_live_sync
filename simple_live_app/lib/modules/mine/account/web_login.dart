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

  /// Cookie 检查进行中占位标志；在 await 之前同步置位，杜绝两次 onLoadStop 交叠
  bool _checking = false;

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    if (_finished || _checking) {
      return;
    }
    _checking = true;
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
      // onSuccess 抛异常时也要返回登录页，避免页面卡死
      try {
        args.onSuccess(cookieStr);
      } finally {
        Get.back();
      }
    } else {
      // 尚未集齐必需 Cookie，放行后续 onLoadStop 继续检查
      _checking = false;
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
