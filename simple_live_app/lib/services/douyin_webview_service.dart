import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
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

/// 空 body 软封：抖音针对该设备会话（ttwid/设备指纹）返回 200 + 空响应，
/// 非账号级，需轮换到新的 WebView2 设备会话
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

  /// 判断 cookie 是否承载账号登录态
  static bool isAccountCookie(String cookie) => cookie.contains('sessionid');

  /// 去掉 cookie 串中的 ttwid：ttwid 是设备会话凭据，登录时捕获并保存的旧
  /// ttwid 重新注入可能已被风控；移除后 reload 由抖音重新签发
  static String stripTtwid(String cookie) {
    final pairs = parseCookiePairs(cookie)..remove('ttwid');
    return pairs.entries.map((e) => '${e.key}=${e.value}').join('; ');
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
  WebViewEnvironment? _environment;
  Future<void>? _starting;
  Completer<void>? _reloadCompleter;
  String _syncedCookie = '';

  /// 当前共享会话身份：'guest' | 'account'。
  /// cookie jar 是共享的，账号进入后必须显式清洗才能保证下一房间游客隔离
  String _sessionMode = 'guest';

  @visibleForTesting
  String get sessionModeForTesting => _sessionMode;

  int _businessFailures = 0;

  /// 设备会话轮换序号：0 用默认数据目录，软封二级自愈后递增，
  /// 新会话使用 `.WebView2.p<n>` 目录
  int _profileIndex = 0;

  @visibleForTesting
  int get profileIndexForTesting => _profileIndex;

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
    if (Platform.isWindows) {
      // 浏览器启动前清扫旧轮换目录（无锁）；占用未释放则跳过，下次启动再清
      final exeName =
          Platform.resolvedExecutable.replaceAll('\\', '/').split('/').last;
      await _sweepStaleUserDataDirs(
        current: _currentUserDataDir,
        parent: _currentUserDataDir.parent,
        prefix: '$exeName.WebView2',
      );
    }
    final firstLoad = Completer<void>();
    _firstLoad = firstLoad;
    HeadlessInAppWebView? headless;
    Object? lastError;
    for (var attempt = 0; attempt < maxStartAttempts; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(startRetryBackoff * attempt);
      }
      try {
        if (Platform.isWindows && _profileIndex > 0 && _environment == null) {
          _environment = await WebViewEnvironment.create(
            settings: WebViewEnvironmentSettings(
              userDataFolder: _currentUserDataDir.path,
            ),
          );
        }
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

  @visibleForTesting
  void completeReloadForTesting() {
    final c = _reloadCompleter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 软封一级自愈：在活会话内删除 ttwid 并 reload，由抖音签发新设备会话
  Future<void> _rotateTtwid() async {
    await CookieManager.instance()
        .deleteCookie(url: WebUri(origin), name: 'ttwid')
        .timeout(initTimeout);
    _reloadCompleter = Completer<void>();
    await _controller!.reload().timeout(initTimeout);
    await _reloadCompleter!.future.timeout(initTimeout);
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
      webViewEnvironment: _environment,
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

  /// 按请求身份同步 cookie 后 reload 同源首页；身份与 cookie 均未变则空操作
  Future<void> _applyCookie(String cookie) async {
    if (isAccountCookie(cookie)) {
      if (_sessionMode == 'account' && cookie == _syncedCookie) return;
      await _plantAccountCookies(cookie);
      _sessionMode = 'account';
      _syncedCookie = cookie;
      return;
    }
    if (_sessionMode == 'guest' && cookie == _syncedCookie) return;
    // 账号→游客（或游客 ttwid 变更）：清掉整个 cookie jar，防止残留 sessionid
    await _purgeToGuest(cookie);
    _sessionMode = 'guest';
    _syncedCookie = cookie;
  }

  /// 注入账号 cookie（剔除旧 ttwid）后 reload
  Future<void> _plantAccountCookies(String cookie) async {
    final cookieManager = CookieManager.instance();
    for (final entry
        in parseCookiePairs(stripTtwid(cookie)).entries) {
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
  }

  /// 清空 cookie jar 后回种设备 ttwid（无则不种）并 reload；
  /// 空 cookie 时由抖音在 reload 时自然重签匿名 ttwid
  Future<void> _purgeToGuest(String cookie) async {
    final cookieManager = CookieManager.instance();
    await cookieManager.deleteAllCookies().timeout(initTimeout);
    final ttwid = parseCookiePairs(cookie)['ttwid'];
    if (ttwid != null && ttwid.isNotEmpty) {
      await cookieManager
          .setCookie(
            url: WebUri(origin),
            name: 'ttwid',
            value: ttwid,
            path: '/',
          )
          .timeout(initTimeout);
    }
    _reloadCompleter = Completer<void>();
    await _controller!.reload().timeout(initTimeout);
    await _reloadCompleter!.future.timeout(initTimeout);
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
        return await _fetchOnce(webRid, cookie);
      } on DouyinSoftBlockedException {
        // 设备会话软封（200+空 body）：
        // 一级自愈：活会话内轮换 ttwid 后重试，保留登录态、不动文件
        try {
          await _rotateTtwid();
          return await _fetchOnce(webRid, cookie);
        } on DouyinSoftBlockedException {
          // 二级兜底：ttwid 无关（指纹级封禁），清目录重建后再试一次
          await _rebuild(clearUserData: true);
          return _fetchOnce(webRid, cookie);
        }
      }
    });
  }

  Future<String> _fetchOnce(String webRid, String cookie) async {
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
    } on DouyinWebViewException catch (e) {
      if (e is! DouyinSoftBlockedException) {
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
  }

  Future<void> _rebuild({bool clearUserData = false}) async {
    final old = _headless;
    final oldEnv = _environment;
    _headless = null;
    _controller = null;
    _environment = null;
    _starting = null;
    _reloadCompleter = null;
    _syncedCookie = '';
    _sessionMode = 'guest';
    _businessFailures = 0;
    try {
      await old?.dispose();
    } catch (_) {}
    try {
      await oldEnv?.dispose();
    } catch (_) {}
    // 不强删被锁的当前目录：软封时递增序号，下次启动使用 .p<n> 新目录，
    // 旧目录等浏览器进程退出后由启动清扫删除
    if (clearUserData && Platform.isWindows) {
      _profileIndex++;
    }
  }

  /// 当前会话用户数据目录：WebView2 默认目录落在可执行文件旁；
  /// 轮换序号 >0 时使用 `.WebView2.p<n>`
  Directory get _currentUserDataDir {
    final base = '${Platform.resolvedExecutable}.WebView2';
    return Directory(
      _profileIndex == 0 ? base : '$base.p$_profileIndex',
    );
  }

  @visibleForTesting
  Future<void> sweepStaleUserDataDirsForTesting({
    required Directory current,
    required Directory parent,
    required String prefix,
    Future<void> Function(Directory dir)? deleteAttempt,
  }) =>
      _sweepStaleUserDataDirs(
        current: current,
        parent: parent,
        prefix: prefix,
        deleteAttempt: deleteAttempt,
      );

  Future<void> _sweepStaleUserDataDirs({
    required Directory current,
    required Directory parent,
    required String prefix,
    Future<void> Function(Directory dir)? deleteAttempt,
  }) async {
    List<FileSystemEntity> entries;
    try {
      entries = parent.listSync(followLinks: false);
    } catch (e) {
      Log.w('DouyinWebView sweep list failed: $e');
      return;
    }
    for (final entry in entries) {
      if (entry is! Directory) continue;
      final entryPath = entry.path.replaceAll('\\', '/');
      if (entryPath == current.path.replaceAll('\\', '/')) continue;
      final name = entryPath.split('/').last;
      if (!name.startsWith(prefix)) continue;
      try {
        if (deleteAttempt != null) {
          await deleteAttempt(entry);
        } else {
          await entry.delete(recursive: true);
        }
      } catch (e) {
        // 旧浏览器进程可能仍持目录锁，下次启动再清
        Log.w('DouyinWebView sweep stale dir failed: $e');
      }
    }
  }

  @override
  void onClose() {
    if (supported) {
      final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
      site.htmlFetcher = null;
    }
    _headless?.dispose();
    _environment?.dispose();
    super.onClose();
  }
}
