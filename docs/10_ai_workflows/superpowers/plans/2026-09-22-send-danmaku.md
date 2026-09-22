# 发送弹幕功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Simple Live 增加在哔哩哔哩、斗鱼、虎牙、抖音、Twitch 五个平台直播间发送弹幕的能力，竖屏底部输入栏与全屏控制栏两个入口。

**Architecture:** Core 层在 `LiveDanmaku` 接口增加 `sendMessage`，返回统一 `DanmakuSendResult`；各平台弹幕实现走各自的公开通道（HTTP / WebSocket / IRC）。App 层新增斗鱼、虎牙账号服务，改造抖音账号服务支持账号登录，房间页新增输入栏与全屏发送弹框。

**Tech Stack:** Flutter 3.38 / Dart（core ≥3.10.0）、GetX、Dio 5、flutter_inappwebview、crypto、tars_dart（本地包）

**Spec:** [docs/10_ai_workflows/superpowers/specs/2026-09-22-send-danmaku-design.md](../specs/2026-09-22-send-danmaku-design.md)

## Global Constraints

- 范围仅 `simple_live_core`、`simple_live_app`；`simple_live_tv_app` 不改动。
- 不新增第三方依赖；只使用 pubspec 中已有的包（crypto、tars_dart、flutter_inappwebview、web_socket_channel 等）。
- 所有用户可见文案使用简体中文。
- 仅使用用户本人登录态调用公开接口；不做批量/机器人行为；客户端自律：B站 ≤1 条/秒、斗鱼 ≤1 条/2 秒、虎牙 ≤1 条/20 秒。
- 各平台错误码 → 中文文案的映射统一在 App 层。
- 调研偏差（以 ordinaryroad douyu 1.5.8 源码为准，实施时同步更新 spec）：
  1. **斗鱼发送弹幕不需要 websec 循环 MD5 签名**：wsproxy 登录使用旧 vk 体系（`vk=MD5(秒时间戳+vk_secret+dy_did)`），websec/getEncryption 仅用于直播流签名。
  2. **虎牙登录采用 WebView 打开 https://www.huya.com**（网页内可扫码/账密），不再单独实现扫码接口轮询。
  3. **chatmessage 帧不含 rid 字段**（1.5.8 ChatmessageMsg 实际字段：pe/content/col/dy/sender/ifs/nc/dat/rev/tts/admzq/cst）。

---

## File Structure

### simple_live_core

| 文件 | 职责 | 动作 |
|---|---|---|
| `lib/src/interface/live_danmaku.dart` | 增加 `DanmakuSendResult` 类与 `sendMessage` 抽象方法 | 修改 |
| `lib/src/danmaku/bilibili_danmaku.dart` | POST msg/send 发弹幕 | 修改 |
| `lib/src/danmaku/twitch_danmaku.dart` | 认证 IRC 连接 + PRIVMSG | 修改 |
| `lib/src/danmaku/douyin_danmaku.dart` | GET webcast/room/chat + a_bogus | 修改 |
| `lib/src/danmaku/douyu_danmaku.dart` | 新增 wsproxy 发送连接、vk 登录、chatmessage、keeplive | 修改 |
| `lib/src/danmaku/huya_danmaku.dart` | VerifyCookie 登录 + WupReq 发送 | 修改 |
| `lib/src/twitch_site.dart` | 自身 login 惰性获取，TwitchDanmakuArgs 带 token | 修改 |
| `lib/src/douyu_site.dart` | cookie 字段，danmakuData 改为 DouyuDanmakuArgs | 修改 |
| `lib/src/huya_site.dart` | cookie 字段，HuyaDanmakuArgs 带 cookie | 修改 |
| `lib/src/model/tars/huya_send_message_req.dart` | SendMessageReq / ContentFormat / BulletFormat / MessageTagInfo / SendMessageRsp tars 结构 | 新建 |
| `lib/src/model/tars/huya_verify_cookie.dart` | WSVerifyCookieReq / WSVerifyCookieRsp | 新建 |
| `test/danmaku/bilibili_danmaku_test.dart` | csrf 提取测试 | 新建 |
| `test/danmaku/douyu_danmaku_test.dart` | vk、STT 转义、组帧测试 | 新建 |
| `test/danmaku/huya_danmaku_test.dart` | SendMessageReq tars 字节测试 | 新建 |
| `test/danmaku/douyin_danmaku_test.dart` | chat URL 构造测试 | 新建 |

### simple_live_app

| 文件 | 职责 | 动作 |
|---|---|---|
| `lib/services/local_storage_service.dart` | 新增 kDouyuCookie、kHuyaCookie、kDouyinLoginCookie | 修改 |
| `lib/services/douyu_account_service.dart` | 斗鱼登录态（仿 BiliBiliAccountService） | 新建 |
| `lib/services/huya_account_service.dart` | 虎牙登录态 | 新建 |
| `lib/services/douyin_account_service.dart` | 在 ttwid 之外增加账号登录态 | 修改 |
| `lib/modules/mine/account/web_login.dart` | 通用 WebView 登录页（startUrl + 必需 cookie 判定 + onSuccess 回调） | 新建 |
| `lib/modules/mine/account/account_page.dart` | 斗鱼/虎牙/抖音入口改造 | 修改 |
| `lib/modules/mine/account/account_controller.dart` | 三个平台 tap 与登录逻辑 | 修改 |
| `lib/routes/route_path.dart` | 新增 kWebLogin | 修改 |
| `lib/routes/app_pages.dart` | 注册 WebLogin 页面 | 修改 |
| `lib/main.dart` | 注册 Douyu/HuyaAccountService | 修改 |
| `lib/modules/live_room/live_room_controller.dart` | sendDanmaku + 错误文案映射 + 当前用户名 | 修改 |
| `lib/modules/live_room/live_room_page.dart` | 底部输入栏（手机 + 平板） | 修改 |
| `lib/modules/live_room/player/player_controls.dart` | 全屏发送按钮 + 弹框 | 修改 |

---

## Task 1: Core 接口 — DanmakuSendResult 与 sendMessage

**Files:**
- Modify: `simple_live_core/lib/src/interface/live_danmaku.dart`

**Interfaces:**
- Produces: `DanmakuSendResult({required bool success, String errorCode = "", String errorMessage = "", bool needLocalEcho = false})`；`Future<DanmakuSendResult> sendMessage(String message)`（LiveDanmaku 成员）。后续所有任务依赖此签名。

- [ ] **Step 1: 修改接口文件**

将 `simple_live_core/lib/src/interface/live_danmaku.dart` 整体替换为：

```dart
import 'dart:async';

import 'package:simple_live_core/src/model/live_message.dart';

class DanmakuSendResult {
  final bool success;
  final String errorCode;
  final String errorMessage;

  /// 服务器不回环自身消息时为 true（Twitch），由本地插入消息
  final bool needLocalEcho;

  DanmakuSendResult({
    required this.success,
    this.errorCode = "",
    this.errorMessage = "",
    this.needLocalEcho = false,
  });
}

class LiveDanmaku {
  Function(LiveMessage msg)? onMessage;
  Function(String msg)? onClose;
  Function()? onReady;

  /// 心跳时间
  int heartbeatTime = 0;

  /// 发生心跳
  void heartbeat() {}

  /// 开始接收信息
  Future start(dynamic args) {
    return Future.value();
  }

  /// 停止接收信息
  Future stop() {
    return Future.value();
  }

  /// 发送弹幕
  Future<DanmakuSendResult> sendMessage(String message) {
    return Future.value(
      DanmakuSendResult(success: false, errorCode: "not_supported"),
    );
  }
}
```

- [ ] **Step 2: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/interface/live_danmaku.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add simple_live_core/lib/src/interface/live_danmaku.dart
git commit -m "feat(core): LiveDanmaku 增加 sendMessage 与 DanmakuSendResult"
```

---

## Task 2: 哔哩哔哩发送弹幕

**Files:**
- Modify: `simple_live_core/lib/src/danmaku/bilibili_danmaku.dart`
- Test: `simple_live_core/test/danmaku/bilibili_danmaku_test.dart`

**Interfaces:**
- Consumes: `DanmakuSendResult`（Task 1）；`HttpClient.instance.postJson(url, {data, header, formUrlEncoded})`（已有）。
- Produces: `static String getCsrf(String cookie)`（返回 cookie 中 bili_jct 值，无则空串）。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_core/test/danmaku/bilibili_danmaku_test.dart`：

```dart
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("getCsrf", () {
    test("正常提取 bili_jct", () {
      expect(
        BiliBiliDanmaku.getCsrf("SESSDATA=abc; bili_jct=csrf123; foo=bar"),
        "csrf123",
      );
    });
    test("bili_jct 在末尾", () {
      expect(BiliBiliDanmaku.getCsrf("SESSDATA=a;bili_jct=xyz"), "xyz");
    });
    test("缺失返回空串", () {
      expect(BiliBiliDanmaku.getCsrf("SESSDATA=a"), "");
    });
    test("空 cookie 返回空串", () {
      expect(BiliBiliDanmaku.getCsrf(""), "");
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_core && dart test test/danmaku/bilibili_danmaku_test.dart`
Expected: FAIL（`getCsrf` 方法不存在 / 编译错误）。

- [ ] **Step 3: 实现 getCsrf 与 sendMessage**

在 `bilibili_danmaku.dart` 中：

1) 在 import 区增加（第 7 行 `package:simple_live_core/simple_live_core.dart` 已间接引入 HttpClient，无需新 import；确认文件顶部已有）无需改动 import。

2) 在 `BiliBiliDanmaku` 类内（`stop()` 方法之后）增加：

```dart
  static String getCsrf(String cookie) {
    return RegExp(r"bili_jct=([^;]+)").firstMatch(cookie)?.group(1) ?? "";
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    var cookie = danmakuArgs.cookie;
    var csrf = getCsrf(cookie);
    if (csrf.isEmpty || !cookie.contains("SESSDATA")) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录哔哩哔哩",
      );
    }

    var roomId = danmakuArgs.roomId;
    try {
      var result = await HttpClient.instance.postJson(
        "https://api.live.bilibili.com/msg/send",
        data: {
          "msg": message,
          "roomid": roomId,
          "rnd": DateTime.now().millisecondsSinceEpoch ~/ 1000,
          "color": 16777215,
          "fontsize": 25,
          "mode": 1,
          "bubble": 0,
          "csrf": csrf,
          "csrf_token": csrf,
        },
        formUrlEncoded: true,
        header: {
          "Cookie": cookie,
          "Referer": "https://live.bilibili.com/$roomId",
          "Origin": "https://live.bilibili.com",
        },
      );
      var code = result["code"];
      if (code == 0) {
        return DanmakuSendResult(success: true);
      }
      return DanmakuSendResult(
        success: false,
        errorCode: code.toString(),
        errorMessage: result["message"]?.toString() ?? "",
      );
    } catch (e) {
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "网络请求失败",
      );
    }
  }
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd simple_live_core && dart test test/danmaku/bilibili_danmaku_test.dart`
Expected: PASS（4 个测试）。

