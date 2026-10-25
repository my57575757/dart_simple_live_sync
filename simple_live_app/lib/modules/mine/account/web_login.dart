import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import 'web_load_watchdog.dart';

/// 登录页凭据记忆配置：WebView 顶部显示原生账号密码条，
/// 页面加载后用 JS 自动填入网页登录表单（不自动提交，登录/验证仍由用户完成）。
/// 当前填充逻辑对应斗鱼 passport.douyu.com 登录页。
class LoginCredential {
  final String account;
  final String password;
  final String accountHint;

  /// 桌面 UA 下页面默认停在验证码登录，自动填充前需点击该文本的 tab
  final String passwordTabText;

  /// 登录表单账号/密码输入框的 CSS 选择器（斗鱼 passport 与虎牙壳页不同）
  final String accountSelector;
  final String passwordSelector;

  /// 页面加载后先执行的引导脚本（如虎牙登录页是嵌入式壳页，需模拟父页
  /// postMessage 握手才渲染表单）；随每次填充轮询执行，脚本自身须幂等
  final String? bootstrapScript;

  /// 仅在该主机名下的页面执行填充 JS
  final String injectHost;
  final void Function(String account, String password) onSave;
  final void Function() onClear;

  const LoginCredential({
    required this.account,
    required this.password,
    required this.onSave,
    required this.onClear,
    this.accountHint = "手机号 / 昵称",
    this.passwordTabText = "密码登录",
    this.injectHost = "passport.douyu.com",
    this.accountSelector = 'input[name="nicknameOrPhone"]',
    this.passwordSelector = 'input[type=password][name="password"]',
    this.bootstrapScript,
  });
}

/// 生成登录页自动填充脚本：先跑（幂等的）平台引导脚本，再把账号密码写入表单。
/// 账号/密码经 jsonEncode 转义；选择器仅允许由调用方写死，不接受用户输入。
String buildCredentialAutofillScript({
  required LoginCredential cred,
  required String account,
  required String password,
}) {
  final tabText = jsonEncode(cred.passwordTabText);
  final accountJson = jsonEncode(account);
  final passwordJson = jsonEncode(password);
  final accountSelector = jsonEncode(cred.accountSelector);
  final passwordSelector = jsonEncode(cred.passwordSelector);
  final bootstrap = cred.bootstrapScript ?? "";
  return '''
(function(){
  $bootstrap
  var acc = document.querySelector($accountSelector);
  var pwd = document.querySelector($passwordSelector);
  if(!acc || !pwd || !acc.offsetParent || !pwd.offsetParent){
    if($tabText){
      var divs = document.getElementsByTagName('div');
      for(var i=0;i<divs.length;i++){
        var d = divs[i];
        if(d.children.length===0 && (d.innerText||'').trim()===$tabText && d.offsetParent){
          d.click();
          break;
        }
      }
    }
    return false;
  }
  if(acc.value===$accountJson && pwd.value===$passwordJson) return true;
  var setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
  setter.call(acc, $accountJson);
  acc.dispatchEvent(new Event('input',{bubbles:true}));
  acc.dispatchEvent(new Event('change',{bubbles:true}));
  setter.call(pwd, $passwordJson);
  pwd.dispatchEvent(new Event('input',{bubbles:true}));
  pwd.dispatchEvent(new Event('change',{bubbles:true}));
  return true;
})()
''';
}

class WebLoginArgs {
  static const String desktopUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36";

  final String title;
  final String startUrl;
  final String cookieUrl;
  final List<String> requiredCookies;
  final void Function(String cookie) onSuccess;

  /// 非空时启用重定向提取模式：导航到此前缀开头的 URL 时拦截，
  /// 从 URL fragment 中取出 [fragmentKey] 对应的值交给 onSuccess
  final String? redirectMatch;
  final String? fragmentKey;

  /// 非空时用该 UA 覆盖 WebView 默认 UA（如虎牙需强制桌面页登录）
  final String? userAgent;

  /// 非空时在 WebView 顶部显示账号密码记忆条，并自动填充网页登录表单
  final LoginCredential? credential;

