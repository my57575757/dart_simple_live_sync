import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// WebView 通道错误（message 可直接展示给用户）
class DouyinWebViewException implements Exception {
  final String message;
  DouyinWebViewException(this.message);

  @override
  String toString() => message;
}

/// 以真实浏览器内核（WebView2 / Android WebView）获取抖音房间页，
/// 绕过 Dart HttpClient 的 TLS 指纹被风控识别的问题
class DouyinWebViewService extends GetxService {
  static DouyinWebViewService get instance =>
      Get.find<DouyinWebViewService>();

  static const String homeUrl = 'https://live.douyin.com/';
  static const String origin = 'https://live.douyin.com';
  static const Duration initTimeout = Duration(seconds: 20);
  static const Duration fetchTimeout = Duration(seconds: 15);
  static const Duration pollInterval = Duration(milliseconds: 250);

  /// 正常房间页约 1.2MB；验证码中间页约 6.3KB
  static const int minValidHtmlLength = 20000;

  /// flutter_inappwebview 有实现的平台；Linux / Web 不注册
  static bool get supported =>
      !kIsWeb &&
      (Platform.isWindows ||
          Platform.isAndroid ||
          Platform.isIOS ||
          Platform.isMacOS);

  /// 把 "a=b; c=d" 解析为键值对；value 允许含 '='
  static Map<String, String> parseCookiePairs(String cookie) {
    final result = <String, String>{};
    for (final part in cookie.split(';')) {
      final i = part.indexOf('=');
      if (i <= 0) continue;
      final name = part.substring(0, i).trim();
      if (name.isNotEmpty) {
        result[name] = part.substring(i + 1).trim();
      }
    }
    return result;
  }

  /// 校验 fetch 结果：HTTP 状态 / 空 body / 验证码中间页 / 异常小页面
  static void validateResponse(int? statusCode, String html) {
    if (statusCode != null && statusCode >= 400) {
      throw DouyinWebViewException('抖音返回 HTTP $statusCode，请稍后重试');
    }
    if (html.isEmpty) {
      throw DouyinWebViewException(
        '抖音返回空白页面，可能已触发风控，请稍后重试或重新登录',
      );
    }
    if (html.length < minValidHtmlLength) {
      final lower = html.toLowerCase();
      if (lower.contains('captcha') ||
          lower.contains('/verify') ||
          html.contains('滑块') ||
          html.contains('验证')) {
        throw DouyinWebViewException('抖音要求完成人机验证，请重新登录账号后重试');
      }
      throw DouyinWebViewException(
        '抖音房间页面异常（${html.length} 字节），可能触发风控，请稍后重试',
      );
    }
  }

  /// 启动脚本：页面内 fetch 房间路径，结果写入 window.__dyFetch[token]
  static String buildFetchScript(String token, String webRid) {
    final key = jsonEncode(token);
    final path = jsonEncode('/$webRid');
    return '''
(function(){
  var k=$key;
  window.__dyFetch=window.__dyFetch||{};
  window.__dyFetch[k]={s:'pending'};
  fetch($path,{credentials:'include',redirect:'follow'})
    .then(function(r){window.__dyFetch[k].code=r.status;return r.text();})
    .then(function(t){window.__dyFetch[k].html=t;window.__dyFetch[k].s='done';})
    .catch(function(e){window.__dyFetch[k].s='error';window.__dyFetch[k].e=String(e);});
})()
''';
  }

  /// 轮询脚本：序列化本次任务状态（pending/done/error）
  static String buildPollScript(String token) =>
      '(function(){var o=(window.__dyFetch||{})[${jsonEncode(token)}];'
      'return o?JSON.stringify(o):"null";})()';

  /// 静音/暂停脚本：WebView 仅用于取 HTML，永不播放媒体。
  /// 抖音首页会自动播放推荐直播，不禁止就会在隐藏窗口里发出声音、持续耗流量
  static String buildSilenceMediaScript() => '''
(function(){
  function stop(m){m.muted=true;try{m.pause();}catch(e){}}
  function stopAll(){
    var list=document.querySelectorAll('video,audio');
    for(var i=0;i<list.length;i++){stop(list[i]);}
  }
  document.addEventListener('play',function(e){stop(e.target);},true);
  stopAll();
})()
''';

  HeadlessInAppWebView? _headless;
  InAppWebViewController? _controller;
  Future<void>? _starting;
  Completer<void>? _reloadCompleter;
  String _syncedCookie = '';
  int _businessFailures = 0;
  bool _closed = false;

  /// 串行化：cookie 重注入/reload 与 fetch 不得交叠
  Future<void>? _lastTask;
  Future<T> _locked<T>(Future<T> Function() action) {
    final previous = _lastTask ?? Future<void>.value();
    final done = Completer<void>();
    _lastTask = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }

  @override
  void onInit() {
    super.onInit();
    if (!supported) return;
    final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    site.htmlFetcher = _fetchRoomHtml;
    unawaited(warmUp());
  }