- [ ] **Step 5: 全量分析**

Run: `cd simple_live_core && dart analyze lib/src/danmaku/bilibili_danmaku.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add simple_live_core/lib/src/danmaku/bilibili_danmaku.dart simple_live_core/test/danmaku/bilibili_danmaku_test.dart
git commit -m "feat(core): 哔哩哔哩发送弹幕（msg/send）"
```

---

## Task 3: Twitch 认证连接与发送

**Files:**
- Modify: `simple_live_core/lib/src/danmaku/twitch_danmaku.dart`
- Modify: `simple_live_core/lib/src/twitch_site.dart`

**Interfaces:**
- Consumes: `TwitchSite.oauthToken`（已有）；`_helixHeader`（已有 getter）。
- Produces: `TwitchDanmakuArgs({required String channel, String oauthToken = "", String userLogin = ""})`；`TwitchSite.userLogin`（字段，默认空串）。

- [ ] **Step 1: 修改 TwitchDanmakuArgs 与连接逻辑**

将 `simple_live_core/lib/src/danmaku/twitch_danmaku.dart` 中：

1) `TwitchDanmakuArgs` 类（第 9-14 行）替换为：

```dart
class TwitchDanmakuArgs {
  /// 频道登录名（小写）
  final String channel;

  /// OAuth token（为空时匿名连接，不能发送）
  final String oauthToken;

  /// 自身登录名（有 token 时必填，用于 NICK）
  final String userLogin;

  TwitchDanmakuArgs({
    required this.channel,
    this.oauthToken = "",
    this.userLogin = "",
  });
}
```

2) `start` 方法（第 34-59 行）中，替换最后三行：

```dart
    _send("CAP REQ :twitch.tv/tags twitch.tv/commands");
    var nick = "justinfan${Random().nextInt(90000) + 10000}";
    _send("NICK $nick");
    _send("JOIN #${danmakuArgs.channel}");
```

为：

```dart
    _send("CAP REQ :twitch.tv/tags twitch.tv/commands");
    if (danmakuArgs.oauthToken.isNotEmpty &&
        danmakuArgs.userLogin.isNotEmpty) {
      _send("PASS oauth:${danmakuArgs.oauthToken}");
      _send("NICK ${danmakuArgs.userLogin}");
    } else {
      var nick = "justinfan${Random().nextInt(90000) + 10000}";
      _send("NICK $nick");
    }
    _send("JOIN #${danmakuArgs.channel}");
```

3) 在 `stop()` 方法之前增加 `sendMessage`：

```dart
  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    if (danmakuArgs.oauthToken.isEmpty || danmakuArgs.userLogin.isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未配置 Twitch 账号",
      );
    }
    _send("PRIVMSG #${danmakuArgs.channel} :$message");
    return DanmakuSendResult(success: true, needLocalEcho: true);
  }
```

- [ ] **Step 2: 修改 TwitchSite —— 自身 login 获取与 args 传参**

在 `simple_live_core/lib/src/twitch_site.dart`：

1) 在类字段区（`oauthToken` 字段附近）增加：

```dart
  /// 自身登录名（oauthToken 存在时惰性获取）
  String userLogin = "";
```

2) 在类内增加私有方法（放在 `_helixRoomDetail` 之前）：

```dart
  Future<void> _ensureUserLogin() async {
    if (oauthToken.isEmpty || userLogin.isNotEmpty) {
      return;
    }
    var result = await HttpClient.instance.getJson(
      "https://api.twitch.tv/helix/users",
      header: _helixHeader,
    );
    var data = result["data"] as List;
    if (data.isNotEmpty) {
      userLogin = data[0]["login"].toString();
    }
  }
```

3) 两处 danmakuData 替换（第 522-524 行 gql 路径 `return LiveRoomDetail`，第 562-564 行 helix 路径 `return LiveRoomDetail`）：

在两处 `return LiveRoomDetail(` 之前各插入一行：

```dart
    await _ensureUserLogin();
```

并将两处的 danmakuData 都替换为：

```dart
      danmakuData: TwitchDanmakuArgs(
        channel: user["login"].toString(),
        oauthToken: oauthToken,
        userLogin: userLogin,
      ),
```

- [ ] **Step 3: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/danmaku/twitch_danmaku.dart lib/src/twitch_site.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add simple_live_core/lib/src/danmaku/twitch_danmaku.dart simple_live_core/lib/src/twitch_site.dart
git commit -m "feat(core): Twitch 认证 IRC 连接与 PRIVMSG 发送"
```

---

## Task 4: 抖音发送弹幕（room/chat + a_bogus）

**Files:**
- Modify: `simple_live_core/lib/src/danmaku/douyin_danmaku.dart`
- Test: `simple_live_core/test/danmaku/douyin_danmaku_test.dart`

**Interfaces:**
- Consumes: `DouyinSign.getAbogusUrl(String url, String ua)`（已有，url 必须含 `?`）；`DouyinDanmakuArgs({webRid, roomId, userId, cookie})`（已有）。
- Produces: `static String buildChatUrl({required String roomId, required String content, required String webRid})`（返回已含全部业务/公共参数、待签名的 URL）。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_core/test/danmaku/douyin_danmaku_test.dart`：

```dart
import 'package:simple_live_core/src/danmaku/douyin_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("buildChatUrl", () {
    var url = DouyinDanmaku.buildChatUrl(
      roomId: "7300000000000000000",
      content: "你好",
      webRid: "123abc",
    );
    test("基础地址", () {
      expect(
        url.startsWith("https://live.douyin.com/webcast/room/chat/?"),
        isTrue,
      );
    });
    test("包含必带参数", () {
      expect(url.contains("room_id=7300000000000000000"), isTrue);
      expect(url.contains("type=0"), isTrue);
      expect(url.contains("aid=6383"), isTrue);
      expect(url.contains("app_name=douyin_web"), isTrue);
    });
    test("内容做 URL 编码", () {
      expect(url.contains("content="), isTrue);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_core && dart test test/danmaku/douyin_danmaku_test.dart`
Expected: FAIL（`buildChatUrl` 不存在）。

- [ ] **Step 3: 实现 buildChatUrl 与 sendMessage**

在 `douyin_danmaku.dart` 的 `DouyinDanmaku` 类内（`stop()` 方法之前）增加：

```dart
  static String buildChatUrl({
    required String roomId,
    required String content,
    required String webRid,
  }) {
    var params = <String, String>{
      "room_id": roomId,
      "content": content,
      "type": "0",
      "rtf_content": "",
      "emoji_id": "0",
      "camera_id": "",
      "team_id": "",
      "paste_edit_method": "0",
      "aid": "6383",
      "app_name": "douyin_web",
      "live_id": "1",
      "device_platform": "web",
      "language": "zh-CN",
      "enter_from": "web_live",
      "cookie_enabled": "true",
      "screen_width": "1920",
      "screen_height": "1080",
      "browser_name": "Mozilla",
      "browser_version": "180800",
      "os_name": "Windows",
      "os_version": "10",
      "web_rid": webRid,
    };
    var query = params.entries
        .map((e) =>
            "${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}")
        .join("&");
    return "https://live.douyin.com/webcast/room/chat/?$query";
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    if (!danmakuArgs.cookie.contains("sessionid")) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录抖音",
      );
    }
    try {
      var url = buildChatUrl(
        roomId: danmakuArgs.roomId,
        content: message,
        webRid: danmakuArgs.webRid,
      );
      url = DouyinSign.getAbogusUrl(url, DouyinSite.kDefaultUserAgent);
      var result = await HttpClient.instance.getJson(
        url,
        header: {
          "User-Agent": DouyinSite.kDefaultUserAgent,
          "Referer": "https://live.douyin.com/${danmakuArgs.webRid}",
          "Cookie": danmakuArgs.cookie,
        },
      );
      var code = result["status_code"];
      if (code == 0) {
        return DanmakuSendResult(success: true);
      }
      var msg = result["data"]?["message"]?.toString() ?? "";
      return DanmakuSendResult(
        success: false,
        errorCode: code.toString(),
        errorMessage: msg,
      );
    } catch (e) {
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "网络请求失败",
      );
    }
  }
```

`HttpClient` 已通过 `package:simple_live_core/simple_live_core.dart` 导出可用（文件第 4 行已有该 import）。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd simple_live_core && dart test test/danmaku/douyin_danmaku_test.dart`
Expected: PASS（4 个测试）。

- [ ] **Step 5: Commit**

```bash
git add simple_live_core/lib/src/danmaku/douyin_danmaku.dart simple_live_core/test/danmaku/douyin_danmaku_test.dart
git commit -m "feat(core): 抖音发送弹幕（webcast/room/chat + a_bogus）"
```

---

## Task 5: 抖音账号服务 WebView 登录改造

**Files:**
- Modify: `simple_live_app/lib/services/local_storage_service.dart`
- Create: `simple_live_app/lib/modules/mine/account/web_login.dart`
- Modify: `simple_live_app/lib/services/douyin_account_service.dart`
- Modify: `simple_live_app/lib/routes/route_path.dart`
- Modify: `simple_live_app/lib/routes/app_pages.dart`

**Interfaces:**
- Consumes: `WebLoginArgs({required String title, required String startUrl, required String cookieUrl, required List<String> requiredCookies, required void Function(String cookie) onSuccess})`；Get 路由名 `RoutePath.kWebLogin`，`Get.toNamed(..., arguments: WebLoginArgs)`。
- Produces: `WebLoginArgs` / `WebLoginPage`；`DouyinAccountService.setLoginCookie(String)`、`logout()`；`logined`（RxBool）、`loginName`（RxString）。

- [ ] **Step 1: LocalStorage 新增 key**

在 `local_storage_service.dart` 第 127 行 `kDouyinCookie` 之后增加：

```dart
  /// 抖音账号登录完整cookie
  static const String kDouyinLoginCookie = "DouyinLoginCookie";

  /// 斗鱼cookie
  static const String kDouyuCookie = "DouyuCookie";

  /// 虎牙cookie
  static const String kHuyaCookie = "HuyaCookie";