  /// 是否启用 shouldOverrideUrlLoading。Windows 端该能力基于 CDP Fetch 拦截，
  /// 表单登录的 POST→302 顶层跳转命中其缺陷（插件 DLL 访问违例闪退），
  /// 此类登录流程（斗鱼）必须传 false，登录成功改由 onLoadStop 查 cookie 判定
  final bool useShouldOverrideUrlLoading;

  WebLoginArgs({
    required this.title,
    required this.startUrl,
    required this.cookieUrl,
    required this.onSuccess,
    required this.requiredCookies,
    this.redirectMatch,
    this.fragmentKey,
    this.userAgent,
    this.credential,
    this.useShouldOverrideUrlLoading = true,
  });
}

class WebLoginController extends GetxController {
  /// 无参深链（Get.toNamed(kWebLogin) 不带 arguments）或类型不符时返回 null：
  /// 调用方必须判空走安全默认/关闭页面，禁止 cast 崩溃。
  WebLoginArgs? get args {
    final a = Get.arguments;
    return a is WebLoginArgs ? a : null;
  }

  /// 懒解析：单测构造控制器时无 InAppWebView 平台实例，eager 字段初始化会炸
  CookieManager get cookieManager => CookieManager.instance();
  bool _finished = false;

  /// Cookie 检查进行中占位标志；在 await 之前同步置位，杜绝两次 onLoadStop 交叠
  bool _checking = false;

  /// TTGW 444 封锁页（Access Denied / Oncall ID）自动重载退避秒数
  static const List<int> _blockRetryDelays = [3, 5, 10, 15];
  int _blockRetries = 0;

  /// 封锁页特征同时命中才判定，避免误伤正常页面
  static const String _blockDetectScript = r'''
(function(){
  var b = document.body ? document.body.innerText : "";
  var t = (document.title || "") + "|" + b.slice(0, 300);
  return t.indexOf("Access Denied") > -1 &&
         t.indexOf("X-TT-System-Error") > -1 &&
         t.indexOf("Oncall ID") > -1;
})()
''';

  /// 重定向模式：Twitch 授权按钮会被周期性完整性校验反复禁用，
  /// 用户手动点击常落在禁用窗口；轮询在启用窗口自动点击一次
  Timer? _pollTimer;

  /// WebView2 环境一次性创建失败时插件不发任何事件，只能靠看门狗发现白屏
  late final WebLoadWatchdog _loadWatchdog = WebLoadWatchdog(
    readyOnFirstStart: args?.redirectMatch != null,
  );
  Timer? _watchdogTimer;
  final RxBool loadFailed = false.obs;
  final RxBool loadRetryExhausted = false.obs;
  final RxInt webViewAttempt = 0.obs;

  /// 无参深链/参数类型不符：页面层展示错误并提供关闭
  final RxBool argsMissing = false.obs;

  /// 凭据记忆条控件（args.credential 非空时才创建）
  InAppWebViewController? _webViewController;
  TextEditingController? accountController;
  TextEditingController? passwordController;
  final RxBool obscurePassword = true.obs;
  RxBool? rememberCredential;
  Timer? _autofillTimer;
  int _autofillAttempts = 0;
  static const int _autofillMaxAttempts = 20;

  bool get _credentialEnabled => args?.credential != null;

  /// 安全返回登录页：对齐 main.dart 的 canPop 守卫，栈底/无栈时 no-op
  void closePage() {
    final navigator = Get.key.currentState;
    if (navigator != null && navigator.canPop()) {
      Get.back();
    }
  }

