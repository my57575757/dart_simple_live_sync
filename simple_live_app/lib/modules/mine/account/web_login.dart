import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

class WebLoginArgs {
  final String title;
  final String startUrl;
  final String cookieUrl;
  final List<String> requiredCookies;
  final void Function(String cookie) onSuccess;

  /// 非空时启用重定向提取模式：导航到此前缀开头的 URL 时拦截，
  /// 从 URL fragment 中取出 [fragmentKey] 对应的值交给 onSuccess
  final String? redirectMatch;
  final String? fragmentKey;

  WebLoginArgs({
    required this.title,
    required this.startUrl,
    required this.cookieUrl,
    required this.requiredCookies,
    required this.onSuccess,
    this.redirectMatch,
    this.fragmentKey,
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

  /// 重定向提取模式：匹配则拦截并解析 fragment；返回 null 表示放行
  NavigationActionPolicy? handleNavigation(Uri uri) {
    if (_finished ||
        args.redirectMatch == null ||
        !uri.toString().startsWith(args.redirectMatch!)) {
      return null;
    }
    var value = Uri.splitQueryString(uri.fragment)[args.fragmentKey];
    if (value == null || value.isEmpty) {
      return null;
    }
    _finished = true;
    try {
      args.onSuccess(value);
    } finally {
      Get.back();
    }
    return NavigationActionPolicy.CANCEL;
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
        // 不提供该回调时首个文档导航会被插件中止（白屏），必须显式放行
        shouldOverrideUrlLoading: (controller, action) async {
          var url = action.request.url;
          if (url != null) {
            var policy = this.controller.handleNavigation(Uri.parse(url.toString()));
            if (policy != null) {
              return policy;
            }
          }
          return NavigationActionPolicy.ALLOW;
        },
      ),
    );
  }
}