```

- [ ] **Step 2: 新增通用 WebView 登录页**

创建 `simple_live_app/lib/modules/mine/account/web_login.dart`：

```dart
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
```

- [ ] **Step 3: 改造 DouyinAccountService**

将 `simple_live_app/lib/services/douyin_account_service.dart` 整体替换为：

```dart
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyinAccountService extends GetxService {
  static DouyinAccountService get instance =>
      Get.find<DouyinAccountService>();

  /// 自定义 ttwid（设备标识，可选）
  var cookie = "";
  var hasCookie = false.obs;

  /// 账号登录完整 cookie
  var loginCookie = "";
  var logined = false.obs;
  var loginName = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = cookie.isNotEmpty;
    loginCookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyinLoginCookie, "");
    logined.value = loginCookie.contains("sessionid");
    loginName.value = logined.value ? "已登录" : "未登录";
    setSite();
    super.onInit();
  }

  void setSite() {
    var site = (Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite);
    site.cookie = logined.value ? loginCookie : cookie;
  }

  void setCookie(String cookie) {
    this.cookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, cookie);
    hasCookie.value = cookie.isNotEmpty;
    setSite();
  }

  void clearCookie() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinCookie, "");
    hasCookie.value = false;
    setSite();
  }

  void setLoginCookie(String cookie) {
    loginCookie = cookie;
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, cookie);
    logined.value = cookie.contains("sessionid");
    loginName.value = logined.value ? "已登录" : "未登录";
    setSite();
  }

  void logout() {
    loginCookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyinLoginCookie, "");
    logined.value = false;
    loginName.value = "未登录";
    setSite();
  }
}
```

- [ ] **Step 4: 注册路由**

1) 在 `route_path.dart` 增加常量（跟随其他 k... 常量风格）：

```dart
  static const kWebLogin = "/web-login";
```

2) 在 `app_pages.dart` 的 pages 列表中（BiliBiliQRLogin 路由之后）增加：

```dart
      GetPage(
        name: RoutePath.kWebLogin,
        page: () => const WebLoginPage(),
        binding: BindingsBuilder.put(() => WebLoginController()),
      ),
```

并在文件顶部增加 import：

```dart
import 'package:simple_live_app/modules/mine/account/web_login.dart';
```

- [ ] **Step 5: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/services/douyin_account_service.dart lib/modules/mine/account/web_login.dart lib/routes/`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/services/douyin_account_service.dart simple_live_app/lib/services/local_storage_service.dart simple_live_app/lib/modules/mine/account/web_login.dart simple_live_app/lib/routes/
git commit -m "feat(app): 抖音 WebView 账号登录与通用 WebLogin 页面"
```

---

## Task 6: 斗鱼弹幕 —— wsproxy 发送连接

**Files:**
- Modify: `simple_live_core/lib/src/danmaku/douyu_danmaku.dart`
- Test: `simple_live_core/test/danmaku/douyu_danmaku_test.dart`

**Interfaces:**
- Consumes: `web_socket_channel`（已是依赖）；`crypto`（已是依赖）。
- Produces:
  - `DouyuDanmakuArgs({required int roomId, String cookie = ""})`
  - `static String generateVk(int ts, String did)`
  - `static String escapeStt(String v)`
  - `static String buildStt(Map<String,String> fields)`
  - `static Uint8List frameStt(String body)`

- [ ] **Step 1: 写失败测试**

创建 `simple_live_core/test/danmaku/douyu_danmaku_test.dart`：

```dart
import 'dart:typed_data';

import 'package:simple_live_core/src/danmaku/douyu_danmaku.dart';
import 'package:test/test.dart';

