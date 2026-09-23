import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
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

  /// 重定向模式：Twitch 授权按钮会被周期性完整性校验反复禁用，
  /// 用户手动点击常落在禁用窗口；轮询在启用窗口自动点击一次
  Timer? _pollTimer;

  void _startPolling(InAppWebViewController controller) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_finished) return;
      try {
        await controller.evaluateJavascript(source: _autoAuthorizeScript);
      } catch (_) {}
    });
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) async {
    // 重定向提取模式：轮询处理授权按钮
    if (args.redirectMatch != null) {
      if (_finished) return;
      _startPolling(controller);
      return;
    }
    // 空 cookieUrl 时不能检查（requiredCookies 为空时 every 会空真误判成功）
    if (args.cookieUrl.isEmpty || _finished || _checking) {
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

  /// 重定向提取模式：匹配则拦截并解析 fragment；返回 true 表示已处理
  bool handleNavigation(Uri uri) {
    if (_finished ||
        args.redirectMatch == null ||
        !uri.toString().startsWith(args.redirectMatch!)) {
      return false;
    }
    _finished = true;
    var value = Uri.splitQueryString(uri.fragment)[args.fragmentKey];
    if (value == null || value.isEmpty) {
      // 已回到重定向 URI 但没有令牌（如用户拒绝授权）
      SmartDialog.showToast("未获得授权");
      _pollTimer?.cancel();
      Get.back();
      return true;
    }
    try {
      args.onSuccess(value);
    } finally {
      _pollTimer?.cancel();
      Get.back();
    }
    return true;
  }

  /// onLoadStart 兜底拦截：部分机型 302 到 localhost 时
  /// shouldOverrideUrlLoading 不触发
  void onLoadStart(InAppWebViewController controller, Uri? uri) {
    if (args.redirectMatch != null && !_finished) {
      // onLoadStop 在部分页面不触发，提前启动轮询
      _startPolling(controller);
    }
    if (uri == null ||
        _finished ||
        args.redirectMatch == null ||
        !uri.toString().startsWith(args.redirectMatch!)) {
      return;
    }
    // 必须在 Get.back() 之前停止加载，否则页面销毁后操作 controller
    controller.stopLoading();
    handleNavigation(uri);
  }

  @override
  void onClose() {
    _pollTimer?.cancel();
    super.onClose();
  }
}

class WebLoginPage extends GetView<WebLoginController> {
  const WebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var args = controller.args;
    // 重定向提取模式（Twitch）：不用 CDP Fetch 实现的
    // shouldOverrideUrlLoading（POST→302 到 localhost 时会静默挂起），
    // 改依赖 WebView2 NavigationStarting 触发的 onLoadStart，最可靠
    var redirectMode = args.redirectMatch != null;
    var webView = InAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(args.startUrl)),
      initialSettings: InAppWebViewSettings(
        useShouldOverrideUrlLoading: !redirectMode,
      ),
      onLoadStop: controller.onLoadStop,
      onLoadStart: controller.onLoadStart,
      // 不提供该回调时首个文档导航会被插件中止（白屏），必须显式放行
      shouldOverrideUrlLoading: redirectMode
          ? null
          : (controller, action) async {
              return NavigationActionPolicy.ALLOW;
            },
    );
    return Scaffold(
      appBar: AppBar(title: Text(args.title)),
      body: Column(
        children: [
          if (redirectMode)
            Container(
              width: double.infinity,
              color: Theme.of(context).colorScheme.primaryContainer,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Text(
                "若点击「授权」无反应，请稍候，页面会在按钮可用时自动确认授权。",
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                ),
              ),
            ),
          Expanded(child: webView),
        ],
      ),
    );
  }
}

/// 授权按钮进入启用窗口时自动点击一次（仅点击一次，防止重复提交）
const String _autoAuthorizeScript = r'''
(function(){
  if(window.__autoAuthorized) return;
  var btns=document.querySelectorAll('button');
  for(var i=0;i<btns.length;i++){
    var b=btns[i];
    var t=String(b.innerText||"");
    if(!b.disabled&&(t.indexOf("授权")>-1||t.indexOf("Authorize")>-1)){
      window.__autoAuthorized=true;
      b.click();
      return;
    }
  }
})()
''';