  /// 后台预热；失败只记日志，首次真正使用时会再试
  Future<void> warmUp() async {
    try {
      await _ensureStarted();
    } catch (e) {
      Log.w('DouyinWebView warmUp failed: $e');
    }
  }

  Future<void> _ensureStarted() {
    return _starting ??= _start().catchError((Object e) {
      _starting = null;
      throw e;
    });
  }

  Future<void> _start() async {
    final firstLoad = Completer<void>();
    _reloadCompleter = Completer<void>();
    Future<void> inject(InAppWebViewController controller) async {
      try {
        await controller.evaluateJavascript(
          source: buildSilenceMediaScript(),
        ).timeout(fetchTimeout);
      } catch (e) {
        Log.w('DouyinWebView inject silence script failed: $e');
      }
    }

    _headless = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(homeUrl)),
      // document-start 即注册 play 拦截，抢在页面自动播放脚本前面
      onLoadStart: (controller, url) => inject(controller),
      onLoadStop: (controller, url) async {
        _controller = controller;
        await inject(controller);
        if (!firstLoad.isCompleted) firstLoad.complete();
        final reload = _reloadCompleter;
        if (reload != null && !reload.isCompleted) reload.complete();
      },
    );
    await _headless!.run();
    await firstLoad.future.timeout(initTimeout);

    final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    await _applyCookie(site.cookie);
  }

  /// 注入/更换/清除 cookie 后 reload 同源首页；cookie 未变则空操作
  Future<void> _applyCookie(String cookie) async {
    if (cookie == _syncedCookie) return;
    if (cookie.isEmpty) {
      // 匿名环境：首页已自然建立 ttwid，无需 reload
      _syncedCookie = '';
      return;
    }
    final cookieManager = CookieManager.instance();
    for (final entry in parseCookiePairs(cookie).entries) {
      await cookieManager
          .setCookie(
            url: WebUri(origin),
            name: entry.key,
            value: entry.value,
            path: '/',
          )
          .timeout(initTimeout);
    }
    _reloadCompleter = Completer<void>();
    await _controller!.reload().timeout(initTimeout);
    await _reloadCompleter!.future.timeout(initTimeout);
    _syncedCookie = cookie;
  }

  /// 平台通道调用超时包装：宿主进程被杀时通道可能永久不返回
  Future<T> _channelCall<T>(Future<T> Function() call) =>
      call().timeout(fetchTimeout);

  /// 供 DouyinSite.htmlFetcher 调用
  Future<String> _fetchRoomHtml(String webRid, String cookie) {
    return _locked(() async {
      try {
        await _ensureStarted();
        await _applyCookie(cookie);

        final currentUrl = await _channelCall(_controller!.getUrl);
        if (currentUrl == null || currentUrl.origin != origin) {
          throw StateError('抖音 WebView 会话不在同源页');
        }

        final token = 'f${DateTime.now().microsecondsSinceEpoch}';
        await _channelCall(
          () => _controller!.evaluateJavascript(
            source: buildFetchScript(token, webRid),
          ),
        );

        final deadline = DateTime.now().add(fetchTimeout);
        while (true) {
          await Future<void>.delayed(pollInterval);
          final raw = await _channelCall(
            () => _controller!.evaluateJavascript(
              source: buildPollScript(token),
            ),
          );
          final obj = jsonDecode(raw as String) as Map?;
          if (obj == null || obj['s'] == 'pending') {
            if (DateTime.now().isAfter(deadline)) {
              throw DouyinWebViewException(
                '获取抖音房间页面超时（${fetchTimeout.inSeconds} 秒）',
              );
            }
            continue;
          }
          if (obj['s'] == 'error') {
            throw DouyinWebViewException('页面请求失败：${obj['e']}');
          }
          validateResponse(obj['code'] as int?, obj['html'] as String);
          _businessFailures = 0;
          return obj['html'] as String;
        }
      } on DouyinWebViewException {
        _businessFailures++;
        if (_businessFailures >= 3) {
          unawaited(_rebuild());
        }
        rethrow;
      } catch (e) {
        // 通道级异常（控制器失效等）：立即销毁，下次调用重建
        Log.w('DouyinWebView channel error: $e');
        unawaited(_rebuild());
        rethrow;
      }
    });
  }

  Future<void> _rebuild() async {
    final old = _headless;
    _headless = null;
    _controller = null;
    _starting = null;
    _reloadCompleter = null;
    _syncedCookie = '';
    _businessFailures = 0;
    try {
      await old?.dispose();
    } catch (_) {}
    if (!_closed) {
      try {
        await _ensureStarted();
      } catch (e) {
        Log.w('DouyinWebView rebuild failed: $e');
      }
    }
  }

  @override
  void onClose() {
    _closed = true;
    if (supported) {
      final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
      site.htmlFetcher = null;
    }
    _headless?.dispose();
    super.onClose();
  }
}