void main() {
  group("escapeStt", () {
    test("@ 与 / 转义", () {
      expect(DouyuDanmaku.escapeStt("a@b/c"), "a@Ab@Sc");
    });
  });

  group("buildStt", () {
    test("按顺序拼接", () {
      expect(
        DouyuDanmaku.buildStt({"type": "loginreq", "roomid": "123"}),
        "type@=loginreq/roomid@=123/",
      );
    });
    test("值转义", () {
      expect(
        DouyuDanmaku.buildStt({"dfl": "sn=105/ss=1"}),
        "dfl@=sn@A=105@Sss@A=1/",
      );
    });
  });

  group("generateVk", () {
    test("MD5 口径固定", () {
      // md5("1700000000" + vk_secret + "did123")
      var vk = DouyuDanmaku.generateVk(1700000000, "did123");
      expect(vk.length, 32);
      expect(RegExp(r"^[0-9a-f]{32}$").hasMatch(vk), isTrue);
    });
  });

  group("frameStt", () {
    test("帧头与现有协议一致（小端 689，length=总长-4）", () {
      var frame = DouyuDanmaku.frameStt("type@=mrkl/");
      var bd = ByteData.sublistView(frame);
      expect(bd.getInt32(0, Endian.little), frame.length - 4);
      expect(bd.getInt32(4, Endian.little), frame.length - 4);
      expect(bd.getInt16(8, Endian.little), 689);
      expect(frame.last, 0);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_core && dart test test/danmaku/douyu_danmaku_test.dart`
Expected: FAIL（静态方法/类不存在）。

- [ ] **Step 3: 重写 douyu_danmaku.dart**

将 `simple_live_core/lib/src/danmaku/douyu_danmaku.dart` 整体替换为：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/web_socket_util.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../common/binary_writer.dart';

class DouyuDanmakuArgs {
  final int roomId;
  final String cookie;
  DouyuDanmakuArgs({required this.roomId, this.cookie = ""});

  @override
  String toString() => json.encode({"roomId": roomId, "cookie": cookie});
}

class DouyuDanmaku implements LiveDanmaku {
  @override
  int heartbeatTime = 45 * 1000;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;
  String serverUrl = "wss://danmuproxy.douyu.com:8506";

  WebScoketUtils? webScoketUtils;

  static const String vkSecret =
      "r5*^5;}2#\${XF[h+;'./.Q'1;,-]f'p[";

  late DouyuDanmakuArgs danmakuArgs;

  // 发送连接
  WebSocketChannel? _sendChannel;
  Timer? _keepLiveTimer;
  Completer<void>? _loginCompleter;
  Completer<void>? _pendingAck;
  String? _pendingContent;
  String? _pendingError;
  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Future start(dynamic args) async {
    danmakuArgs = args is DouyuDanmakuArgs
        ? args
        : DouyuDanmakuArgs(roomId: int.tryParse(args.toString()) ?? 0);
    webScoketUtils = WebScoketUtils(
      url: serverUrl,
      heartBeatTime: heartbeatTime,
      onMessage: (e) {
        decodeMessage(e);
      },
      onReady: () {
        onReady?.call();
        joinRoom();
      },
      onHeartBeat: () {
        heartbeat();
      },
      onReconnect: () {
        onClose?.call("与服务器断开连接，正在尝试重连");
      },
      onClose: (e) {
        onClose?.call("服务器连接失败$e");
      },
    );
    webScoketUtils?.connect();

    if (danmakuArgs.cookie.isNotEmpty) {
      unawaited(_initSendChannel());
    }
  }

  void joinRoom() {
    webScoketUtils?.sendMessage(
      serializeDouyu("type@=loginreq/roomid@=${danmakuArgs.roomId}/"),
    );
    webScoketUtils?.sendMessage(serializeDouyu(
        "type@=joingroup/rid@=${danmakuArgs.roomId}/gid@=-9999/"));
  }

  @override
  void heartbeat() {
    webScoketUtils?.sendMessage(serializeDouyu("type@=mrkl/"));
  }

  Future<void> _initSendChannel() async {
    var cookie = danmakuArgs.cookie;
    var did = cookieValue(cookie, "dy_did");
    if (did.isEmpty) {
      did = _randomDid();
    }
    var uid = cookieValue(cookie, "acf_uid");

    String url;
    try {
      var resp = await HttpClient.instance.postJson(
        "https://www.douyu.com/lapi/live/gateway/web/${danmakuArgs.roomId}?isH5=1",
        data: "",
        header: {
          "Cookie": cookie,
          "Referer": "https://www.douyu.com/${danmakuArgs.roomId}",
        },
      );
      var info = resp["data"] ?? resp;
      var wssList = info["wss"] as List;
      var pick = wssList[Random().nextInt(wssList.length)];
      url = "wss://${pick["domain"]}:${pick["port"]}";
    } catch (e) {
      CoreLog.error(e);
      return;
    }

    _loginCompleter = Completer<void>();
    _sendChannel = WebSocketChannel.connect(Uri.parse(url));
    unawaited(_sendChannel!.ready);
    _sendChannel!.stream.listen(
      (event) {
        if (event is List<int>) {
          _onSendChannelMessageBytes(Uint8List.fromList(event));
        } else {
          _handleStt(event.toString());
        }
      },
      onError: (e) => CoreLog.error(e),
      onDone: _onSendChannelDone,
    );

    var now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var stt = buildStt({
      "type": "loginreq",
      "roomid": danmakuArgs.roomId.toString(),
      "dfl": "sn=105/ss=1",
      "username": uid,
      "password": "",
      "ltkid": cookieValue(cookie, "acf_ltkid"),
      "biz": "1",
      "stk": cookieValue(cookie, "acf_stk"),
      "devid": did,
      "ct": "0",
      "pt": "2",
      "cvr": "0",
      "tvr": "7",
      "apd": "",
      "rt": now.toString(),
      "vk": generateVk(now, did),
      "ver": "20220825",
      "aver": "218101901",
      "dmbt": "chrome",
      "dmbv": "123",
    });
    _sendChannel!.sink.add(frameStt(stt));
  }

  void _onSendChannelMessageBytes(Uint8List bytes) {
    try {
      var data = ByteData.sublistView(bytes);
      var length = data.getInt32(0, Endian.little);
      var bodyEnd = length - 1;
      if (bodyEnd > bytes.length) {
        bodyEnd = bytes.length;
      }
      var stt = utf8.decode(bytes.sublist(8, bodyEnd), allowMalformed: true);
      _handleStt(stt);
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void _handleStt(String stt) {
    if (stt.isEmpty) {
      return;
    }
    var fields = _parseStt(stt);
    var type = fields["type"];
    if (type == "loginres") {
      if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
        _loginCompleter!.complete();
      }
      _keepLiveTimer?.cancel();
      _keepLiveTimer = Timer.periodic(
        const Duration(seconds: 45),
        (_) {
          var tick = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          _sendChannel!.sink.add(frameStt(buildStt({
            "type": "keeplive",
            "vbw": "0",
            "cnd": "hs-h5",
            "tick": tick.toString(),
            "kd": "",
          })));
        },
      );
    } else if (type == "chatmsg") {
      if (_pendingAck != null &&
          fields["uid"] == cookieValue(danmakuArgs.cookie, "acf_uid") &&
          fields["txt"] == _pendingContent &&
          !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    } else if (type == "newblackres") {
      _pendingError = "muted";
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    } else if (type == "errorrid") {
      _pendingError = fields["result"] ?? "error";
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingAck!.complete();
      }
    }
  }

  void _onSendChannelDone() {
    _keepLiveTimer?.cancel();
    if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
      _loginCompleter!.completeError("closed");
    }
    if (_pendingAck != null && !_pendingAck!.isCompleted) {
      _pendingError = "closed";
      _pendingAck!.complete();
    }
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    var cookie = danmakuArgs.cookie;
    if (cookie.isEmpty ||
        cookieValue(cookie, "acf_stk").isEmpty ||
        cookieValue(cookie, "acf_uid").isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录斗鱼",
      );
    }
    if (_sendChannel == null) {
      return DanmakuSendResult(
        success: false,
        errorCode: "connecting",
        errorMessage: "发送连接未建立，请稍后再试",
      );
    }
    if (DateTime.now().difference(_lastSendTime).inSeconds < 2) {
      return DanmakuSendResult(
        success: false,
        errorCode: "rate_limit",
        errorMessage: "发言太快，请稍后再试",
      );
    }
    try {
      await _loginCompleter!.future;
    } catch (e) {
      return DanmakuSendResult(
        success: false,
        errorCode: "login_failed",
        errorMessage: "发送登录失败",
      );
    }

    var did = cookieValue(cookie, "dy_did");
    if (did.isEmpty) {
      did = _randomDid();
    }
    var nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    var cst = DateTime.now().millisecondsSinceEpoch +
        8000 +
        Random().nextInt(2000);
    var stt = buildStt({
      "type": "chatmessage",
      "pe": "0",
      "content": message,
      "col": "0",
      "dy": did,
      "sender": cookieValue(cookie, "acf_uid"),
      "ifs": "0",
      "nc": "0",
      "dat": "0",
      "rev": "0",
      "tts": nowSec.toString(),
      "admzq": "0",
      "cst": cst.toString(),
    });

    _pendingAck = Completer<void>();
    _pendingContent = message;
    _pendingError = null;
    _sendChannel!.sink.add(frameStt(stt));
    _lastSendTime = DateTime.now();

    var timer = Timer(const Duration(seconds: 8), () {
      if (_pendingAck != null && !_pendingAck!.isCompleted) {
        _pendingError = "timeout";
        _pendingAck!.complete();
      }
    });
    await _pendingAck!.future;
    timer.cancel();

    if (_pendingError != null) {
      return DanmakuSendResult(
        success: false,
        errorCode: _pendingError!,
        errorMessage: _pendingError == "muted" ? "你已被禁言" : "发送失败",
      );
    }
    return DanmakuSendResult(success: true);
  }

  static String generateVk(int currentTimeSecs, String did) {
    return md5
        .convert("$currentTimeSecs$vkSecret$did".codeUnits)
        .toString();
  }

  static String escapeStt(String v) =>
      v.replaceAll("@", "@A").replaceAll("/", "@S");

  static String buildStt(Map<String, String> fields) {
    return fields.entries
        .map((e) => "${escapeStt(e.key)}@=${escapeStt(e.value)}/")
        .join();
  }

  static Uint8List frameStt(String body) {
    var bytes = utf8.encode(body);
    var total = bytes.length + 9;
    var writer = BinaryWriter([]);
    writer.writeInt(total, 4, endian: Endian.little);
    writer.writeInt(total, 4, endian: Endian.little);
    writer.writeInt(689, 2, endian: Endian.little);
    writer.writeInt(0, 1, endian: Endian.little);
    writer.writeInt(0, 1, endian: Endian.little);
    writer.writeBytes(bytes);
    writer.writeInt(0, 1, endian: Endian.little);
    return Uint8List.fromList(writer.buffer);
  }

  static String cookieValue(String cookie, String name) {
    return RegExp("$name=([^;]+)").firstMatch(cookie)?.group(1) ?? "";
  }

  Map<String, String> _parseStt(String stt) {
    var result = <String, String>{};
    for (var field in stt.split("/")) {
      var idx = field.indexOf("@=");
      if (idx <= 0) {
        continue;
      }
      result[field.substring(0, idx)] = field.substring(idx + 2);
    }
    return result;
  }

  String _randomDid() {
    const chars = "0123456789abcdef";
    var rnd = Random();
    return List.generate(32, (_) => chars[rnd.nextInt(16)]).join();
  }

  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    _keepLiveTimer?.cancel();
    await _sendChannel?.sink.close();
    _sendChannel = null;
    webScoketUtils?.close();
  }

  void decodeMessage(List<int> data) {
    try {
      String? result = deserializeDouyu(data);
      if (result == null) {
        return;
      }
      var jsonData = sttToJObject(result);

      var type = jsonData["type"]?.toString();
      if (type == "chatmsg") {
        if (jsonData["dms"] == null) {
          return;
        }
        var col = int.tryParse(jsonData["col"].toString()) ?? 0;
        var liveMsg = LiveMessage(
          type: LiveMessageType.chat,
          userName: jsonData["nn"].toString(),
          message: jsonData["txt"].toString(),
          color: getColor(col),
        );

        onMessage?.call(liveMsg);
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  List<int> serializeDouyu(String body) {
    try {
      List<int> buffer = utf8.encode(body);
      var writer = BinaryWriter([]);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(4 + 4 + body.length + 1, 4, endian: Endian.little);
      writer.writeInt(689, 2, endian: Endian.little);
      writer.writeInt(0, 1, endian: Endian.little);
      writer.writeInt(0, 1, endian: Endian.little);
      writer.writeBytes(buffer);
      writer.writeInt(0, 1, endian: Endian.little);
      return writer.buffer;
    } catch (e) {
      CoreLog.error(e);
      return [];
    }
  }

  String? deserializeDouyu(List<int> buffer) {
    try {
      var reader = BinaryReader(Uint8List.fromList(buffer));
      int fullMsgLength = reader.readInt32(endian: Endian.little);
      reader.readInt32(endian: Endian.little);
      int bodyLength = fullMsgLength - 9;
      reader.readShort(endian: Endian.little);
      reader.readByte(endian: Endian.little);
      reader.readByte(endian: Endian.little);

      var bytes = reader.readBytes(bodyLength);

      reader.readByte(endian: Endian.little);
      return utf8.decode(bytes);
    } catch (e) {
      CoreLog.error(e);
      return null;
    }
  }

  dynamic sttToJObject(String str) {
    if (str.contains("//")) {
      var result = [];
      for (var field in str.split("//")) {
        if (field.isEmpty) {
          continue;
        }
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains("@=")) {
      var result = {};
      for (var field in str.split("/")) {
        if (field.isEmpty) {
          continue;
        }
        var tokens = field.split("@=");
        result[tokens[0]] = sttToJObject(unscapeSlashAt(tokens[1]));
      }
      return result;
    } else if (str.contains("@A=")) {
      return sttToJObject(unscapeSlashAt(str));
    } else {
      return unscapeSlashAt(str);
    }
  }

  String unscapeSlashAt(String str) {
    return str.replaceAll("@S", "/").replaceAll("@A", "@");
  }

  LiveMessageColor getColor(int type) {
    switch (type) {
      case 1:
        return LiveMessageColor(255, 0, 0);
      case 2:
        return LiveMessageColor(30, 135, 240);
      case 3:
        return LiveMessageColor(122, 200, 75);
      case 4:
        return LiveMessageColor(255, 127, 0);
      case 5:
        return LiveMessageColor(155, 57, 244);
      case 6:
        return LiveMessageColor(255, 105, 180);
      default:
        return LiveMessageColor.white;
    }
  }
}
```

注意：测试文件中 `frameStt("type@=mrkl/")` 断言首字段为帧全长；`frameStt` 写的 total = bytes.length+9，首 4 字节即 total，与 `frame.length` 相等。✓

- [ ] **Step 4: 运行测试**

Run: `cd simple_live_core && dart test test/danmaku/douyu_danmaku_test.dart`
Expected: PASS（5 个测试）。

- [ ] **Step 5: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/danmaku/douyu_danmaku.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add simple_live_core/lib/src/danmaku/douyu_danmaku.dart simple_live_core/test/danmaku/douyu_danmaku_test.dart
git commit -m "feat(core): 斗鱼 wsproxy 发送连接与 chatmessage"
```

---

## Task 7: 斗鱼 Site 接入 cookie 与新 Args

**Files:**
- Modify: `simple_live_core/lib/src/douyu_site.dart`

**Interfaces:**
- Consumes: `DouyuDanmakuArgs({required int roomId, String cookie})`（Task 6）。
- Produces: `DouyuSite.cookie`（字段，默认空串）。

- [ ] **Step 1: 增加 cookie 字段**

在 `douyu_site.dart` 的 `class DouyuSite` 内（类声明开头字段区）增加：

```dart
  /// 用户设置的 cookie
  String cookie = "";
```

- [ ] **Step 2: 替换 danmakuData**

将第 251 行：

```dart
      danmakuData: roomInfo["room_id"].toString(),
```

改为：

```dart
      danmakuData: DouyuDanmakuArgs(
        roomId: int.tryParse(roomInfo["room_id"].toString()) ?? 0,
        cookie: cookie,
      ),
```

- [ ] **Step 3: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/douyu_site.dart`
Expected: No issues found.

- [ ] **Step 4: Commit**

```bash
git add simple_live_core/lib/src/douyu_site.dart
git commit -m "feat(core): DouyuSite 支持 cookie 并使用 DouyuDanmakuArgs"
```

---

## Task 8: 斗鱼账号服务

**Files:**
- Create: `simple_live_app/lib/services/douyu_account_service.dart`

**Interfaces:**
- Consumes: `WebLoginArgs`（Task 5）；`RoutePath.kWebLogin`；`DouyuDanmakuArgs` 不需要——服务只写 `DouyuSite.cookie`。
- Produces: `DouyuAccountService.instance`；`logined`（RxBool）、`name`（RxString）、`cookie`；`startWebLogin()`、`logout()`。

- [ ] **Step 1: 创建服务**

创建 `simple_live_app/lib/services/douyu_account_service.dart`：

```dart
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class DouyuAccountService extends GetxService {
  static DouyuAccountService get instance =>
      Get.find<DouyuAccountService>();

  var logined = false.obs;
  var cookie = "";
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kDouyuCookie, "");
    logined.value = cookie.contains("acf_stk") && cookie.contains("acf_uid");
    name.value = logined.value ? _uid : "未登录";
    setSite();
    super.onInit();
  }

  String get _uid {
    var m = RegExp(r"acf_uid=([^;]+)").firstMatch(cookie);
    return m != null ? "UID: ${m.group(1)}" : "已登录";
  }

  void setSite() {
    var site = Sites.allSites[Constant.kDouyu]!.liveSite as DouyuSite;
    site.cookie = cookie;
  }

  void startWebLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "斗鱼账号登录",
        startUrl: "https://www.douyu.com",
        cookieUrl: "https://www.douyu.com",
        requiredCookies: ["acf_uid", "acf_stk"],
        onSuccess: (cookieStr) {
          cookie = cookieStr;
          LocalStorageService.instance
              .setValue(LocalStorageService.kDouyuCookie, cookieStr);
          logined.value = true;
          name.value = _uid;
          setSite();
          SmartDialog.showToast("斗鱼登录成功");
        },
      ),
    );
  }

  void logout() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kDouyuCookie, "");
    logined.value = false;
    name.value = "未登录";
    setSite();
  }
}
```

- [ ] **Step 2: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/services/douyu_account_service.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add simple_live_app/lib/services/douyu_account_service.dart
git commit -m "feat(app): 斗鱼账号服务（WebView 登录）"
```

---

## Task 9: 虎牙 tars 模型 —— SendMessageReq 等

**Files:**
- Create: `simple_live_core/lib/src/model/tars/huya_send_message_req.dart`
- Test: `simple_live_core/test/danmaku/huya_danmaku_test.dart`

**Interfaces:**
- Consumes: `TarsStruct`（tars_dart）；`HuyaUserId`（已有，`lib/src/model/tars/huya_user_id.dart`）。
- Produces: `HuyaContentFormat`、`HuyaBulletFormat`、`HuyaMessageTagInfo`、`HuyaSendMessageReq`、`HuyaSendMessageRsp`，均为 TarsStruct，字段 tag 见代码。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_core/test/danmaku/huya_danmaku_test.dart`：

```dart
import 'dart:convert';

import 'package:simple_live_core/src/model/tars/huya_send_message_req.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:test/test.dart';

void main() {
  test("SendMessageReq 编码包含 content 与 tag 结构", () {
    var req = HuyaSendMessageReq();
    req.tUserId = HuyaUserId()
      ..lUid = 123
      ..sHuYaUA = "webh5&2004231432&websocket"
      ..sCookie = "udb_uid=123; udb_biztoken=tok";
    req.lTid = 456;
    req.lSid = 456;
    req.lPid = 456;
    req.sContent = "你好";

    var oos = TarsOutputStream();
    req.writeTo(oos);
    var bytes = oos.toUint8List();

    expect(bytes.isNotEmpty, isTrue);
    // tag0 tUserId：首字节 head，tag = 0
    expect(bytes.first & 0x0F, 0);
    // sContent 以 UTF-8 字节存储，断言字节序列存在
    var contentBytes = utf8.encode("你好");
    var found = false;
    for (var i = 0; i <= bytes.length - contentBytes.length; i++) {
      if (contentBytes
          .asMap()
          .entries
          .every((e) => bytes[i + e.key] == e.value)) {
        found = true;
        break;
      }
    }
    expect(found, isTrue);
  });

  test("SendMessageReq 默认字段可编码不报错", () {
    var oos = TarsOutputStream();
    HuyaSendMessageReq().writeTo(oos);
    expect(oos.toUint8List().isNotEmpty, isTrue);
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_core && dart test test/danmaku/huya_danmaku_test.dart`
Expected: FAIL（目标文件/类不存在）。

- [ ] **Step 3: 创建 tars 模型**

创建 `simple_live_core/lib/src/model/tars/huya_send_message_req.dart`：

```dart
import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

import 'huya_user_id.dart';

class HuyaContentFormat extends TarsStruct {
  int iFontColor = 0;
  int iFontSize = 0;
  int iPopupStyle = 0;
  int iNickNameFontColor = 0;
  int iDarkFontColor = 0;
  int iDarkNickNameFontColor = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iFontColor = _is.read(iFontColor, 0, false);
    iFontSize = _is.read(iFontSize, 1, false);
    iPopupStyle = _is.read(iPopupStyle, 2, false);
    iNickNameFontColor = _is.read(iNickNameFontColor, 3, false);
    iDarkFontColor = _is.read(iDarkFontColor, 4, false);
    iDarkNickNameFontColor = _is.read(iDarkNickNameFontColor, 5, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iFontColor, 0);
    _os.write(iFontSize, 1);
    _os.write(iPopupStyle, 2);
    _os.write(iNickNameFontColor, 3);
    _os.write(iDarkFontColor, 4);
    _os.write(iDarkNickNameFontColor, 5);
  }

  @override
  Object deepCopy() => this;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iFontColor, "iFontColor");
  }
}

class HuyaBulletFormat extends TarsStruct {
  int iFontColor = 0;
  int iFontSize = 0;
  int iTextSpeed = 0;
  int iTransitionType = 0;

  @override
  void readFrom(TarsInputStream _is) {
    iFontColor = _is.read(iFontColor, 0, false);
    iFontSize = _is.read(iFontSize, 1, false);
    iTextSpeed = _is.read(iTextSpeed, 2, false);
    iTransitionType = _is.read(iTransitionType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iFontColor, 0);
    _os.write(iFontSize, 1);
    _os.write(iTextSpeed, 2);
    _os.write(iTransitionType, 3);
  }

  @override
  Object deepCopy() => this;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iFontColor, "iFontColor");
  }
}

class HuyaMessageTagInfo extends TarsStruct {
  int iAppId = 1;
  String sTag = "";

  HuyaMessageTagInfo({this.iAppId = 1, this.sTag = ""});

  @override
  void readFrom(TarsInputStream _is) {
    iAppId = _is.read(iAppId, 0, false);
    sTag = _is.read(sTag, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iAppId, 0);
    _os.write(sTag, 1);
  }

  @override
  Object deepCopy() => HuyaMessageTagInfo(iAppId: iAppId, sTag: sTag);

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayString(sTag, "sTag");
  }
}

class HuyaSendMessageReq extends TarsStruct {
  HuyaUserId tUserId = HuyaUserId();
  int lTid = 0;
  int lSid = 0;
  String sContent = "";
  int iShowMode = 0;
  HuyaContentFormat tFormat = HuyaContentFormat();
  HuyaBulletFormat tBulletFormat = HuyaBulletFormat();
  List<HuyaMessageTagInfo> vTagInfo = [HuyaMessageTagInfo()];
  int lPid = 0;

  @override
  void readFrom(TarsInputStream _is) {
    tUserId = _is.read(tUserId, 0, false);
    lTid = _is.read(lTid, 1, false);
    lSid = _is.read(lSid, 2, false);
    sContent = _is.read(sContent, 3, false);
    iShowMode = _is.read(iShowMode, 4, false);
    tFormat = _is.read(tFormat, 5, false);
    tBulletFormat = _is.read(tBulletFormat, 6, false);
    vTagInfo = _is.read(vTagInfo, 7, false);
    lPid = _is.read(lPid, 8, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(tUserId, 0);
    _os.write(lTid, 1);
    _os.write(lSid, 2);
    _os.write(sContent, 3);
    _os.write(iShowMode, 4);
    _os.write(tFormat, 5);
    _os.write(tBulletFormat, 6);
    _os.writeList(vTagInfo, 7);
    _os.write(lPid, 8);
  }

  @override
  Object deepCopy() => HuyaSendMessageReq()..sContent = sContent;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayString(sContent, "sContent");
  }
}

class HuyaSendMessageRsp extends TarsStruct {
  int iStatus = 0;
  String sNotice = "";

  @override
  void readFrom(TarsInputStream _is) {
    iStatus = _is.read(iStatus, 0, false);
    sNotice = _is.read(sNotice, 1, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iStatus, 0);
    _os.write(sNotice, 1);
  }

  @override
  Object deepCopy() => HuyaSendMessageRsp()..iStatus = iStatus;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iStatus, "iStatus");
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `cd simple_live_core && dart test test/danmaku/huya_danmaku_test.dart`
Expected: PASS（2 个测试）。

- [ ] **Step 5: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/model/tars/huya_send_message_req.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add simple_live_core/lib/src/model/tars/huya_send_message_req.dart simple_live_core/test/danmaku/huya_danmaku_test.dart
git commit -m "feat(core): 虎牙 SendMessageReq 等 tars 模型"
```

---

## Task 10: 虎牙 VerifyCookie 与 WupReq 发送

**Files:**
- Create: `simple_live_core/lib/src/model/tars/huya_verify_cookie.dart`
- Modify: `simple_live_core/lib/src/danmaku/huya_danmaku.dart`
- Test: 扩展 `simple_live_core/test/danmaku/huya_danmaku_test.dart`

**Interfaces:**
- Consumes: `TarsUniPacket`（tars_dart，servantName/funcName/put/encode/decode/getByClass）；`HuyaSendMessageReq/Rsp`（Task 9）。
- Produces: `HuyaVerifyCookieReq/Rsp`（tars 模型）；`HuyaDanmaku` 登录与发送能力。

- [ ] **Step 1: 创建 VerifyCookie tars 模型**

创建 `simple_live_core/lib/src/model/tars/huya_verify_cookie.dart`：

```dart
import 'package:tars_dart/tars/codec/tars_displayer.dart';
import 'package:tars_dart/tars/codec/tars_input_stream.dart';
import 'package:tars_dart/tars/codec/tars_output_stream.dart';
import 'package:tars_dart/tars/codec/tars_struct.dart';

class HuyaVerifyCookieReq extends TarsStruct {
  int lUid = 0;
  String sUA = "";
  String sCookie = "";
  String sGuid = "";

  @override
  void readFrom(TarsInputStream _is) {
    lUid = _is.read(lUid, 0, false);
    sUA = _is.read(sUA, 1, false);
    sCookie = _is.read(sCookie, 2, false);
    sGuid = _is.read(sGuid, 3, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(lUid, 0);
    _os.write(sUA, 1);
    _os.write(sCookie, 2);
    _os.write(sGuid, 3);
  }

  @override
  Object deepCopy() => HuyaVerifyCookieReq()
    ..lUid = lUid
    ..sCookie = sCookie;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(lUid, "lUid");
  }
}

class HuyaVerifyCookieRsp extends TarsStruct {
  int iValidate = -1;

  @override
  void readFrom(TarsInputStream _is) {
    iValidate = _is.read(iValidate, 0, false);
  }

  @override
  void writeTo(TarsOutputStream _os) {
    _os.write(iValidate, 0);
  }

  @override
  Object deepCopy() => HuyaVerifyCookieRsp()..iValidate = iValidate;

  @override
  void displayAsString(StringBuffer sb, int level) {
    TarsDisplayer(sb, level: level).DisplayInt(iValidate, "iValidate");
  }
}
```

- [ ] **Step 2: 改造 HuyaDanmaku**

在 `simple_live_core/lib/src/danmaku/huya_danmaku.dart`：

1) import 增加：

```dart
import 'package:tars_dart/tars/tup/tars_uni_packet.dart';
import 'package:simple_live_core/src/model/tars/huya_send_message_req.dart';
import 'package:simple_live_core/src/model/tars/huya_user_id.dart';
import 'package:simple_live_core/src/model/tars/huya_verify_cookie.dart';
```

2) `HuyaDanmakuArgs` 增加 cookie（替换类定义）：

```dart
class HuyaDanmakuArgs {
  final int ayyuid;
  final int topSid;
  final int subSid;
  final String cookie;
  HuyaDanmakuArgs({
    required this.ayyuid,
    required this.topSid,
    required this.subSid,
    this.cookie = "",
  });
  @override
  String toString() {
    return json.encode({
      "ayyuid": ayyuid,
      "topSid": topSid,
      "subSid": subSid,
      "cookie": cookie,
    });
  }
}
```

3) 在 `HuyaDanmaku` 类内增加字段（`late HuyaDanmakuArgs danmakuArgs;` 附近）：

```dart
  static const String kHuyaUA = "webh5&2004231432&websocket";

  int _requestId = 0;
  bool _verified = false;
  final Map<int, Completer<int>> _pendingWup = {};

  String get _uidStr {
    var m = RegExp(r"(?:yyuid|udb_uid)=([^;]+)").firstMatch(
      danmakuArgs.cookie,
    );
    return m?.group(1) ?? "";
  }
```

4) 修改 `joinRoom()`（在发送 RegisterReq 之后追加登录）：

```dart
  void joinRoom() {
    var joinData =
        getJoinData(danmakuArgs.ayyuid, danmakuArgs.topSid, danmakuArgs.topSid);
    webScoketUtils?.sendMessage(joinData);
    if (danmakuArgs.cookie.isNotEmpty) {
      verifyCookie();
    }
  }

  void verifyCookie() {
    var req = HuyaVerifyCookieReq()
      ..lUid = int.tryParse(_uidStr) ?? 0
      ..sUA = kHuyaUA
      ..sCookie = danmakuArgs.cookie
      ..sGuid = "";
    var oos = TarsOutputStream();
    req.writeTo(oos);

    var cmd = TarsOutputStream();
    cmd.write(10, 0);
    cmd.write(oos.toUint8List(), 1);
    webScoketUtils?.sendMessage(cmd.toUint8List());
  }
```

5) 修改 `decodeMessage`：现有逻辑只处理 `type == 7`。在 `var type = stream.read(0, 0, false);` 之后增加分支（保留原 type==7 逻辑）：