  @override
  void onInit() {
    super.onInit();
    final a = args;
    if (a == null) {
      // 无参深链：不启动加载看门狗，页面层展示参数错误并提供关闭
      argsMissing.value = true;
      loadFailed.value = true;
      loadRetryExhausted.value = true;
      return;
    }
    if (_credentialEnabled) {
      final cred = a.credential!;
      accountController = TextEditingController(text: cred.account);
      passwordController = TextEditingController(text: cred.password);
      rememberCredential =
          (cred.account.isNotEmpty || cred.password.isNotEmpty).obs;
      accountController!.addListener(_onCredentialChanged);
      passwordController!.addListener(_onCredentialChanged);
    }
    _loadWatchdog.start(DateTime.now().millisecondsSinceEpoch);
    _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_loadWatchdog.poll(DateTime.now().millisecondsSinceEpoch)) {
        _onWatchdogFailed();
      }
    });
  }

  void _onCredentialChanged() {
    if (rememberCredential?.value ?? false) {
      final cred = args?.credential;
      if (cred == null) return;
      cred.onSave(accountController!.text.trim(), passwordController!.text);
    }
  }

  void toggleRememberCredential(bool value) {
    final cred = args?.credential;
    if (cred == null) return;
    rememberCredential!.value = value;
    if (value) {
      cred.onSave(accountController!.text.trim(), passwordController!.text);
    } else {
      cred.onClear();
    }
  }

  /// 手动点「填入网页」：重新轮询注入
  void fillCredentialNow() {
    final webViewController = _webViewController;
    if (webViewController == null) return;
    if (accountController!.text.trim().isEmpty &&
        passwordController!.text.isEmpty) {
      SmartDialog.showToast("请先在上方填写账号密码");
      return;
    }
    startCredentialAutofill(webViewController);
  }

  void _onWatchdogFailed() {
    if (_loadWatchdog.shouldAutoRetry) {
      SmartDialog.showToast("页面启动失败，正在自动重试");
      _rebuildWebView();
      return;
    }
    loadFailed.value = true;
    loadRetryExhausted.value = !_loadWatchdog.canRetry;
  }

  void _rebuildWebView() {
    _loadWatchdog.retry(DateTime.now().millisecondsSinceEpoch);
    loadFailed.value = false;
    webViewAttempt.value++;
  }

  void retryManual() {
    if (!_loadWatchdog.canRetry) return;
    _rebuildWebView();
  }

  void onWebViewCreated(InAppWebViewController controller) {
    _webViewController = controller;
    _loadWatchdog.markCreated(DateTime.now().millisecondsSinceEpoch);
  }

  /// 轮询等待登录表单渲染完成后注入账号密码（返回 true 表示已填入）
  void startCredentialAutofill(InAppWebViewController controller) {
    _autofillTimer?.cancel();
    final account = accountController?.text.trim() ?? "";
    final password = passwordController?.text ?? "";
    if (account.isEmpty || password.isEmpty) return;
    _autofillAttempts = 0;
    _autofillTimer = Timer.periodic(const Duration(milliseconds: 500),
        (timer) async {
      _autofillAttempts++;
      bool done = false;
      try {
        done = await controller.evaluateJavascript(
          source: _buildAutofillScript(account, password),
        ) as bool;
      } catch (_) {}
      if (done || _autofillAttempts >= _autofillMaxAttempts) {
        timer.cancel();
      }
    });
  }

  /// 登录页填充脚本：账号/密码由 [buildCredentialAutofillScript] 按平台配置生成
  String _buildAutofillScript(String account, String password) {
    final cred = args?.credential;
    if (cred == null) return "false";
    return buildCredentialAutofillScript(
      cred: cred,
      account: account,
      password: password,
    );
  }

  void onReceivedError(
    InAppWebViewController controller,
    WebResourceRequest request,
    WebResourceError error,
  ) {
    // Windows 端该事件只可能来自主框架且字段可能为 null（null 视为主框架）
    if (request.isForMainFrame ?? true) {
      _loadWatchdog.markFatal();
    }
  }

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
    _loadWatchdog.markLoadStop();
    final a = args;
    if (a == null) return;
    // 重定向提取模式：轮询处理授权按钮
    if (a.redirectMatch != null) {
      if (_finished) return;
      _startPolling(controller);
      return;
    }
    // 凭据自动填充：仅在登录页主机名下执行
    if (_credentialEnabled &&
        uri != null &&
        uri.host == a.credential!.injectHost) {
      startCredentialAutofill(controller);
    }
    // 空 cookieUrl 时不能检查（requiredCookies 为空时 every 会空真误判成功）
    if (a.cookieUrl.isEmpty || _finished || _checking) {
      return;
    }
    _checking = true;
    // 抖音边缘网关对匿名请求按 IP 限速，超限返回 444 封锁页；
    // 退避后自动重载，封锁窗口通常数秒至数分钟
    bool blocked = false;
    try {
      blocked = await controller.evaluateJavascript(
        source: _blockDetectScript,
      ) as bool;
    } catch (_) {}
    if (blocked) {
      await _reloadAfterBlock(controller);
      return;
    }
    var cookies = await cookieManager.getCookies(
      url: WebUri(a.cookieUrl),
    );
    var names = cookies.map((e) => e.name).toSet();
    if (a.requiredCookies.every(names.contains)) {
      _finished = true;
      var cookieStr = cookies
          .where((e) => e.value.isNotEmpty)
          .map((e) => "${e.name}=${e.value}")
          .join(";");
      // onSuccess 抛异常时也要返回登录页，避免页面卡死
      try {
        a.onSuccess(cookieStr);
      } finally {
        closePage();
      }
    } else {
      // 尚未集齐必需 Cookie，放行后续 onLoadStop 继续检查
      _checking = false;
    }
  }

  Future<void> _reloadAfterBlock(InAppWebViewController controller) async {
    if (_blockRetries >= _blockRetryDelays.length) {
      _checking = false;
      SmartDialog.showToast("访问受限，请稍后关闭页面重新登录");
      return;
    }
    final seconds = _blockRetryDelays[_blockRetries];
    _blockRetries++;
    SmartDialog.showToast("访问受限，$seconds 秒后自动重试");
    await Future.delayed(Duration(seconds: seconds));
    _checking = false;
    try {
      await controller.reload();
    } catch (_) {}
  }

  /// 重定向提取模式：匹配则拦截并解析 fragment；返回 true 表示已处理
  bool handleNavigation(Uri uri) {
    final a = args;
    final match = a?.redirectMatch;
    if (_finished || match == null || !uri.toString().startsWith(match)) {
      return false;
    }
    _finished = true;
    var value = Uri.splitQueryString(uri.fragment)[a!.fragmentKey];
    if (value == null || value.isEmpty) {
      // 已回到重定向 URI 但没有令牌（如用户拒绝授权）
      SmartDialog.showToast("未获得授权");
      _pollTimer?.cancel();
      closePage();
      return true;
    }
    try {
      a.onSuccess(value);
    } finally {
      _pollTimer?.cancel();
      closePage();
    }
    return true;
  }

  /// onLoadStart 兜底拦截：部分机型 302 到 localhost 时
  /// shouldOverrideUrlLoading 不触发
  void onLoadStart(InAppWebViewController controller, Uri? uri) {
    _loadWatchdog.markLoadStart(DateTime.now().millisecondsSinceEpoch);
    final a = args;
    if (a == null) return;
    if (a.redirectMatch != null && !_finished) {
      // onLoadStop 在部分页面不触发，提前启动轮询
      _startPolling(controller);
    }
    if (uri == null ||
        _finished ||
        a.redirectMatch == null ||
        !uri.toString().startsWith(a.redirectMatch!)) {
      return;
    }
    // 必须在 closePage() 之前停止加载，否则页面销毁后操作 controller
    controller.stopLoading();
    handleNavigation(uri);
  }

  @override
  void onClose() {
    _pollTimer?.cancel();
    _autofillTimer?.cancel();
    _watchdogTimer?.cancel();
    accountController?.removeListener(_onCredentialChanged);
    accountController?.dispose();
    passwordController?.dispose();
    super.onClose();
  }
}

