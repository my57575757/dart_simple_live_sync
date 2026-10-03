import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// WebView 通道错误（message 可直接展示给用户）
class DouyinWebViewException implements Exception {
  final String message;
  DouyinWebViewException(this.message);

  @override
  String toString() => message;
}

/// 空 body 软封：抖音针对该设备会话（ttwid/设备指纹）返回 200 + 空响应，
/// 非账号级，需清除 WebView2 用户数据目录换新设备会话
class DouyinSoftBlockedException extends DouyinWebViewException {
  DouyinSoftBlockedException(super.message);
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

  /// 销毁后浏览器进程异步退出（持用户数据目录锁），启动失败时按此间隔退避重试
  static const Duration startRetryBackoff = Duration(seconds: 1);
  static const int maxStartAttempts = 3;

  /// 清除用户数据目录时，进程尚未释放目录锁，按此间隔退避重试
  static const Duration eraseRetryBackoff = Duration(seconds: 1);
  static const int maxEraseAttempts = 3;

  /// 连续空响应（软封）达到此次数后清除设备会话
  static const int softBlockedEraseThreshold = 2;

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
      throw DouyinSoftBlockedException(
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
  int _softBlockedFailures = 0;

  /// 当前软封周期是否已弹过引导（去重）；成功取房或重建后复位
  bool _softBlockedPromptShown = false;

  /// 软封时的登录引导动作；默认弹窗引导去验证页，测试可替换；参数为房间号
  @visibleForTesting
  Future<void> Function(String webRid) softBlockedPrompt = _showLoginGuideDialog;

  /// 软封引导弹窗：风控拦截（登录态/匿名均可能发生），确认后打开专门验证页完成滑块
  static Future<void> _showLoginGuideDialog(String webRid) async {
    final goVerify = await Get.dialog<bool>(
      AlertDialog(
        title: const Text('需要完成抖音验证'),
        content: const Text('访问触发了抖音安全验证，完成滑块验证后即可继续观看。'),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text('稍后'),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('去验证'),
          ),
        ],
      ),
    );
    if (goVerify == true) {
      DouyinAccountService.instance.startVerify(webRid);
    }
  }

  Future<void> _runSoftBlockedPrompt(String webRid) async {
    try {
      await softBlockedPrompt(webRid);
    } catch (e) {
      Log.w('DouyinWebView soft-blocked prompt failed: $e');
    }
  }

  /// 用户在专门验证页完成滑块后调用：复位软封计数与引导标记，避免后续误清除
  void onVerifyCompleted() {
    _softBlockedFailures = 0;
    _softBlockedPromptShown = false;
  }

  /// 测试注入：覆盖单次删除动作，避免测试触碰真实 WebView2 目录
  @visibleForTesting
  Future<void> Function(Directory dir)? debugDeleteAttempt;

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

  Completer<void>? _firstLoad;

  Future<void> _start() async {
    final firstLoad = Completer<void>();
    _firstLoad = firstLoad;
    HeadlessInAppWebView? headless;
    Object? lastError;
    for (var attempt = 0; attempt < maxStartAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(startRetryBackoff * attempt);
      }
      try {
        headless ??= _buildHeadless(firstLoad);
        await headless.run();
        _controller = headless.webViewController;
        await firstLoad.future.timeout(initTimeout);
        final site =
            Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
        await _applyCookie(site.cookie);
        _headless = headless;
        return;
      } on PlatformException catch (e) {
        lastError = e;
        Log.w('DouyinWebView start attempt ${attempt + 1} failed: $e');
      }
    }
    throw lastError!;
  }

  @visibleForTesting
  void completeFirstLoadForTesting() {
    final c = _firstLoad;
    if (c != null && !c.isCompleted) c.complete();
  }

  HeadlessInAppWebView _buildHeadless(Completer<void> firstLoad) {
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

    return HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(homeUrl)),
      // 必须伪装桌面 UA：移动 UA 会被服务端 302 到 webcast.amemv.com 移动 reflow 页，
      // 页面内 fetch 跟随跨域重定向后因无 CORS 头失败（Windows WebView2 默认桌面 UA 不受影响）
      initialSettings: InAppWebViewSettings(
        userAgent: DouyinSite.kDefaultUserAgent,
      ),
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

  @visibleForTesting
  Future<String> fetchRoomHtmlForTesting(String webRid, String cookie) =>
      _fetchRoomHtml(webRid, cookie);

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
          _softBlockedFailures = 0;
          _softBlockedPromptShown = false;
          return obj['html'] as String;
        }
      } on DouyinWebViewException catch (e) {
        if (e is DouyinSoftBlockedException) {
          _softBlockedFailures++;
          if (!_softBlockedPromptShown) {
            _softBlockedPromptShown = true;
            unawaited(_runSoftBlockedPrompt(webRid));
          }
          if (_softBlockedFailures >= softBlockedEraseThreshold) {
            unawaited(_rebuild(clearUserData: true));
          }
        } else {
          _businessFailures++;
          if (_businessFailures >= 3) {
            unawaited(_rebuild());
          }
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

  Future<void> _rebuild({bool clearUserData = false}) async {
    final old = _headless;
    _headless = null;
    _controller = null;
    _starting = null;
    _reloadCompleter = null;
    _syncedCookie = '';
    _businessFailures = 0;
    _softBlockedFailures = 0;
    _softBlockedPromptShown = false;
    try {
      await old?.dispose();
    } catch (_) {}
    // 不立即重建：WebView2 浏览器进程异步退出，退出前持有用户数据目录锁。
    // 软封时清除目录换新设备会话；下次请求按需启动，启动失败再退避重试
    if (clearUserData && Platform.isWindows) {
      await _eraseUserDataDir(_userDataDir);
    }
  }

  /// 默认用户数据目录：WebView2 以 nullptr 创建时落在可执行文件旁
  Directory get _userDataDir =>
      Directory('${Platform.resolvedExecutable}.WebView2');

  @visibleForTesting
  Future<void> eraseUserDataDirForTesting(Directory dir) =>
      _eraseUserDataDir(dir);

  Future<void> _eraseUserDataDir(Directory dir) async {
    Object? lastError;
    for (var attempt = 0; attempt < maxEraseAttempts;attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(eraseRetryBackoff * attempt);
      }
      try {
        final injected = debugDeleteAttempt;
        if (injected != null) {
          await injected(dir);
        } else if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
        return;
      } catch (e) {
        lastError = e;
        Log.w('DouyinWebView erase user data dir attempt ${attempt + 1} failed: $e');
      }
    }
    Log.w('DouyinWebView erase user data dir gave up: $lastError');
  }

  @override
  void onClose() {
    if (supported) {
      final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
      site.htmlFetcher = null;
    }
    _headless?.dispose();
    super.onClose();
  }
}