```dart
      if (type == 11) {
        var inner = TarsInputStream(
          stream.readBytes(1, false),
        );
        var rsp = HuyaVerifyCookieRsp();
        rsp.readFrom(inner);
        if (rsp.iValidate == 0) {
          _verified = true;
        }
        return;
      }
      if (type == 4) {
        var bytes = stream.readBytes(1, false) as Uint8List;
        var packet = TarsUniPacket();
        packet.decode(bytes);
        var id = packet.requestId;
        var completer = _pendingWup.remove(id);
        if (completer != null) {
          var rsp = packet.getByClass(
            "tReq",
            HuyaSendMessageRsp(),
          );
          completer.complete(rsp.iStatus);
        }
        return;
      }
```

6) 增加 sendMessage（放在 `stop()` 之前）：

```dart
  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    if (danmakuArgs.cookie.isEmpty || _uidStr.isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未登录虎牙",
      );
    }
    if (!_verified) {
      var waited = 0;
      while (!_verified && waited < 50) {
        await Future.delayed(const Duration(milliseconds: 100));
        waited++;
      }
      if (!_verified) {
        return DanmakuSendResult(
          success: false,
          errorCode: "login_failed",
          errorMessage: "虎牙登录校验失败",
        );
      }
    }

    var req = HuyaSendMessageReq();
    req.tUserId = HuyaUserId()
      ..lUid = int.tryParse(_uidStr) ?? 0
      ..sHuYaUA = kHuyaUA
      ..sCookie = danmakuArgs.cookie
      ..sDeviceInfo = "Chrome";
    req.lTid = danmakuArgs.ayyuid;
    req.lSid = danmakuArgs.ayyuid;
    req.lPid = danmakuArgs.ayyuid;
    req.sContent = message;

    var wup = TarsUniPacket();
    wup.servantName = "liveui";
    wup.funcName = "sendMessage";
    var id = ++_requestId;
    wup.requestId = id;
    wup.put("tReq", req);
    var vData = wup.encode();

    var cmd = TarsOutputStream();
    cmd.write(3, 0);
    cmd.write(vData, 1);

    var completer = Completer<int>();
    _pendingWup[id] = completer;
    webScoketUtils?.sendMessage(cmd.toUint8List());

    var timer = Timer(const Duration(seconds: 10), () {
      var c = _pendingWup.remove(id);
      if (c != null && !c.isCompleted) {
        c.complete(-999);
      }
    });
    var status = await completer.future;
    timer.cancel();

    if (status == 0) {
      return DanmakuSendResult(success: true);
    }
    if (status == -999) {
      return DanmakuSendResult(
        success: false,
        errorCode: "timeout",
        errorMessage: "发送超时",
      );
    }
    return DanmakuSendResult(
      success: false,
      errorCode: status.toString(),
      errorMessage: "发送失败",
    );
  }
```