class WebLoginPage extends GetView<WebLoginController> {
  const WebLoginPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    var args = controller.args;
    if (args == null) {
      // 无参深链/参数类型不符：安全兜底页，不创建 WebView、不 crash
      return Scaffold(
        appBar: AppBar(title: const Text("登录")),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text("页面参数缺失，请从账号设置入口进入"),
              const SizedBox(height: 16),
              TextButton(
                onPressed: controller.closePage,
                child: const Text("关闭页面"),
              ),
            ],
          ),
        ),
      );
    }
    // 重定向提取模式（Twitch）：不用 CDP Fetch 实现的
    // shouldOverrideUrlLoading（POST→302 到 localhost 时会静默挂起），
    // 改依赖 WebView2 NavigationStarting 触发的 onLoadStart，最可靠。
    // 斗鱼同理：passport 表单登录 POST→302 跨域顶层跳转会让 CDP Fetch
    // 拦截路径在插件 DLL 内访问违例闪退，通过 useShouldOverrideUrlLoading=false 关闭
    var redirectMode = args.redirectMatch != null;
    var useOverride =
        !redirectMode && args.useShouldOverrideUrlLoading;
    var webView = Obx(
      () => InAppWebView(
        key: ValueKey(
            'login-webview-${controller.webViewAttempt.value}'),
        initialUrlRequest: URLRequest(url: WebUri(args.startUrl)),
        initialSettings: InAppWebViewSettings(
          useShouldOverrideUrlLoading: useOverride,
          userAgent: args.userAgent,
        ),
        onWebViewCreated: controller.onWebViewCreated,
        onLoadStop: controller.onLoadStop,
        onLoadStart: controller.onLoadStart,
        onReceivedError: controller.onReceivedError,
        // 不提供该回调时首个文档导航会被插件中止（白屏），必须显式放行
        shouldOverrideUrlLoading: !useOverride
            ? null
            : (controller, action) async {
                return NavigationActionPolicy.ALLOW;
              },
      ),
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
          if (args.credential != null)
            _buildCredentialBar(context),
          Expanded(
            child: Stack(
              children: [
                webView,
                Obx(() => controller.loadFailed.value
                    ? _buildLoadFailureMask(context)
                    : const SizedBox.shrink()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCredentialBar(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final credential = controller.args?.credential;
    if (credential == null) return const SizedBox.shrink();
    final inputBorder = OutlineInputBorder(
      borderSide: BorderSide(color: colorScheme.outlineVariant),
    );
    return Container(
      color: colorScheme.surfaceContainerHighest,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller.accountController,
                  style: const TextStyle(fontSize: 14),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: credential.accountHint,
                    border: inputBorder,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Obx(
                  () => TextField(
                    controller: controller.passwordController,
                    style: const TextStyle(fontSize: 14),
                    obscureText: controller.obscurePassword.value,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: "密码",
                      border: inputBorder,
                      suffixIcon: IconButton(
                        iconSize: 18,
                        padding: EdgeInsets.zero,
                        icon: Icon(controller.obscurePassword.value
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined),
                        onPressed: () => controller.obscurePassword.value =
                            !controller.obscurePassword.value,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          Row(
            children: [
              Obx(
                () => Checkbox(
                  value: controller.rememberCredential!.value,
                  visualDensity: VisualDensity.compact,
                  onChanged: (v) =>
                      controller.toggleRememberCredential(v ?? false),
                ),
              ),
              GestureDetector(
                onTap: () => controller.toggleRememberCredential(
                    !controller.rememberCredential!.value),
                child: const Text("记住账号密码", style: TextStyle(fontSize: 13)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "自动填入网页，仍需手动点登录",
                  style: TextStyle(fontSize: 11, color: colorScheme.outline),
                ),
              ),
              TextButton.icon(
                onPressed: controller.fillCredentialNow,
                icon: const Icon(Icons.input, size: 18),
                label: const Text("填入网页"),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildLoadFailureMask(BuildContext context) {
    final exhausted = controller.loadRetryExhausted.value;
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      color: colorScheme.surface,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            exhausted ? "网页环境多次启动失败，请重启 App 后再试" : "页面启动失败",
            style: const TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 16),
          if (exhausted)
            TextButton(
              onPressed: controller.closePage,
              child: const Text("关闭页面"),
            )
          else
            FilledButton(
              onPressed: controller.retryManual,
              child: const Text("重试"),
            ),
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
