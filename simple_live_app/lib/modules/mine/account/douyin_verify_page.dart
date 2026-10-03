import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyin_webview_service.dart';

class DouyinVerifyController extends GetxController {
  String get webRid => Get.arguments as String;

  final RxBool verified = false.obs;
  InAppWebViewController? webController;
  Timer? timer;

  /// 探针：判定当前是否仍为验证码中间页，并返回页面大小
  static const String probeScript = r'''
(function(){
  var t = document.title || "";
  var b = document.body ? document.body.innerText : "";
  var captcha = t.indexOf("验证码中间页") > -1 || b.indexOf("验证码中间页") > -1;
  return {captcha: captcha, len: document.documentElement.innerHTML.length, title: t};
})()
''';

  /// 静音脚本：验证页不播放房间音视频
  static const String silenceScript = r'''
(function(){
  function stop(m){m.muted=true;try{m.pause();}catch(e){}}
  document.addEventListener('play',function(e){stop(e.target);},true);
  var list=document.querySelectorAll('video,audio');
  for(var i=0;i<list.length;i++){stop(list[i]);}
})()
''';

  /// 探针结果 -> 是否已通过验证：非验证码中间页且页面完整
  static bool isVerified(Map? probe) {
    if (probe == null || probe['captcha'] == true) return false;
    return (probe['len'] as num? ?? 0) > 20000;
  }

  void onLoadStop(InAppWebViewController controller, Uri? uri) {
    webController = controller;
    _startPolling();
  }

  void _startPolling() {
    timer?.cancel();
    timer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final probe = await webController?.evaluateJavascript(
          source: probeScript,
        );
        if (isVerified(probe is Map ? probe : null)) {
          verified.value = true;
          timer?.cancel();
        }
      } catch (_) {}
    });
  }

  /// 完成验证：登录态则回写完整 cookie，再复位 headless 会话计数
  Future<void> finish() async {
    try {
      final cookies = await CookieManager.instance().getCookies(
        url: WebUri('https://live.douyin.com'),
      );
      if (cookies.any((e) => e.name == 'sessionid' && e.value.isNotEmpty)) {
        final cookieStr = cookies
            .where((e) => e.value.isNotEmpty)
            .map((e) => '${e.name}=${e.value}')
            .join(';');
        DouyinAccountService.instance.setLoginCookie(cookieStr);
      }
    } catch (_) {}
    if (Get.isRegistered<DouyinWebViewService>()) {
      DouyinWebViewService.instance.onVerifyCompleted();
    }
    Get.back();
  }

  @override
  void onClose() {
    timer?.cancel();
    super.onClose();
  }
}

class DouyinVerifyPage extends GetView<DouyinVerifyController> {
  const DouyinVerifyPage({super.key});

  @override
  Widget build(BuildContext context) {
    final webRid = controller.webRid;
    return Scaffold(
      appBar: AppBar(
        title: const Text('抖音安全验证'),
        actions: [
          Obx(
            () => TextButton(
              onPressed:
                  controller.verified.value ? controller.finish : null,
              child: Text(
                '完成验证',
                style: TextStyle(
                  color: controller.verified.value
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).disabledColor,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            color: Theme.of(context).colorScheme.primaryContainer,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              '请按页面提示完成滑块验证，验证通过后点击右上角「完成验证」。',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
          ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(
                url: WebUri('https://live.douyin.com/$webRid'),
              ),
              initialSettings: InAppWebViewSettings(
                userAgent: WebLoginArgs.desktopUserAgent,
              ),
              initialUserScripts: UnmodifiableListView<UserScript>([
                UserScript(
                  injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
                  source: DouyinVerifyController.silenceScript,
                ),
              ]),
              onLoadStop: controller.onLoadStop,
            ),
          ),
        ],
      ),
    );
  }
}