7) `stop()` 中补充状态清理：

```dart
  @override
  Future stop() async {
    onMessage = null;
    onClose = null;
    _verified = false;
    for (var c in _pendingWup.values) {
      if (!c.isCompleted) {
        c.complete(-999);
      }
    }
    _pendingWup.clear();
    webScoketUtils?.close();
  }
```

- [ ] **Step 3: 静态分析**

Run: `cd simple_live_core && dart analyze lib/src/danmaku/huya_danmaku.dart lib/src/model/tars/huya_verify_cookie.dart`
Expected: No issues found.

- [ ] **Step 4: 回归全部 Core 弹幕测试**

Run: `cd simple_live_core && dart test test/danmaku/`
Expected: 全部 PASS。

- [ ] **Step 5: Commit**

```bash
git add simple_live_core/lib/src/danmaku/huya_danmaku.dart simple_live_core/lib/src/model/tars/huya_verify_cookie.dart
git commit -m "feat(core): 虎牙 VerifyCookie 登录与 WupReq 发送弹幕"
```

---

## Task 11: 虎牙 Site 接入 cookie

**Files:**
- Modify: `simple_live_core/lib/src/huya_site.dart`

**Interfaces:**
- Consumes: `HuyaDanmakuArgs({ayyuid, topSid, subSid, cookie})`（Task 10）。
- Produces: `HuyaSite.cookie`（字段）。

- [ ] **Step 1: 增加 cookie 字段**

在 `huya_site.dart` 的类字段区增加：

```dart
  /// 用户设置的 cookie
  String cookie = "";
```

- [ ] **Step 2: danmakuData 带 cookie**

将第 408-412 行：

```dart
      danmakuData: HuyaDanmakuArgs(
        ayyuid: tLiveInfo["lYyid"] ?? 0,
        topSid: topSid ?? 0,
        subSid: subSid ?? 0,
      ),
```

改为：

```dart
      danmakuData: HuyaDanmakuArgs(
        ayyuid: tLiveInfo["lYyid"] ?? 0,
        topSid: topSid ?? 0,
        subSid: subSid ?? 0,
        cookie: cookie,
      ),
```

- [ ] **Step 3: 静态分析并提交**

Run: `cd simple_live_core && dart analyze lib/src/huya_site.dart`
Expected: No issues found.

```bash
git add simple_live_core/lib/src/huya_site.dart
git commit -m "feat(core): HuyaSite 支持 cookie"
```

---

## Task 12: 虎牙账号服务

**Files:**
- Create: `simple_live_app/lib/services/huya_account_service.dart`

**Interfaces:**
- Consumes: `WebLoginArgs`（Task 5）；`RoutePath.kWebLogin`。
- Produces: `HuyaAccountService.instance`；`logined`、`name`、`cookie`、`startWebLogin()`、`logout()`。

- [ ] **Step 1: 创建服务**

创建 `simple_live_app/lib/services/huya_account_service.dart`：

```dart
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class HuyaAccountService extends GetxService {
  static HuyaAccountService get instance =>
      Get.find<HuyaAccountService>();

  var logined = false.obs;
  var cookie = "";
  var name = "未登录".obs;

  @override
  void onInit() {
    cookie = LocalStorageService.instance
        .getValue(LocalStorageService.kHuyaCookie, "");
    logined.value = cookie.contains("udb_biztoken");
    name.value = logined.value ? _uid : "未登录";
    setSite();
    super.onInit();
  }

  String get _uid {
    var m = RegExp(r"(?:yyuid|udb_uid)=([^;]+)").firstMatch(cookie);
    return m != null ? "UID: ${m.group(1)}" : "已登录";
  }

  void setSite() {
    var site = Sites.allSites[Constant.kHuya]!.liveSite as HuyaSite;
    site.cookie = cookie;
  }

  void startWebLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "虎牙账号登录",
        startUrl: "https://www.huya.com",
        cookieUrl: "https://www.huya.com",
        requiredCookies: ["udb_biztoken"],
        onSuccess: (cookieStr) {
          cookie = cookieStr;
          LocalStorageService.instance
              .setValue(LocalStorageService.kHuyaCookie, cookieStr);
          logined.value = true;
          name.value = _uid;
          setSite();
          SmartDialog.showToast("虎牙登录成功");
        },
      ),
    );
  }

  void logout() {
    cookie = "";
    LocalStorageService.instance
        .setValue(LocalStorageService.kHuyaCookie, "");
    logined.value = false;
    name.value = "未登录";
    setSite();
  }
}
```

- [ ] **Step 2: 静态分析并提交**

Run: `cd simple_live_app && flutter analyze lib/services/huya_account_service.dart`
Expected: No issues found.

```bash
git add simple_live_app/lib/services/huya_account_service.dart
git commit -m "feat(app): 虎牙账号服务（WebView 登录）"
```

---

## Task 13: LiveRoomController —— sendDanmaku 与错误文案

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`
- Test: `simple_live_app/test/send_danmaku_error_test.dart`

**Interfaces:**
- Consumes: `liveDanmaku.sendMessage`（Core）；各账号服务 instance。
- Produces:
  - `Future<void> sendDanmaku(String text)`
  - `var sendingDanmaku = false.obs`
  - `String get currentUserName`
  - `static String danmakuErrorText(String platform, DanmakuSendResult result)`

- [ ] **Step 1: 写失败测试**

创建 `simple_live_app/test/send_danmaku_error_test.dart`：

```dart
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:flutter_test/flutter_test.dart';

DanmakuSendResult result(String code, {bool needEcho = false}) =>
    DanmakuSendResult(
      success: false,
      errorCode: code,
      needLocalEcho: needEcho,
    );

void main() {
  group("danmakuErrorText", () {
    test("未登录", () {
      expect(
        LiveRoomController.danmakuErrorText(
          "bilibili",
          result("not_login"),
        ).contains("登录"),
        isTrue,
      );
    });
    test("B站禁言码1", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("1")),
        "你已被禁言",
      );
    });
    test("频率限制", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("11")),
        "发言太快，请稍后再试",
      );
    });
    test("抖音敏感词", () {
      expect(
        LiveRoomController.danmakuErrorText("douyin", result("50004")),
        "内容包含敏感词",
      );
    });
    test("抖音未登录", () {
      expect(
        LiveRoomController.danmakuErrorText("douyin", result("8")),
        "未登录或登录已失效",
      );
    });
    test("兜底文案", () {
      expect(
        LiveRoomController.danmakuErrorText("bilibili", result("999")),
        "弹幕发送失败",
      );
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `cd simple_live_app && flutter test test/send_danmaku_error_test.dart`
Expected: FAIL（`danmakuErrorText` 不存在）。

- [ ] **Step 3: 实现错误映射、sendDanmaku、当前用户名**

在 `live_room_controller.dart`：

1) import 增加：

```dart
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
```

（bilibili/douyin/twitch 服务文件已在其他地方间接可用；保险起见把下面三个也加入 import）

```dart
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
```

2) 在类字段区（`messages` 附近）增加：

```dart
  /// 弹幕发送中
  var sendingDanmaku = false.obs;

  String get currentUserName {
    switch (site.id) {
      case Constant.kBiliBili:
        return BiliBiliAccountService.instance.name.value;
      case Constant.kDouyu:
        return DouyuAccountService.instance.name.value;
      case Constant.kHuya:
        return HuyaAccountService.instance.name.value;
      case Constant.kDouyin:
        return DouyinAccountService.instance.loginName.value;
      case Constant.kTwitch:
        return detail.value?.danmakuData is TwitchDanmakuArgs
            ? (detail.value!.danmakuData as TwitchDanmakuArgs).userLogin
            : "";
      default:
        return "";
    }
  }

3) 增加 sendDanmaku 与静态错误映射（放在 `onWSMessage` 附近）：

```dart
  Future<void> sendDanmaku(String text) async {
    var content = text.trim();
    if (content.isEmpty) {
      return;
    }
    if (content.length > 200) {
      SmartDialog.showToast("弹幕内容过长（最多200字）");
      return;
    }
    sendingDanmaku.value = true;
    try {
      var result = await liveDanmaku.sendMessage(content);
      if (result.success) {
        if (result.needLocalEcho) {
          onWSMessage(LiveMessage(
            type: LiveMessageType.chat,
            userName: currentUserName,
            message: content,
            color: LiveMessageColor.white,
          ));
        }
      } else {
        SmartDialog.showToast(
          danmakuErrorText(site.id, result),
        );
      }
    } finally {
      sendingDanmaku.value = false;
    }
  }

  static String danmakuErrorText(String platform, DanmakuSendResult result) {
    var code = result.errorCode;
    if (code == "not_login") {
      return "未登录，请先在账号管理中登录";
    }
    if (code == "rate_limit") {
      return "发言太快，请稍后再试";
    }
    if (code == "network_error" || code == "timeout") {
      return "网络异常，请稍后再试";
    }
    if (platform == Constant.kBiliBili) {
      switch (code) {
        case "1":
        case "13":
          return "你已被禁言";
        case "3":
          return "房间已锁定，无法发言";
        case "11":
          return "发言太快，请稍后再试";
        case "12":
          return "弹幕内容过长";
        case "14":
          return "该房间仅粉丝团可发言";
        case "15":
          return "需要绑定手机后才能发言";
      }
    }
    if (platform == Constant.kDouyin) {
      switch (code) {
        case "8":
          return "未登录或登录已失效";
        case "9":
          return "账号已被封禁";
        case "50001":
          return "你已被禁言";
        case "50004":
          return "内容包含敏感词";
        case "50008":
          return "当前账号发言受限";
        case "3009008":
          return "发言太快，请稍后再试";
      }
    }
    if (platform == Constant.kDouyu) {
      if (code == "muted") {
        return "你已被禁言";
      }
    }
    if (platform == Constant.kHuya) {
      if (code != "0") {
        return result.errorMessage.isNotEmpty ? result.errorMessage : "弹幕发送失败";
      }
    }
    return "弹幕发送失败";
  }
```

`TwitchDanmakuArgs` 已由 `package:simple_live_core/simple_live_core.dart` 导出（simple_live_core.dart 第 16 行），无需额外 import。

- [ ] **Step 4: 运行测试确认通过**

Run: `cd simple_live_app && flutter test test/send_danmaku_error_test.dart`
Expected: PASS（6 个测试）。

- [ ] **Step 5: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/modules/live_room/live_room_controller.dart`
Expected: No issues found.

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/test/send_danmaku_error_test.dart
git commit -m "feat(app): LiveRoomController sendDanmaku 与错误文案映射"
```

---

## Task 14: 竖屏底部输入栏（手机 + 平板）

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_page.dart`

**Interfaces:**
- Consumes: `controller.sendDanmaku`、`controller.sendingDanmaku`（Task 13）；账号服务（未登录引导）。
- Produces: `Widget buildSendDanmakuBar(BuildContext context)`。

- [ ] **Step 1: 增加未登录检查与输入栏组件**

在 `live_room_page.dart` 中：

1) 顶部 import 增加：

```dart
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
```

（若某条与已有 import 重复，跳过。）

2) 在 `buildBottomActions` 方法之前增加：

```dart
  bool get _isLogined {
    switch (controller.site.id) {
      case Constant.kBiliBili:
        return BiliBiliAccountService.instance.logined.value;
      case Constant.kDouyu:
        return DouyuAccountService.instance.logined.value;
      case Constant.kHuya:
        return HuyaAccountService.instance.logined.value;
      case Constant.kDouyin:
        return DouyinAccountService.instance.logined.value;
      case Constant.kTwitch:
        return TwitchAccountService.instance.configured.value;
      default:
        return false;
    }
  }

  Future<void> _showLoginDialog() async {
    var result = await Utils.showAlertDialog(
      "登录后才能发送弹幕，是否前往账号管理？",
      title: "未登录",
    );
    if (result) {
      Get.toNamed(RoutePath.kSettingsAccount);
    }
  }

  Widget buildSendDanmakuBar(BuildContext context) {
    var inputController = TextEditingController();
    return Container(
      padding: AppStyle.edgeInsetsH12.copyWith(top: 6, bottom: 6),
      color: Theme.of(context).cardColor,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: inputController,
              maxLength: 200,
              textInputAction: TextInputAction.send,
              decoration: InputDecoration(
                hintText: "说点什么…",
                counterText: "",
                isDense: true,
                contentPadding: AppStyle.edgeInsetsA12,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                ),
              ),
              onSubmitted: (v) async {
                if (!_isLogined) {
                  _showLoginDialog();
                  return;
                }
                await controller.sendDanmaku(v);
                inputController.clear();
              },
            ),
          ),
          AppStyle.hGap8,
          Obx(
            () => IconButton(
              onPressed: controller.sendingDanmaku.value
                  ? null
                  : () async {
                      if (!_isLogined) {
                        _showLoginDialog();
                        return;
                      }
                      await controller.sendDanmaku(inputController.text);
                      inputController.clear();
                    },
              icon: controller.sendingDanmaku.value
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
            ),
          ),
        ],
      ),
    );
  }
```

- [ ] **Step 2: 手机布局插入输入栏**

将 `buildPhoneUI`（第 135-147 行）改为：

```dart
  Widget buildPhoneUI(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: buildMediaPlayer(),
        ),
        buildUserProfile(context),
        buildMessageArea(),
        buildSendDanmakuBar(context),
        buildBottomActions(context),
      ],
    );
  }
```

- [ ] **Step 3: 平板布局插入输入栏**

平板底部 Container（第 170 行开始）的 `child: Row(...)`——将其内容整体包一层，改为 Column：

把该 Container 的 `child: Row(...)` 替换为：

```dart
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildSendDanmakuBar(context),
              Row(
                children: [
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.refreshRoom,
                    icon: const Icon(Remix.refresh_line),
                    label: const Text("刷新"),
                  ),
                  AppStyle.hGap4,
                  Obx(
                    () => controller.followed.value
                        ? TextButton.icon(
                            style: TextButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 14),
                            ),
                            onPressed: controller.removeFollowUser,
                            icon: const Icon(Remix.heart_fill),
                            label: const Text("取消关注"),
                          )
                        : TextButton.icon(
                            style: TextButton.styleFrom(
                              textStyle: const TextStyle(fontSize: 14),
                            ),
                            onPressed: controller.followUser,
                            icon: const Icon(Remix.heart_line),
                            label: const Text("关注"),
                          ),
                  ),
                  const Expanded(child: Center()),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.share,
                    icon: const Icon(Remix.share_line),
                    label: const Text("分享"),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.copyUrl,
                    icon: const Icon(Remix.file_copy_line),
                    label: const Text("复制链接"),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      textStyle: const TextStyle(fontSize: 14),
                    ),
                    onPressed: controller.copyPlayUrl,
                    icon: const Icon(Remix.file_copy_line),
                    label: const Text("复制播放直链"),
                  ),
                ],
              ),
            ],
          ),
```

- [ ] **Step 4: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/modules/live_room/live_room_page.dart`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add simple_live_app/lib/modules/live_room/live_room_page.dart
git commit -m "feat(app): 房间页底部弹幕输入栏（手机与平板）"
```

---

## Task 15: 全屏控制栏发送按钮与弹框

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/player/player_controls.dart`

**Interfaces:**
- Consumes: `LiveRoomController.sendDanmaku`；`Utils.showEditTextDialog(content, {title, hintText})`（已有，返回 String?）。
- Produces: 全屏控制 Row 中弹幕设置按钮之后一个发送 IconButton。

- [ ] **Step 1: 增加发送按钮**

在 `player_controls.dart` 的 `buildFullControls` 内，弹幕设置 IconButton（第 278-287 行）之后插入：

```dart
                  IconButton(
                    onPressed: () async {
                      var text = await Utils.showEditTextDialog(
                        "",
                        title: "发送弹幕",
                        hintText: "说点什么…",
                      );
                      if (text == null || text.trim().isEmpty) {
                        return;
                      }
                      await controller.sendDanmaku(text);
                    },
                    icon: const Icon(
                      Remix.chat_3_line,
                      color: Colors.white,
                    ),
                  ),
```

- [ ] **Step 2: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/modules/live_room/player/player_controls.dart`
Expected: No issues found.

- [ ] **Step 3: Commit**

```bash
git add simple_live_app/lib/modules/live_room/player/player_controls.dart
git commit -m "feat(app): 全屏控制栏增加发送弹幕按钮"
```

---

## Task 16: 账号页接入与服务注册

**Files:**
- Modify: `simple_live_app/lib/main.dart`
- Modify: `simple_live_app/lib/modules/mine/account/account_page.dart`
- Modify: `simple_live_app/lib/modules/mine/account/account_controller.dart`

**Interfaces:**
- Consumes: Douyu/HuyaAccountService（Task 8/12）、DouyinAccountService 新方法（Task 5）。
- Produces: 账号页三个入口的完整登录/退出交互。

- [ ] **Step 1: main.dart 注册服务**

在 `main.dart` 第 139 行 `Get.put(TwitchAccountService());` 之后增加：

```dart
  Get.put(DouyuAccountService());

  Get.put(HuyaAccountService());
```

并在文件顶部增加 import：

```dart
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
```

- [ ] **Step 2: account_controller 增加三个 tap**

在 `account_controller.dart`：

1) import 增加：

```dart
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
```

2) 在类内增加方法：

```dart
  void douyuTap() async {
    if (DouyuAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出斗鱼账号吗？", title: "退出登录");
      if (result) {
        DouyuAccountService.instance.logout();
      }
    } else {
      DouyuAccountService.instance.startWebLogin();
    }
  }

  void huyaTap() async {
    if (HuyaAccountService.instance.logined.value) {
      var result = await Utils.showAlertDialog("确定要退出虎牙账号吗？", title: "退出登录");
      if (result) {
        HuyaAccountService.instance.logout();
      }
    } else {
      HuyaAccountService.instance.startWebLogin();
    }
  }

  void douyinLoginTap() {
    DouyinAccountService.instance.logout();
    SmartDialog.showToast("已退出抖音账号");
  }

  void douyinLogin() {
    Get.toNamed(
      RoutePath.kWebLogin,
      arguments: WebLoginArgs(
        title: "抖音账号登录",
        startUrl: "https://live.douyin.com",
        cookieUrl: "https://live.douyin.com",
        requiredCookies: ["sessionid"],
        onSuccess: (cookieStr) {
          DouyinAccountService.instance.setLoginCookie(cookieStr);
          SmartDialog.showToast("抖音登录成功");
        },
      ),
    );
  }

  void douyinMenu() {
    Utils.showBottomSheet(
      title: "抖音",
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.account_circle_outlined),
            title: Text(DouyinAccountService.instance.logined.value
                ? "退出账号登录"
                : "账号登录（可发送弹幕）"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              if (DouyinAccountService.instance.logined.value) {
                douyinLoginTap();
              } else {
                douyinLogin();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text("自定义 ttwid"),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Get.back();
              doDouyinCookieConfig();
            },
          ),
        ],
      ),
    );
  }
```

3) 将原 `douyinTap` 方法改为：

```dart
  void douyinTap() {
    douyinMenu();
  }
```

4) import 增加（WebLoginArgs、RoutePath 可能尚未 import）：

```dart
import 'package:simple_live_app/modules/mine/account/web_login.dart';
```

（`RoutePath` 已在文件中 import。）

- [ ] **Step 3: account_page 更新三个 ListTile**

在 `account_page.dart`：

1) import 增加：

```dart
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
```

2) 顶部说明文字（第 22-25 行）替换为：

```dart
          const Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "登录后可在直播间发送弹幕，哔哩哔哩登录后还可观看高清晰度直播。",
              textAlign: TextAlign.center,
            ),
          ),
```

3) 斗鱼 ListTile（第 42-52 行）替换为：

```dart
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/douyu.png',
                width: 36,
                height: 36,
              ),
              title: const Text("斗鱼直播"),
              subtitle: Text(DouyuAccountService.instance.name.value),
              trailing: DouyuAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.douyuTap,
            ),
          ),
```

4) 虎牙 ListTile（第 53-63 行）替换为：

```dart
          Obx(
            () => ListTile(
              leading: Image.asset(
                'assets/images/huya.png',
                width: 36,
                height: 36,
              ),
              title: const Text("虎牙直播"),
              subtitle: Text(HuyaAccountService.instance.name.value),
              trailing: HuyaAccountService.instance.logined.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
              onTap: controller.huyaTap,
            ),
          ),
```

5) 抖音 ListTile（第 64-80 行）的 subtitle/trailing 替换为：

```dart
              subtitle: Text(DouyinAccountService.instance.logined.value
                  ? "账号已登录"
                  : DouyinAccountService.instance.hasCookie.value
                      ? "自定义 ttwid（${DouyinAccountService.instance.cookie.length} 字符）"
                      : "使用默认 ttwid"),
              trailing: DouyinAccountService.instance.logined.value ||
                      DouyinAccountService.instance.hasCookie.value
                  ? const Icon(Icons.logout)
                  : const Icon(Icons.chevron_right),
```

（抖音 trailing 统一显示 logout 会让「自定义 ttwid」也走退出图标但 onTap 已打开菜单，菜单内可处理；保持现状逻辑即可。）

- [ ] **Step 4: 静态分析**

Run: `cd simple_live_app && flutter analyze lib/main.dart lib/modules/mine/account/`
Expected: No issues found.

- [ ] **Step 5: Commit**

```bash
git add simple_live_app/lib/main.dart simple_live_app/lib/modules/mine/account/
git commit -m "feat(app): 账号页接入斗鱼/虎牙/抖音登录"
```

---

## Task 17: 全量测试与构建验证

**Files:** 无新增，验证性任务。

- [ ] **Step 1: Core 全部测试**

Run: `cd simple_live_core && dart test`
Expected: 全部 PASS。

- [ ] **Step 2: App 全部测试**

Run: `cd simple_live_app && flutter test`
Expected: 全部 PASS（含现有 widget_test）。

- [ ] **Step 3: 双端静态分析**

Run: `cd simple_live_core && dart analyze`
Expected: No issues found.

Run: `cd simple_live_app && flutter analyze`
Expected: No issues found.

- [ ] **Step 4: APK 构建**

Run: `cd simple_live_app && flutter build apk --debug`
Expected: 构建成功产出 app-debug.apk。

- [ ] **Step 5: 同步更新 spec 偏差并提交**

将本计划 Global Constraints 中的 3 条调研偏差同步到 spec（`2026-09-22-send-danmaku-design.md`）：
1. 2.2 节 websec 段落改为「弹幕发送使用 vk 签名，websec 仅直播流使用」；
2. 2.3 节登录改为 WebView 方式；
3. chatmessage 字段列表删除 rid。

```bash
git add docs/10_ai_workflows/superpowers/specs/2026-09-22-send-danmaku-design.md
git commit -m "docs: 按实际实现修正斗鱼/虎牙方案偏差"
```

---

## Task 18: 真机手工验证

在 Android 真机上逐平台执行（这是功能正确性的最终验证，无法被自动化测试替代）：

- [ ] 哔哩哔哩：账号页登录（扫码）→ 进入房间 → 底部栏发一条「测试」→ 聊天列表与弹幕层均可见；再从全屏控制栏发送一条。
- [ ] Twitch：账号页配置 token → 进入房间 → 发送 → 本地立即出现在列表（不回环）。
- [ ] 抖音：账号页菜单选账号登录 → WebView 登录成功 → 进房发送；若返回验证码错误，记录实际响应，后续 P2 处理。
- [ ] 斗鱼：账号页 WebView 登录 → 进房发送 → 收到自己的广播；间隔 2 秒内连点验证频率拦截。
- [ ] 虎牙：账号页 WebView 登录 → 进房发送 → WupRsp iStatus=0；如房间策略拦截，记录 iStatus 值。
- [ ] 未登录场景：退出全部账号 → 点发送 → 弹「前往账号管理」对话框 → 跳转正确。
- [ ] 异常场景：断网发送 → 「网络异常」toast；超长输入（>200 字）被拦截。

将真机中发现的协议偏差反馈到对应实现与 spec；如有修复，按正常 TDD 流程补测试再修。
