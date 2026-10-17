# M4-3 账号面 Presence IPC 实施计划（多窗口）

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让子窗口抖音直播间标签以"借用主窗登录身份 + 主引擎唯一仲裁器远端标签混栈"的方式参与 M3 presence：可进场、可点赞/灯牌/入团/点亮、心跳与全部账号 HTTP 收口主引擎，cookie 仅内存单次下行、退出即清；同时收口 M3 网关健壮性 #1–#8 与子窗深路由防御。

**Architecture:** 唯一 `PresenceArbiter`/心跳 Timer 仍在主引擎 `DouyinPresenceGateway`；主引擎新增 `MainPresenceService`（经 `MainDataPlaneService` 默认分支委托收 pr_ 流量，不重挂 dmw handler），把远端标签实现为 `RemotePresenceTab`（implements 既有 `DouyinPresenceTab`）与本地标签混栈仲裁。子引擎每窗一个 `IpcPresenceCoordinator`，为每个控制器造一个实现统一 `PresenceClient` 接口的 per-tab proxy；控制器只持有 `PresenceClient`，主窗本地用 `LocalPresenceClient`、子窗用 IPC proxy，调用点无分支。下行三 apply 只传 `{cookie,status,reentered}`，子端自己重取账号详情自连弹幕。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4（固定 `C:/tools/flutter347/flutter/bin/flutter.bat`）、GetX 4.7.3、desktop_multi_window 0.3.1、Hive 2.2.3、dio 5.x、fake_async、uuid、flutter_smart_dialog。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-17-multiwindow-m4-3-account-presence-ipc-design.md`（spec 是权威；本计划是其论证，冲突以 spec 为准，记入 ledger Ruling）。

## Global Constraints

- 始终简体中文回复与撰写注释/文案/commit。
- Flutter 一律用固定 SDK：`C:/tools/flutter347/flutter/bin/flutter.bat`（3.47.5/Dart 3.13.4，AGENTS.md 的 3.38 不作为依据）。flutter 命令 cwd=`D:\project\dart_simple_live\simple_live_app`；git 根在上一级 `D:\project\dart_simple_live`。
- 每任务门禁：`flutter analyze` 相对基线零新增（基线 22 条 = 2 warning + 20 info，不得增加）；全量 `flutter test` 绿（**基线 234**）；接线/注册/路由任务额外 `flutter build windows --debug` 成功。
- 新文件一律 `package:simple_live_app/...` 绝对 import。
- GetX 4.7.3：`Get.reset()` 返回 void（勿当 Future）；`firstWhereOrNull` 由 get 导出；permanent + tag 容器语义不变。
- dmw 0.3.1 事实：windowId 是 **String**；每个引擎每个 channel 只有**单 handler 槽位**，重复 `setWindowMethodHandler` 即覆盖——pr_ 流量**绝不许**重挂主窗 handler，只许经 `MainDataPlaneService.handleCall` 的 `default` 分支一行委托给 `MainPresenceService.handleCall`；主端 handler 收到的 MethodCall **不含来源 windowId**，子端每个载荷**必带 windowId**；同引擎 handler 调用同 task runner FIFO。
- Android/TV/首页路由零行为变化：无 `tabId` 路径（Android、`Get.toNamed` 独立房间页）一行不动；非 Windows 不注册任何 presence IPC 服务；bili/huya 控制器发送直连路径不改。
- 凭据安全：敏感键 17 具名 + `GuardAccountId_` 前缀清单不变；cookie/token 绝不进 dp_ 通道/开窗快照/RemoteKvBox/任何日志；登录 cookie 只在 `pr_apply_enter` 内存载荷下行一次；`PresenceProtocol.sanitizeForLog` 脱敏（`<cookie:Nchars>`，单测钉死不含 `sessionid`）；三个失效点（收到 yield、收到 suspended、coordinator onClose）立即 `setBorrowedLoginCookie(null)`。
- 不做真实 dmw 双引擎自动化测试（同 M3/M4-2 策略），交 GUI 清单；**执行者不得声称 GUI 已过**。本里程碑 GUI 11 项由用户合并后在本机执行。
- git：严禁 `git add -A` / `git add .`，只 `git add` 精确路径；仓内约 40 个与本任务无关的存量脏文件（.idea/.opencode/generated_plugin_registrant/build reports/simple_live_tv_app gradle 等）不碰、不还原、不清理；commit message 用简体中文，结尾空行 + `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`；**不 push、不合并**（合并方式与时机用户定）。
- 测试 Timer 卫生：普通（非 fakeAsync）测试涉及 periodic Timer 时例尾 `await Future.delayed(120ms)` 排空或显式 `stopHeartbeatForTesting()`；fakeAsync 用例结束前 `elapse` 排空并取消 Timer，不得遗留悬挂计时器。
- 站点 id 字面量：`bilibili`/`douyin`/`douyu`/`huya`/`twitch`；抖音判定优先用 `Constant.kDouyin`（值 `"douyin"`）。
- 边界（非目标）：子窗弹幕发送 UI 不恢复（底部栏保持置灰、全屏回车只 toast），留 M5；bili/huya/douyu/twitch 子窗写动作不做，留 M5；`pr_detach` 仅协议 + 单测，本计划无生产调用点（M4-4 接线）。
- 逐字代码若触发 lint，允许的合法偏离仅限删冗余 import / 补 `const`，且必须在任务报告"偏离记录"中写明。

## File Structure

新增（均在 `simple_live_app/lib/`）：

| 文件 | 职责 | 引入任务 |
|---|---|---|
| `app/multiwindow/presence/presence_client.dart` | `PresenceClient` 接口、`PresenceClaimResult`/`PresenceFailureReason`、`PresenceSendResult` 与 not_holder/not_login 码常量 | T1 |
| `app/multiwindow/presence/presence_batch_releaser.dart` | 单方法接口 `PresenceBatchReleaser.batchRelease(Set<String>)` | T3 |
| `app/multiwindow/presence/ipc/presence_protocol.dart` | pr_ 常量/编解码/reason 码/guard 回执/sanitizeForLog | T4 |
| `app/multiwindow/presence/ipc/sub_presence_port.dart` | 抽象出站端口 + `DmwSubPresencePort`（子→主 invokeMain） | T7 |
| `app/multiwindow/presence/ipc/remote_presence_tab.dart` | 主侧 `DouyinPresenceTab` 远端实现（含详情取数/cookie 读取注入） | T7 |
| `app/multiwindow/presence/ipc/main_presence_service.dart` | 主侧 GetxService：6 入站 handler、tabId→windowId 索引、死亡订阅 | T7 |
| `app/multiwindow/presence/ipc/ipc_presence_coordinator.dart` | 子侧每窗协调者：出站 IPC、per-tab client、三 apply、batchRelease | T9 |
| `app/multiwindow/shell/sub_window_blocked_page.dart` | 子窗深路由防御包装 | T12 |

修改：

| 文件 | 改动概要 | 任务 |
|---|---|---|
| `presence/presence_claimant.dart` | 删除 `PresenceClaimResult`（迁 T1），只留 `DouyinPresenceTab` | T1 |
| `presence/local_presence_client.dart` | `implements PresenceClient`，补 isClaimed/sendDanmaku/sendAction | T1 |
| `presence/douyin_presence_gateway.dart` | send*AsHolder 串行域；GetxService/onClose；reason 细分+登录态注入；#4/#5/#6/#7；心跳 reregister 失败 suspended；implements PresenceBatchReleaser | T1/T2/T3 |
| `modules/live_room/live_room_controller.dart` | 接口换型；抖音发送/action 改道 client + not_holder 一次重试；reason 文案；applySuspended 异步；implements PresenceApplyTarget；bindSubWindowPresence/presenceClaimArgs 子窗绑定与入口守卫①–④ | T1/T2/T10/T11 |
| `shell/tab_store.dart` | 字段换型 PresenceBatchReleaser；#8 _batchClosing | T3 |
| `window/window_registry.dart` | reconcile 返回摘除 Set | T5 |
| `window/window_open_service.dart` | onChildWindowsClosed 广播流 | T5 |
| `data/main_data_plane_service.dart` | 可选 unhandledMethodHandler，default 委托（dp_ 零变化） | T8 |
| `services/douyin_account_service.dart` | setBorrowedLoginCookie 内存单点 | T6 |
| `shell/room_controller_registry.dart` + getx 实现 | controllerForTabId | T10 |
| `bootstrap/sub_engine_bootstrap.dart` | 装配 coordinator、handler 三 case、TabStore 注入 releaser | T10 |
| `routes/app_pages.dart` | kShell 注册 MainPresenceService + 委托；isAccountLoggedIn 注入；4 路由包 SubWindowBlockedPage | T2/T8/T12 |

测试基线 234，本计划新增用例约 40（T1≈9、T2≈6、T3=1、T4=4、T5=2、T6≈3、T7=6、T8=1、T9=6、T10=0、T11=3、T12=2；其中 2 例为既有断言改写而非净增），完成约 270–275；最终计数以 T13 全量实跑为准。

---

### Task 1: PresenceClient 接口 + claim 结果迁移 + 写动作串行域 + 控制器改道

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/presence_client.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/local_presence_client.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`
- Test: `simple_live_app/test/douyin_presence_gateway_test.dart`
- Test: `simple_live_app/test/presence_gateway_controller_test.dart`
- Test: `simple_live_app/test/send_danmaku_error_test.dart`
- Create: `simple_live_app/test/presence_client_reroute_test.dart`

**Interfaces:**
- Produces（后续任务消费，命名锁定）：
  - `enum PresenceFailureReason { notLoggedIn, notConfigured, detailFailed, enterFailed, ipcFailed }`
  - `class PresenceClaimResult`：`final bool granted; final PresenceFailureReason? reason;`；具名构造 `const PresenceClaimResult.granted()` 与 `const PresenceClaimResult.failure({required PresenceFailureReason reason})`。
  - `const String kPresenceCodeNotHolder = 'not_holder';`、`const String kPresenceCodeNotLogin = 'not_login';`
  - `class PresenceSendResult { final bool success; final String? code; final String? message; const PresenceSendResult({required this.success, this.code, this.message}); static const PresenceSendResult notHolder = PresenceSendResult(success:false, code: kPresenceCodeNotHolder); }`
  - `abstract class PresenceClient`：`Future<PresenceClaimResult> claim()`、`Future<void> release()`、`Future<void> detach()`、`bool get isClaimed`、`Future<PresenceSendResult> sendDanmaku(String content)`、`Future<PresenceSendResult> sendAction(String action)`。
  - 网关新增：`Future<PresenceSendResult> sendDanmakuAsHolder({required String tabId, required String content})`、`Future<PresenceSendResult> sendActionAsHolder({required String tabId, required String action})`，均经 `_serialized`。
  - 控制器新增测试接缝：`@visibleForTesting void debugBindPresenceClient(PresenceClient client)`。
- Consumes: 既有 `DouyinPresenceTab`、`PresenceArbiter`、`GuardServerService.sendDanmaku/sendAction/reregister`、`DanmakuSendResult`。

- [ ] **Step 1: 新建 presence_client.dart（接口与结果类型）**

```dart
/// 控制器对抖音 presence 的唯一依赖面：主引擎内由 LocalPresenceClient
/// 直接函数调用实现，子引擎由 IPC proxy 实现，控制器调用点无分支。
library;

/// claim 失败原因。ipcFailed 仅子端本地产生（invoke 抛错/主窗无响应），
/// 主端永远不会回它；其余四值由主引擎网关产生、经 IPC 下行。
enum PresenceFailureReason {
  notLoggedIn,
  notConfigured,
  detailFailed,
  enterFailed,
  ipcFailed,
}

/// claim 结果：granted=true 时 reason 为 null；失败必带 reason。
class PresenceClaimResult {
  const PresenceClaimResult._(this.granted, this.reason);

  const PresenceClaimResult.granted() : this._(true, null);

  const PresenceClaimResult.failure({required PresenceFailureReason reason})
      : this._(false, reason);

  final bool granted;
  final PresenceFailureReason? reason;
}

/// pr_guard_send / 网关写动作回执码。
const String kPresenceCodeNotHolder = 'not_holder';
const String kPresenceCodeNotLogin = 'not_login';

/// 弹幕/互动写动作结果。not_holder 表示本标签已不是仲裁持有者，
/// 控制器据此让位给一次重新 claim + 重发。
class PresenceSendResult {
  const PresenceSendResult({
    required this.success,
    this.code,
    this.message,
  });

  final bool success;
  final String? code;
  final String? message;

  static const PresenceSendResult notHolder = PresenceSendResult(
    success: false,
    code: kPresenceCodeNotHolder,
  );
}

abstract class PresenceClient {
  Future<PresenceClaimResult> claim();
  Future<void> release();
  Future<void> detach();

  /// 本标签当前是否仍在仲裁意图栈中（承接旧 gateway.hasClaim 判定）。
  bool get isClaimed;

  Future<PresenceSendResult> sendDanmaku(String content);
  Future<PresenceSendResult> sendAction(String action);
}
```

- [ ] **Step 2: 从 presence_claimant.dart 删除 PresenceClaimResult**

把 `presence_claimant.dart` 第 44–56 行整段（`/// claim 结果。...` 注释 + `class PresenceClaimResult {...}`）删除；该文件只保留 `import 'package:simple_live_core/simple_live_core.dart';` 与 `abstract class DouyinPresenceTab`（第 1–42 行不动）。

- [ ] **Step 3: LocalPresenceClient 实现完整接口**

整文件替换 `local_presence_client.dart`：

```dart
import 'douyin_presence_gateway.dart';
import 'presence_client.dart';
import 'presence_claimant.dart';

/// 主引擎内的控制器侧薄代理：直接函数调用。
/// 子引擎场景替换为 IPC 实现，控制器侧调用点不变。
class LocalPresenceClient implements PresenceClient {
  LocalPresenceClient(this._gateway, this._tab);

  final DouyinPresenceGateway _gateway;
  final DouyinPresenceTab _tab;

  @override
  Future<PresenceClaimResult> claim() => _gateway.claim(_tab);

  @override
  Future<void> release() => _gateway.release(_tab.tabId);

  @override
  Future<void> detach() => _gateway.detach(_tab.tabId);

  @override
  bool get isClaimed => _gateway.hasClaim(_tab.tabId);

  @override
  Future<PresenceSendResult> sendDanmaku(String content) =>
      _gateway.sendDanmakuAsHolder(tabId: _tab.tabId, content: content);

  @override
  Future<PresenceSendResult> sendAction(String action) =>
      _gateway.sendActionAsHolder(tabId: _tab.tabId, action: action);
}
```

- [ ] **Step 4: 网关迁移 PresenceClaimResult 引用并加两个写动作方法**

`douyin_presence_gateway.dart`：

(a) import 区把 `import 'presence_claimant.dart';` 保留（仍用 DouyinPresenceTab），新增一行：

```dart
import 'presence_client.dart';
```

（`PresenceClaimResult`/`PresenceFailureReason` 改由 presence_client.dart 提供。）

(b) `_claim` 中第 93 行

```dart
      return PresenceClaimResult.failure(detailFailed: result.detailFailed);
```

改为

```dart
      return PresenceClaimResult.failure(
        reason: result.detailFailed
            ? PresenceFailureReason.detailFailed
            : PresenceFailureReason.enterFailed,
      );
```

（本任务暂保留 `_performEnter` 的 `({outcome, detailFailed})` 返回形态；reason 四细分在 Task 2。）

(c) 在 `batchRelease`/`_batchRelease` 之后、`_applyFallback` 之前（约第 206 行处）插入两个写动作方法。它们与 claim/release 共用 `_serialized`，故发送瞬间的 holder 切换不会把动作打到后一房间：

```dart
  // —— 写动作进入同一串行域（spec §6.5，M3 记账 #2）——

  Future<PresenceSendResult> sendDanmakuAsHolder({
    required String tabId,
    required String content,
  }) =>
      _serialized(() => _sendDanmakuAsHolder(tabId, content));

  Future<PresenceSendResult> sendActionAsHolder({
    required String tabId,
    required String action,
  }) =>
      _serialized(() => _sendActionAsHolder(tabId, action));

  /// 非 holder / 不在 _ready：零 HTTP 直接 not_holder；
  /// accountId 缺失：not_login。404 重注册一次（与控制器旧策略一致）。
  Future<PresenceSendResult> _sendDanmakuAsHolder(
    String tabId,
    String content,
  ) async {
    final tab = _tabs[tabId];
    if (tab == null ||
        arbiter.holder != tabId ||
        !_ready.contains(tabId)) {
      return PresenceSendResult.notHolder;
    }
    final accountId = _accountIds[tabId];
    if (accountId == null) {
      return const PresenceSendResult(
        success: false,
        code: kPresenceCodeNotLogin,
      );
    }
    try {
      Future<Map<String, dynamic>> once(String id,
          {bool retried = false}) async {
        try {
          return await _guard.sendDanmaku(
            platform: Constant.kDouyin,
            accountId: id,
            roomId: tab.guardRoomId,
            webRid: tab.guardWebRid,
            content: content,
            extra: tab.guardExtraArgs(),
          );
        } on DioException catch (e) {
          if (e.response?.statusCode == 404 && !retried) {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null) {
              _accountIds[tabId] = newId;
              return once(newId, retried: true);
            }
          }
          rethrow;
        }
      }

      final data = await once(accountId);
      return PresenceSendResult(
        success: data['success'] == true,
        code: data['platformCode']?.toString(),
        message: data['message']?.toString(),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = body is Map ? body['message'] : null;
      return PresenceSendResult(
        success: false,
        message: msg is String && msg.isNotEmpty ? msg : '网络请求失败',
      );
    } catch (e) {
      Log.logPrint('presence: holder 弹幕发送失败: $e');
      return const PresenceSendResult(success: false, message: '网络请求失败');
    }
  }

  /// 互动动作（like/fans_badge/join_club/light_up）。guard.sendAction
  /// 不带 platform/extra（与 sendDanmaku 区别，勿补参数）。
  Future<PresenceSendResult> _sendActionAsHolder(
    String tabId,
    String action,
  ) async {
    final tab = _tabs[tabId];
    if (tab == null ||
        arbiter.holder != tabId ||
        !_ready.contains(tabId)) {
      return PresenceSendResult.notHolder;
    }
    final accountId = _accountIds[tabId];
    if (accountId == null) {
      return const PresenceSendResult(
        success: false,
        code: kPresenceCodeNotLogin,
      );
    }
    try {
      Future<Map<String, dynamic>> once(String id,
          {bool retried = false}) async {
        try {
          return await _guard.sendAction(
            accountId: id,
            roomId: tab.guardRoomId,
            webRid: tab.guardWebRid,
            action: action,
          );
        } on DioException catch (e) {
          if (e.response?.statusCode == 404 && !retried) {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null) {
              _accountIds[tabId] = newId;
              return once(newId, retried: true);
            }
          }
          rethrow;
        }
      }

      final data = await once(accountId);
      return PresenceSendResult(
        success: data['success'] == true,
        code: data['platformCode']?.toString(),
        message: data['message']?.toString(),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = body is Map ? body['message'] : null;
      return PresenceSendResult(
        success: false,
        message: msg is String && msg.isNotEmpty ? msg : '网络请求失败',
      );
    } catch (e) {
      Log.logPrint('presence: holder 互动动作失败: $e');
      return const PresenceSendResult(success: false, message: '操作失败');
    }
  }

  /// 测试接缝：构造 holder+ready 但 accountId 缺失的 not_login 分支
  /// （生产中 ready 与 accountId 同置，该分支为防御性不可达，靠接缝验证）。
  @visibleForTesting
  void debugDropAccountId(String tabId) => _accountIds.remove(tabId);
```

- [ ] **Step 5: 先写/改网关写动作测试（红）**

在 `test/douyin_presence_gateway_test.dart`：

(a) import 增加（第 7–9 行那块）：

```dart
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
```

(b) 给 `FakeGuard` 增加发送记录与一次性 404 字段（类内，与 `enters/exits` 同级）：

```dart
  final sentDanmaku = <String>[];
  final sentActions = <String>[];
  bool sendDanmakuThrow404Once = false;

  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    if (sendDanmakuThrow404Once) {
      sendDanmakuThrow404Once = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/api/send'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/send'),
          statusCode: 404,
        ),
      );
    }
    sentDanmaku.add(content);
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async {
    sentActions.add(action);
    return {'success': true};
  }
```

并把既有两处 `detailFailed` 断言迁移到新枚举（用 `grep -n "\.detailFailed" test/douyin_presence_gateway_test.dart` 定位，恰好两处）：

- `FakeTab(detailThrows: true)` 详情抛错用例：`expect(r.detailFailed, isTrue);` → `expect(r.reason, PresenceFailureReason.detailFailed);`
- `detailGuardUnconfigured = true`（FakeGuard.configured=false）用例：`expect(r.detailFailed, isFalse);` → `expect(r.reason, PresenceFailureReason.enterFailed);`（本任务临时态：Task 2 细分 reason 后此用例改为 `PresenceFailureReason.notConfigured`）。

(c) 文件末尾 `}`（main 收尾，第 741 行 group 之后、顶层 `}` 之前）新增 group：

```dart
  group('holder 写动作串行域', () {
    test('holder 发弹幕：走 guard.sendDanmaku，带 platform=douyin 与 extra',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'hello');

      expect(r.success, isTrue);
      expect(guard.sentDanmaku, ['hello']);
      gw.stopHeartbeatForTesting();
    });

    test('holder 点赞：走 guard.sendAction（无 platform 参数）', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendActionAsHolder(tabId: 'A', action: 'like');

      expect(r.success, isTrue);
      expect(guard.sentActions, ['like']);
      gw.stopHeartbeatForTesting();
    });

    test('非 holder：not_holder 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b); // B 持有，A 让位
      await Future<void>.value();

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'x');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotHolder);
      expect(guard.sentDanmaku, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('未知 tab：not_holder 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);

      final r = await gw.sendActionAsHolder(tabId: 'ZZ', action: 'like');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotHolder);
      expect(guard.sentActions, isEmpty);
    });

    test('holder+ready 但 accountId 缺失：not_login 且零 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      gw.debugDropAccountId('A');

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'x');

      expect(r.success, isFalse);
      expect(r.code, kPresenceCodeNotLogin);
      expect(guard.sentDanmaku, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('发弹幕 404：reregister 后重试一次成功', () async {
      final guard = FakeGuard()..sendDanmakuThrow404Once = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final r = await gw.sendDanmakuAsHolder(tabId: 'A', content: 'hi');

      expect(r.success, isTrue);
      expect(guard.reregisters, [Constant.kDouyin]);
      expect(guard.sentDanmaku, ['hi']);
      gw.stopHeartbeatForTesting();
    });
  });
```

- [ ] **Step 6: 跑网关测试，确认新组绿、迁移断言绿**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/douyin_presence_gateway_test.dart`
Expected: 全绿（含 6 个新例）。此时控制器尚未改，整仓 analyze 会因控制器仍用旧 `LocalPresenceClient?` 类型——那是合法的（接口实现赋值兼容），但 `result.detailFailed` 与 `_presenceClient` 发送路径在 Step 8 一起改。

- [ ] **Step 7: 控制器接口换型 + claim 失败文案映射**

`live_room_controller.dart`：

(a) import（第 19–21 行区域）新增：

```dart
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
```

（`douyin_presence_gateway.dart`、`local_presence_client.dart`、`presence_claimant.dart` 三个 import 保留。）

(b) 第 164 行字段换型：

```dart
  PresenceClient? _presenceClient;
```

（第 165 行 `DouyinPresenceTab? _presenceTab;` 不动。）

(c) 第 481 行方法签名换型，并把失败文案改成 reason 全量映射：

```dart
  Future<bool> _doEnterViaGateway(PresenceClient client) async {
    presence.value = RoomPresence.entering;
    final result = await client.claim();
    if (result.granted) {
      // applyAccountEnter 可能在弹幕重连处抛错，而网关已置 holder+ready，
      // 后续 claim 短路不再 apply：账号态以服务端/心跳为准，此处必须落
      // account，否则控制器永久停在 entering。
      presence.value = RoomPresence.account;
      return true;
    }
    presence.value = RoomPresence.guest;
    SmartDialog.showToast(presenceFailureText(result.reason));
    return false;
  }

  /// claim/IPC 失败原因 → toast 文案（spec §5.1 逐字）。
  /// 主窗本地只会见到 detailFailed/enterFailed；其余为子窗 IPC 路径。
  String presenceFailureText(PresenceFailureReason? reason) {
    switch (reason) {
      case PresenceFailureReason.notLoggedIn:
        return '主窗口未登录抖音，请先在主窗口登录';
      case PresenceFailureReason.notConfigured:
        return '主窗口未配置弹幕签名服务，请在主窗口完成配置';
      case PresenceFailureReason.detailFailed:
        return '无法以账号身份读取该房间（可能被主播限制）';
      case PresenceFailureReason.enterFailed:
        return '进入直播间失败，已保持游客观看';
      case PresenceFailureReason.ipcFailed:
        return '主窗口服务无响应，请重试';
      case null:
        return '进入直播间失败，已保持游客观看';
    }
  }
```

(d) `_leaveDouyinPresence`（第 678–696 行）client 分支去掉对具体网关的耦合，改用接口：

```dart
    final client = _presenceClient;
    if (client != null) {
      final inStack = client.isClaimed;
      if (unconditional ||
          presence.value == RoomPresence.account ||
          inStack) {
        await client.release();
      }
      return;
    }
```

（删除原第 681–682 行 `final gateway = _resolveGateway(); final inStack = gateway?.hasClaim(tabId!) ?? false;`。`_resolveGateway()` 仍被 onInit 绑定使用，不删。）

(e) 新增测试接缝（放在 `bindPresenceGateway` 之后，约第 190 行后）：

```dart
  /// 测试用：注入假 PresenceClient 验证 not_holder 重发等控制器逻辑。
  @visibleForTesting
  void debugBindPresenceClient(PresenceClient client) {
    _presenceClient = client;
  }
```

- [ ] **Step 8: 控制器抖音发送 / action 改道 client（含 not_holder 一次重试）**

(a) `sendDanmaku` 第 712–769 行 try 块内，把

```dart
      DanmakuSendResult result;
      final guard = GuardServerService.instance;

      String? accountId;
      if (guard.configured && _guardPlatforms.contains(site.id)) {
```

起整段"accountId 直连"分支改造为三路。将第 714 行 `DanmakuSendResult result;` 保留，在其前取一次 client，并在 `String? accountId;` 之前插入抖音 presence 分流。目标结构（第 713–769 行整体替换 try 内到 `result = await liveDanmaku.sendMessage(content);` 为止）：

```dart
      DanmakuSendResult result;
      final presenceClient = _presenceClient;
      final guard = GuardServerService.instance;

      if (site.id == Constant.kDouyin && presenceClient != null) {
        // 主窗标签 / 子窗标签抖音发送统一走 presence 串行域，不再直连
        // GuardServerService、不在控制器起心跳（消除发送瞬间 holder 切换）。
        result = await _sendDanmakuViaPresence(presenceClient, content);
      } else {
        String? accountId;
        if (guard.configured && _guardPlatforms.contains(site.id)) {
          // 发送时按需注册：未注册则用本地保存的登录 cookie 自动注册
          accountId = await guard.ensureAccount(site.id);
        }

        if (accountId != null) {
          Future<DanmakuSendResult> sendOnce(String id,
              {bool retried = false}) async {
            try {
              final data = await guard.sendDanmaku(
                platform: site.id,
                accountId: id,
                roomId: _guardRoomId,
                webRid: _guardWebRid,
                content: content,
                extra: _guardExtraArgs(),
              );
              return DanmakuSendResult(
                success: data["success"] == true,
                errorCode: data["platformCode"] != null
                    ? data["platformCode"].toString()
                    : "guard",
                errorMessage: data["message"]?.toString() ?? "",
              );
            } on DioException catch (e) {
              if (e.response?.statusCode == 404 && !retried) {
                // 服务端会话丢失（如容器重启）：accountId 由 cookie 哈希决定，
                // 重新注册得到的 ID 与原 ID 相同，故不能比较 ID，注册成功即重试一次
                final newId = await guard.reregister(site.id);
                if (newId != null) {
                  return sendOnce(newId, retried: true);
                }
              }
              final data = e.response?.data;
              final msg = data is Map ? data["message"] : null;
              return DanmakuSendResult(
                success: false,
                errorCode: "guard",
                errorMessage:
                    msg is String && msg.isNotEmpty ? msg : "网络请求失败",
              );
            }
          }

          result = await sendOnce(accountId);
          if (result.success && _presenceClient == null) {
            // 网关模式下唯一心跳由网关维护；仅 Android / bili/huya 直连路径
            // 才在控制器起 Timer。
            _startGuardHeartbeat(accountId);
          }
        } else {
          result = await liveDanmaku.sendMessage(content);
        }
      }
```

紧随 `sendDanmaku` 方法之后新增 presence 发送辅助（含 not_holder 重claim重发一次）：

```dart
  /// 抖音 presence 通道发送：not_holder（持有者在他端切换/挂起）时
  /// 先强制回 guest 再重新 claim，重发**一次**；仍失败由文案层提示。
  Future<DanmakuSendResult> _sendDanmakuViaPresence(
    PresenceClient client,
    String content,
  ) async {
    var r = await client.sendDanmaku(content);
    if (!r.success && r.code == kPresenceCodeNotHolder) {
      presence.value = RoomPresence.guest;
      if (await ensureAccountPresence()) {
        r = await client.sendDanmaku(content);
      }
    }
    return DanmakuSendResult(
      success: r.success,
      errorCode: r.success ? '' : (r.code ?? 'guard'),
      errorMessage: r.message ?? '',
    );
  }
```

(b) `_sendGuardAction`（第 840–900 行）：在 `sendingAction.value = true;` 之后、`var accountId = await guard.ensureAccount(site.id);`（第 850 行）之前插入抖音 presence 分流并提前返回：

```dart
    sendingAction.value = true;
    try {
      final presenceClient = _presenceClient;
      if (site.id == Constant.kDouyin && presenceClient != null) {
        await _sendActionViaPresence(presenceClient, action);
        return;
      }
      var accountId = await guard.ensureAccount(site.id);
```

（之后既有直连代码原样保留，注意原第 847 行 `final guard = GuardServerService.instance;` 已在 try 之外声明，保持不动。）

新增辅助（放在 `_sendGuardAction` 之后）：

```dart
  /// 抖音 presence 通道互动动作 + not_holder 一次重claim重发。
  Future<void> _sendActionViaPresence(
    PresenceClient client,
    String action,
  ) async {
    var r = await client.sendAction(action);
    if (!r.success && r.code == kPresenceCodeNotHolder) {
      presence.value = RoomPresence.guest;
      if (await ensureAccountPresence()) {
        r = await client.sendAction(action);
      }
    }
    if (r.success) {
      _applyGuardActionSuccessFlags(action);
    } else {
      SmartDialog.showToast(
        r.message ??
            (r.code == kPresenceCodeNotHolder ? '登录状态已切换，请重试' : '操作失败'),
      );
    }
  }

  void _applyGuardActionSuccessFlags(String action) {
    if (action == 'join_club') {
      guardJoined.value = true;
      guardBadgeActive.value = true;
    }
    if (action == 'light_up') guardBadgeActive.value = true;
  }
```

并把直连路径第 878–882 行成功标志改为调用同一 helper（保持两路径一致）：

```dart
        _applyGuardActionSuccessFlags(action);
        // 主动操作已在服务端抢占房间，恢复本端心跳保活
        if (_presenceClient == null) {
          _startGuardHeartbeat(accountId);
        }
```

(c) `danmakuErrorText`（静态，第 1266 行起）在 `not_login` 分支之后插入 not_holder 分支：

```dart
    if (code == kPresenceCodeNotHolder) {
      return "登录状态已切换，请重试";
    }
```

- [ ] **Step 9: 控制器/文案测试**

(a) `test/send_danmaku_error_test.dart` 的 `group("danmakuErrorText")` 内新增一例：

```dart
    test("抖音 not_holder（登录态切换）", () {
      expect(
        LiveRoomController.danmakuErrorText("douyin", result("not_holder")),
        "登录状态已切换，请重试",
      );
    });
```

（`result(...)` 辅助已在该文件顶部，errorCode 即传入串。）

(b) `test/presence_gateway_controller_test.dart`：给该文件的 `FakeGuard`（第 89 行，configured=true、ensureAccount→'acct1'）补两个发送字段与 override（纯成功返回、不抛错，故**不需要** import dio），以便网关标签发送不落真实 Dio：

```dart
  final sentDanmaku = <String>[];
  final sentActions = <String>[];

  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    sentDanmaku.add(content);
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async {
    sentActions.add(action);
    return {'success': true};
  }
```

`FakeDanmaku`（第 14 行）加发送计数（其余 start/stop 不动）：

```dart
  int sendMessageCount = 0;

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    sendMessageCount++;
    return DanmakuSendResult(success: true);
  }
```

在 `testWidgets('A 进入后 B 进入...')` 之后、`main()` 内新增一例。此用例的控制器经 `makeController` 已绑定**真实** `LocalPresenceClient`（不是假 client），发送应经网关到 FakeGuard；`sendDanmaku`/`_sendGuardAction` 方法体内会无条件取 `GuardServerService.instance`，故必须注册（与 live_room_presence_test 一致）：

```dart
  testWidgets('主窗标签抖音发送/点赞：经 PresenceClient 走网关，不直连本地弹幕',
      (tester) async {
    final gateway = DouyinPresenceGateway(guard);
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<GuardServerService>(guard);
    Get.put<DouyinAccountService>(FakeDouyinAccount());
    final a = makeController(tabId: 'tabA', site: siteA, gateway: gateway);

    await a.enterAsAccount();
    await tester.pump();
    await a.sendDanmaku('hello');
    await tester.pump();
    await a.like();
    await tester.pump();

    expect(guard.sentDanmaku, ['hello']);
    expect(guard.sentActions, ['like']);
    expect(siteA.danmaku.sendMessageCount, 0,
        reason: '抖音弹幕必须走网关串行域，不落本地弹幕 sendMessage');
    gateway.stopHeartbeatForTesting();
  });
```

(c) 新建 `test/presence_client_reroute_test.dart`，用假 PresenceClient 验证控制器 not_holder 一次重claim重发。夹具照 `live_room_presence_test.dart`：**不调用控制器 onInit**（构造器不碰 Get，已由该文件 bootstrap 先构造、后 put service 证明），故无需 DBService/AppSettings/播放器；只在调用前 put 两个发送路径会取的 service。假 client 的 `claim` 直接 granted，控制器不跑网关那套 apply/弹幕/HTTP，不起任何 Timer：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeDanmaku extends LiveDanmaku {
  @override
  Future<void> start(dynamic args) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<DanmakuSendResult> sendMessage(String message) async =>
      DanmakuSendResult(success: true);
}

class _Site extends DouyinSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();
  @override
  LiveDanmaku getDanmaku() => danmaku;
  LiveRoomDetail guestDetail() => LiveRoomDetail(
        roomId: '111',
        title: 't',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 1,
        status: true,
        url: 'https://live.douyin.com/111',
        danmakuData: const DouyinDanmakuArgs(
          webRid: '111',
          roomId: 'room_111',
          userId: 'uid',
          cookie: 'ttwid=guest',
        ),
      );
  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async =>
      guestDetail();
}

class _Guard extends GuardServerService {
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  bool get configured => false;
}

class _Account extends DouyinAccountService {
  final _logined = true.obs;
  @override
  RxBool get logined => _logined;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakeClient implements PresenceClient {
  int claims = 0;
  int danmakuSends = 0;
  bool firstSendNotHolder = true;
  @override
  bool isClaimed = true;
  @override
  Future<PresenceClaimResult> claim() async {
    claims++;
    return const PresenceClaimResult.granted();
  }
  @override
  Future<PresenceSendResult> sendDanmaku(String content) async {
    danmakuSends++;
    if (firstSendNotHolder) {
      firstSendNotHolder = false;
      return PresenceSendResult.notHolder;
    }
    return const PresenceSendResult(success: true);
  }
  @override
  Future<PresenceSendResult> sendAction(String action) async =>
      const PresenceSendResult(success: true);
  @override
  Future<void> release() async {}
  @override
  Future<void> detach() async {}
}

void main() {
  tearDown(() => Get.reset());

  testWidgets('抖音发送遇 not_holder：强制回 guest → 重新 claim → 重发一次',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<GuardServerService>(_Guard());
    Get.put<DouyinAccountService>(_Account());

    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: 'tabA',
    );
    c.detail.value = site.guestDetail();
    final client = _FakeClient();
    c.debugBindPresenceClient(client);

    await c.sendDanmaku('hello');
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    // 首次 ensure（进入）claim 一次；not_holder 后强制回 guest 重进再 claim 一次
    expect(client.claims, 2);
    expect(client.danmakuSends, 2, reason: 'not_holder 后只重发一次');
    expect(c.presence.value, RoomPresence.account);
  });
}
```

- [ ] **Step 10: 全量门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿（约 234 + 本任务新增 7 例：网关 6 + 文案 1；控制器两例在既有文件内）。
Expected: 无 `PresenceClaimResult.detailFailed` 残留引用（grep 自查）；无 tabId 路径行为变化（live_room_presence_test 全绿：其控制器无 tabId、client=null，走直连分支）。

- [ ] **Step 11: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_client.dart \
  simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart \
  simple_live_app/lib/app/multiwindow/presence/local_presence_client.dart \
  simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart \
  simple_live_app/lib/modules/live_room/live_room_controller.dart \
  simple_live_app/test/douyin_presence_gateway_test.dart \
  simple_live_app/test/presence_gateway_controller_test.dart \
  simple_live_app/test/send_danmaku_error_test.dart \
  simple_live_app/test/presence_client_reroute_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 抽出 PresenceClient 接口并让抖音写动作进入网关串行域

PresenceClaimResult 迁移为 reason 枚举；新增 PresenceSendResult 与
not_holder/not_login 码；LocalPresenceClient 实现完整接口；网关新增
sendDanmaku/sendActionAsHolder 经 _serialized 执行；控制器抖音发送与
互动动作在 presence client 存在时改道，not_holder 自动重 claim 重发一次。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 网关健壮性 #3–#7、claim reason 细分、登录态注入、心跳 reregister 失败收口

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（仅 `applySuspended` 签名）
- Modify: `simple_live_app/lib/routes/app_pages.dart`
- Test: `simple_live_app/test/douyin_presence_gateway_test.dart`
- Test: `simple_live_app/test/presence_gateway_controller_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `PresenceFailureReason`、`PresenceClaimResult.failure(reason:)`；控制器 `presenceFailureText`（Task 1 已落，本任务无需再改控制器文案）。
- Produces（后续任务消费，命名锁定）：
  - 构造新参：`DouyinPresenceGateway(GuardServerService guard, {Duration heartbeatInterval, bool Function()? isAccountLoggedIn})`；`isAccountLoggedIn` 为 null 时按"已登录"处理（保既有测试/子引擎外默认）。
  - `_performEnter` 返回 `({_EnterOutcome? outcome, PresenceFailureReason? reason})`。
  - 端口 `DouyinPresenceTab.applySuspended()` 由 `void` 改 `Future<void>`（RemotePresenceTask in Task 7 需要异步 IPC）。

判定顺序（spec §5.1，严格按此）：账号详情抛错 → `detailFailed`；`isAccountLoggedIn()` 为 false → `notLoggedIn`；`!_guard.configured` → `notConfigured`；`ensureAccount` 返回 null / enterRoom（含 404 重注册仍失败）/ 任何进场异常 → `enterFailed`。

- [ ] **Step 1: 端口 applySuspended 改异步**

`presence_claimant.dart` 第 41 行：

```dart
  Future<void> applySuspended();
```

（同步更新其上方注释为"停止本标签账号态语义……"即可，无其他改动。）

- [ ] **Step 2: 控制器 applySuspended 改 async（仅签名+方法体）**

`live_room_controller.dart` 第 600–604 行整段替换：

```dart
  /// 外部端抢占：不切弹幕、不抢回；置 guest 使后续写动作走 claim 重进
  Future<void> applySuspended() async {
    // 不切弹幕、不抢回；使在途的让位/进场续体失效
    ++_presenceGeneration;
    presence.value = RoomPresence.guest;
  }
```

同文件文件末尾 `_ControllerPresenceTab`（约第 2492–2493 行）的 override 必须同步改型，否则 invalid_override：

```dart
  @override
  Future<void> applySuspended() => _c.applySuspended();
```

- [ ] **Step 3: 网关类声明、import、构造注入**

`douyin_presence_gateway.dart`：

(a) import 区新增（`presence_claimant.dart` 旁）：

```dart
import 'package:get/get.dart';
```

并新增 presence_client（Task 1 已加则跳过）：

```dart
import 'presence_client.dart';
```

(b) 第 22–29 行类声明与构造改为：

```dart
class DouyinPresenceGateway extends GetxService {
  DouyinPresenceGateway(
    this._guard, {
    this.heartbeatInterval = const Duration(seconds: 20),
    bool Function()? isAccountLoggedIn,
  }) : _isAccountLoggedIn = isAccountLoggedIn;

  final GuardServerService _guard;
  final Duration heartbeatInterval;
  final bool Function()? _isAccountLoggedIn;
  final PresenceArbiter arbiter = PresenceArbiter();
```

- [ ] **Step 4: _performEnter 返回 reason（整方法替换第 261–316 行）**

```dart
  /// 账号进场 HTTP 序列：账号详情 → 登录态 → 配置 → ensureAccount →
  /// enterRoom（404 重注册一次）。失败 outcome 为 null，reason 给细分原因。
  Future<({_EnterOutcome? outcome, PresenceFailureReason? reason})>
      _performEnter(DouyinPresenceTab tab) async {
    final LiveRoomDetail detail;
    try {
      detail = await tab.fetchAccountDetail();
    } catch (e) {
      return (outcome: null, reason: PresenceFailureReason.detailFailed);
    }
    // 登录态门在配置门之前：未登录时不计"未配置"，文案指向主窗登录
    final loggedIn = _isAccountLoggedIn?.call() ?? true;
    if (!loggedIn) {
      return (outcome: null, reason: PresenceFailureReason.notLoggedIn);
    }
    if (!_guard.configured) {
      return (outcome: null, reason: PresenceFailureReason.notConfigured);
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return (outcome: null, reason: PresenceFailureReason.enterFailed);
      }
      Map<String, dynamic> status;
      try {
        status = await _guard.enterRoom(
          accountId: accountId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          rethrow;
        }
        // 服务端会话丢失：重新注册后再进一次
        final newId = await _guard.reregister(Constant.kDouyin);
        if (newId == null) {
          return (outcome: null, reason: PresenceFailureReason.enterFailed);
        }
        accountId = newId;
        status = await _guard.enterRoom(
          accountId: newId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      }
      return (
        outcome: _EnterOutcome(
          accountId: accountId,
          status: status,
          detail: detail,
        ),
        reason: null,
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return (outcome: null, reason: PresenceFailureReason.enterFailed);
    }
  }
```

- [ ] **Step 5: _claim 消费 reason + #7 让位条件**

(a) 第 93 行（Task 1 已改为 detailFailed 三元）整行替换为：

```dart
      return PresenceClaimResult.failure(
        reason: result.reason ?? PresenceFailureReason.enterFailed,
      );
```

(b) **#7**：第 122–124 行让位条件加 `!tab.isClosed`：

```dart
    if (previousHolder != null &&
        !selfWasHolder &&
        !tab.isClosed &&
        !previousHolder.isClosed) {
```

（`_applyFallback` 内调用 `_performEnter` 的失败分支第 216–219 行不使用 reason，保持只 log。）

- [ ] **Step 6: #4 _remove 在早退前取消持有者心跳**

`_remove` 第 146–160 行替换为：

```dart
  Future<void> _remove(String tabId, {required bool emitExit}) async {
    final tab = _tabs[tabId];
    final accountId = _accountIds[tabId];
    // 必须在 arbiter 摘栈前快照：detach 唯一持有者且无 fallback 时
    // transition 的 exits/enters 均为 null，会命中下方早退导致 Timer 残留（#4）
    final wasHolder = arbiter.holder == tabId;
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _accountIds.remove(tabId);
    _ready.remove(tabId);
    if (wasHolder) {
      _heartbeatTimer?.cancel();
    }
    if (transition == null) {
      return; // 未知 tab
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 非持有者仅出栈 / detach 唯一持有者无 fallback：心跳已在上方取消
    }
    _heartbeatTimer?.cancel();
```

其后第 162–169 行（exit/fallback）保持不动。

- [ ] **Step 7: #6 _exitRoom 空房间守卫**

第 244–245 行方法开头改为：

```dart
  Future<void> _exitRoom(DouyinPresenceTab tab, String? accountId) async {
    // SSR 骨架房抖音 args.roomId 为空：没有可退的服务端房间，不发 exit（#6）
    if (tab.guardRoomId.isEmpty) {
      return;
    }
    try {
```

- [ ] **Step 8: _suspend 收口 + #5 心跳非重入 + reregister 失败 suspended（替换第 318–378 行）**

新增字段（与 `_heartbeatTimer` 同区，约第 39 行后）：

```dart
  /// 心跳拍在途标志：heartbeat RTT 超过间隔时跳过重叠拍，杜绝并发续租（#5）
  bool _beatInFlight = false;
```

`_startHeartbeat` / beat / 测试钩子 / 生命周期整体替换为：

```dart
  /// 心跳失去 holder 资格或重注册失败的统一收口：cancel Timer、移出
  /// _ready、标 suspended、通知标签（best-effort）。inRoom!=true 与
  /// 404-reregister 失败共用此路径。
  Future<void> _suspend(DouyinPresenceTab tab) async {
    _heartbeatTimer?.cancel();
    _ready.remove(tab.tabId);
    arbiter.markSuspended(tab.tabId);
    try {
      await tab.applySuspended();
    } catch (e) {
      Log.logPrint('presence: applySuspended 失败: $e');
    }
  }

  void _startHeartbeat(DouyinPresenceTab tab, String accountId) {
    _heartbeatTimer?.cancel();

    Future<void> beat() async {
      // 上一拍仍在途（RTT > 间隔）：跳过本拍，不并发 heartbeat（#5）
      if (_beatInFlight) return;
      // 回调延迟期间 holder 可能已切换：非 holder 不再续租
      if (arbiter.holder != tab.tabId) {
        return;
      }
      _beatInFlight = true;
      try {
        final data = await _guard.heartbeat(
          accountId: accountId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
        if (arbiter.holder != tab.tabId) {
          return;
        }
        if (data['inRoom'] != true) {
          // 同账号在外部端进入别的房间：suspended 收口，不抢回
          await _suspend(tab);
          return;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          // 服务端会话丢失：reregister 一次。成功且仍为 holder → 同步
          // accountId 缓存并重挂心跳；失败/已不持有 → suspended 收口，
          // 不再让 Timer 空转（spec §6.3，替代 M3 只记日志的旧行为）。
          try {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null && arbiter.holder == tab.tabId) {
              _accountIds[tab.tabId] = newId;
              _startHeartbeat(tab, newId);
            } else {
              await _suspend(tab);
            }
          } catch (e2) {
            Log.logPrint('弹幕服务心跳重注册失败: $e2');
            await _suspend(tab);
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
      } catch (e) {
        // 响应体畸形等：只记日志，不让单个 beat 成为未处理 async 异常
        Log.logPrint('弹幕服务心跳异常: $e');
      } finally {
        _beatInFlight = false;
      }
    }

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => beat());
  }

  @visibleForTesting
  void stopHeartbeatForTesting() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  @override
  void onClose() {
    _heartbeatTimer?.cancel();
    super.onClose();
  }
}
```

即：**删除**旧的 `void dispose() {...}`（第 375–378 行），类尾以 `onClose` 收尾。确认全仓再无网关 dispose 调用：

Run: `grep -rn "\.dispose()" simple_live_app/test simple_live_app/lib | grep -i "gw\|gateway"`
Expected: 无 `gateway.dispose`/`gw.dispose`（presence_gateway_controller_test 的一处下一步改）。

- [ ] **Step 9: app_pages 注入登录态判定**

`app_pages.dart` import 区加：

```dart
import 'package:simple_live_app/services/douyin_account_service.dart';
```

第 80 行替换为：

```dart
        Get.put(
          DouyinPresenceGateway(
            GuardServerService.instance,
            isAccountLoggedIn: () => DouyinAccountService
                .instance.loginCookie
                .contains('sessionid'),
          ),
        );
```

- [ ] **Step 10: 测试夹具改造（FakeGuard / FakeTab）**

`test/douyin_presence_gateway_test.dart`：

(a) `FakeTab` 支持空 guardRoomId（#6），构造与 getter 改为：

```dart
class FakeTab implements DouyinPresenceTab {
  FakeTab(this.id, this.webRid, {this.cookie = 'sessionid=abc', String? roomId})
      : guardRoomIdOverride = roomId;

  final String id;
  final String webRid;
  final String cookie;
  final String? guardRoomIdOverride;
```

并把

```dart
  @override
  String get guardRoomId => 'room_$webRid';
```

改为

```dart
  @override
  String get guardRoomId => guardRoomIdOverride ?? 'room_$webRid';
```

`applySuspended` 改异步：

```dart
  @override
  Future<void> applySuspended() async {
    suspended++;
  }
```

(b) `FakeGuard` 增加测试钩子（字段区与现有 `enterThrowsOnce` 等同级）：

```dart
  /// 非 null 时 heartbeat 进入即等待（在 beats.add 之前），造 RTT>间隔
  Completer<void>? heartbeatEnterGate;

  bool reregisterReturnNull = false;
  bool enterAlways500 = false;
```

`reregister` 改为：

```dart
  @override
  Future<String?> reregister(String platform) async {
    reregisters.add(platform);
    if (reregisterReturnNull) return null;
    return 'acct2';
  }
```

`enterRoom` 在现有 `enterThrowsOnce` 404 块**之后**、`enters.add` 之前插入：

```dart
    if (enterAlways500) {
      throw DioException(
        requestOptions: RequestOptions(path: '/api/room/enter'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/room/enter'),
          statusCode: 500,
        ),
      );
    }
```

`heartbeat` 在 `thrown` 处理之后、`beats.add` 之前插入：

```dart
    final enterGate = heartbeatEnterGate;
    if (enterGate != null) {
      await enterGate.future;
    }
```

(c) 既有「guard 未配置」用例（约第 257–266 行）断言迁移：

```dart
      expect(r.reason, PresenceFailureReason.notConfigured);
```

（替换 Task 1 临时写的 `PresenceFailureReason.enterFailed`。）

- [ ] **Step 11: 新增健壮性 / reason 测试**

在 `test/douyin_presence_gateway_test.dart` 相应 group 内追加：

`claim 进场` group 末尾加两例：

```dart
    test('未登录：isAccountLoggedIn=false → reason=notLoggedIn，零账号 HTTP',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        isAccountLoggedIn: () => false,
      );
      final a = FakeTab('A', '111');
      final r = await gw.claim(a);
      expect(r.granted, isFalse);
      expect(r.reason, PresenceFailureReason.notLoggedIn);
      expect(guard.ensureAccounts, isEmpty);
      expect(guard.enters, isEmpty);
      expect(gw.holderTabId, isNull);
    });

    test('enterRoom 持续 500：reason=enterFailed', () async {
      final guard = FakeGuard()..enterAlways500 = true;
      final gw = DouyinPresenceGateway(guard);
      final r = await gw.claim(FakeTab('A', '111'));
      expect(r.granted, isFalse);
      expect(r.reason, PresenceFailureReason.enterFailed);
      expect(guard.enters, isEmpty);
      gw.stopHeartbeatForTesting();
    });
```

`唯一心跳（fakeAsync）` group 末尾加三例：

```dart
    test('#5 心跳 RTT 超间隔：重叠拍跳过，不并发 heartbeat', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final gate = Completer<void>();
        guard.heartbeatEnterGate = gate;

        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 100)); // 首拍卡在 gate
        async.elapse(const Duration(milliseconds: 100)); // 重叠拍必须跳过
        expect(guard.beats, isEmpty, reason: '在途拍未返回，不应有完成的 beat');

        gate.complete();
        async.flushMicrotasks();
        expect(guard.beats, ['acct1@room_111']);

        async.elapse(const Duration(milliseconds: 100)); // 下一拍正常
        expect(guard.beats.length, 2, reason: '无并发，仅两拍');
        guard.heartbeatEnterGate = null;
        gw.stopHeartbeatForTesting();
      });
    });

    test('心跳 404 且 reregister 失败：转 suspended、停心跳、通知标签', () {
      FakeAsync().run((async) {
        final guard = FakeGuard()
          ..heartbeatThrowOnce = DioException(
            requestOptions: RequestOptions(path: '/api/room/heartbeat'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/api/room/heartbeat'),
              statusCode: 404,
            ),
          )
          ..reregisterReturnNull = true;
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        async.flushMicrotasks();

        expect(gw.holderTabId, isNull);
        expect(a.suspended, 1);
        expect(guard.reregisters, [Constant.kDouyin]);
        final beats = guard.beats.length;
        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats.length, beats, reason: 'suspended 后心跳必须停止');
        gw.stopHeartbeatForTesting();
      });
    });

    test('#7 新 holder 进房在途被关：不 yield 旧 holder，由排队 release reenter',
        () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final b = FakeTab('B', '222');
        gw.claim(a);
        async.flushMicrotasks();

        final gate = Completer<void>();
        guard.enterGate = gate;
        gw.claim(b);
        async.flushMicrotasks(); // B 停在 enterRoom
        b.closed = true;
        gate.complete();
        async.flushMicrotasks();
        async.flushMicrotasks();
        expect(a.yields, 0, reason: '新 holder 已关闭，不得 yield 旧 holder');

        guard.enters.clear();
        gw.release('B');
        async.flushMicrotasks();
        expect(a.reenteredCalls, contains(true),
            reason: '排队 release 触发 fallback 一次性重新 enter A');
        expect(a.yields, 0);
        gw.stopHeartbeatForTesting();
      });
    });
```

`release / detach` group 加 #4、#6 两例：

```dart
    test('#4 detach 唯一持有者无 fallback：心跳 Timer 取消，无残留拍', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        expect(guard.beats.length, 1);

        gw.detach('A'); // 唯一持有者、无 fallback：exits/enters 双 null
        async.flushMicrotasks();
        expect(gw.holderTabId, isNull);
        expect(guard.exits, isEmpty, reason: 'detach 不发 exit');

        final beats = guard.beats.length;
        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats.length, beats, reason: 'Timer 必须已取消，无残留拍');
        gw.stopHeartbeatForTesting();
      });
    });

    test('#6 guardRoomId 为空：release holder 不发 exit', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '', roomId: '');
      await gw.claim(a);
      await gw.release('A');
      expect(guard.exits, isEmpty, reason: '空 roomId 骨架房不发 exit');
    });
```

- [ ] **Step 12: 控制器测试 dispose 调用迁移**

`test/presence_gateway_controller_test.dart` 第 243 行：

```dart
    addTearDown(gw2.stopHeartbeatForTesting);
```

（替换 `addTearDown(gw2.dispose);`。第 258 行的手动 stop 保留，重复调用幂等。）

- [ ] **Step 13: 全量门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增；特别确认无 `PresenceClaimResult.detailFailed`/`gw.dispose`/`void applySuspended` 残留（grep 三项应零命中）。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿（基线 + Task 1 + 本任务新增 7 例：notLoggedIn、enterFailed、#4、#5、#6、#7、心跳-suspended）。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功（app_pages 接线改动）。

- [ ] **Step 14: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart \
  simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart \
  simple_live_app/lib/modules/live_room/live_room_controller.dart \
  simple_live_app/lib/routes/app_pages.dart \
  simple_live_app/test/douyin_presence_gateway_test.dart \
  simple_live_app/test/presence_gateway_controller_test.dart
git commit -m "$(cat <<'EOF'
fix(presence): 收口网关健壮性 #3-#7 并细分 claim 失败原因

网关改 GetxService 以 onClose 收心跳；detach 唯一持有者早退前取消
Timer；心跳拍非重入；空 roomId 不发 exit；在途新 holder 被关不再
yield 旧 holder。claim 失败按 detail/未登录/未配置/进场失败细分
reason 并注入主窗登录态判定；心跳 404 重注册失败统一转 suspended。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: PresenceBatchReleaser 接口、TabStore 换型、批量菜单防抖 #8

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/presence_batch_releaser.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_store.dart`
- Test: `simple_live_app/test/tab_store_test.dart`

**Interfaces:**
- Consumes: Task 2 的 `DouyinPresenceGateway extends GetxService`；网关现有方法 `Future<void> batchRelease(Set<String> tabIds)`（douyin_presence_gateway.dart:175）。
- Produces（T10 消费，命名锁定）：
  - `abstract class PresenceBatchReleaser { Future<void> batchRelease(Set<String> tabIds); }`
  - `TabStore` 构造参数仍命名 `presenceGateway`，类型换为 `PresenceBatchReleaser?`；T10 的 `IpcPresenceCoordinator` implements 同一接口注入子引擎 TabStore。

- [ ] **Step 1: 写失败测试（#8 防抖）**

`test/tab_store_test.dart` 顶部 import 区加：

```dart
import 'dart:async';

import 'package:simple_live_app/app/multiwindow/presence/presence_batch_releaser.dart';
```

文件中 `FakeThenThrowRegistry` 类之后（main 外）加夹具：

```dart
class _BlockingReleaser implements PresenceBatchReleaser {
  int calls = 0;
  final Completer<void> entered = Completer<void>();
  final Completer<void> gate = Completer<void>();

  @override
  Future<void> batchRelease(Set<String> tabIds) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    await gate.future;
  }
}
```

`main()` 内末尾追加用例：

```dart
  test('#8 批量流程在途时再次批量操作直接 no-op，结束后恢复', () async {
    final releaser = _BlockingReleaser();
    final s = TabStore(registry: registry, presenceGateway: releaser);
    s.open(req('a', '1'));
    s.open(req('a', '2'));
    final first = s.closeAll();
    await releaser.entered.future; // 首批量卡在 batchRelease 在途

    // 在途期间：tabs 尚未清空（摘栈 await 之后才 unregister/clear）
    await s.closeAll();
    await s.closeOthers(s.tabs.first.tabId);
    await s.closeRight(s.tabs.first.tabId);
    expect(releaser.calls, 1, reason: '在途期间只允许一个批量摘栈');

    releaser.gate.complete();
    await first;
    expect(s.tabs, isEmpty);

    // 流程结束后批量能力恢复
    s.open(req('a', '9'));
    await s.closeAll();
    expect(releaser.calls, 2);
  });
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/tab_store_test.dart`
Expected: 编译失败——`PresenceBatchReleaser` 未定义、`presenceGateway` 参数类型不接受该夹具。

- [ ] **Step 2: 新建 PresenceBatchReleaser**

`lib/app/multiwindow/presence/presence_batch_releaser.dart` 全文：

```dart
/// 批量释放 presence 标签的最小依赖。
///
/// TabStore 只需要"批量摘栈"能力，不依赖 DouyinPresenceGateway 具体类：
/// 主引擎注入网关，子引擎注入 IPC presence coordinator（转发
/// pr_batch_release），两者实现同一接口。
abstract class PresenceBatchReleaser {
  Future<void> batchRelease(Set<String> tabIds);
}
```

- [ ] **Step 3: 网关 implements 接口**

`douyin_presence_gateway.dart` import 区加：

```dart
import 'presence_batch_releaser.dart';
```

类声明（Task 2 已改为 extends GetxService）加 implements：

```dart
class DouyinPresenceGateway extends GetxService
    implements PresenceBatchReleaser {
```

`batchRelease(Set<String> tabIds)` 方法体不动，签名已满足接口。

- [ ] **Step 4: TabStore 换型 + #8 防抖**

`tab_store.dart`：

(a) 第 6 行 import 替换：

```dart
import '../presence/presence_batch_releaser.dart';
```

（删除 `import '../presence/douyin_presence_gateway.dart';`）

(b) 第 22 行字段换型（构造参数名不变）：

```dart
  /// Windows 标签壳注入；null（单元测试 / 未来其他宿主）时行为与 M2 完全一致。
  /// 主引擎传 DouyinPresenceGateway，子引擎传 IpcPresenceCoordinator。
  final PresenceBatchReleaser? presenceGateway;
```

(c) 在 `final _uuid = const Uuid();`（第 24 行）下方加防抖状态与包装：

```dart
  /// 批量菜单防抖：closeOthers/closeRight/closeAll 任一在途时，其余批量
  /// 调用直接 no-op（终态幂等），杜绝快速两次批量操作的"刚 enter 即 exit"
  /// 抖动（spec §7 #8）。单标签 close() 不受此门控。
  bool _batchClosing = false;

  Future<void> _batchGuarded(Future<void> Function() body) async {
    if (_batchClosing) return;
    _batchClosing = true;
    try {
      await body();
    } finally {
      _batchClosing = false;
    }
  }
```

(d) 三个批量方法改为"公开门控方法 + 私有实现"。第 107–123 行替换为：

```dart
  Future<void> closeOthers(String tabId) =>
      _batchGuarded(() => _closeOthers(tabId));

  Future<void> _closeOthers(String tabId) async {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final victims = tabs.where((t) => t.tabId != tabId).toList();
    // 必须先摘栈再销毁控制器：否则 holder 关闭会对同样即将销毁的次新标签
    // 连环发起 enter/exit；幸存者由网关一次性接管
    await presenceGateway?.batchRelease(
      victims.map((t) => t.tabId).toSet(),
    );
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    activeTabId.value = tabId;
  }
```

第 125–141 行替换为：

```dart
  Future<void> closeRight(String tabId) =>
      _batchGuarded(() => _closeRight(tabId));

  Future<void> _closeRight(String tabId) async {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final victims = tabs.sublist(index + 1);
    await presenceGateway?.batchRelease(
      victims.map((t) => t.tabId).toSet(),
    );
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    if (!tabs.any((t) => t.tabId == activeTabId.value)) {
      activeTabId.value = tabId;
    }
  }
```

第 150–160 行替换为：

```dart
  Future<void> closeAll() => _batchGuarded(_closeAll);

  Future<void> _closeAll() async {
    final all = tabs.toList();
    await presenceGateway?.batchRelease(
      all.map((t) => t.tabId).toSet(),
    );
    for (final t in all) {
      registry.unregister(t.tabId);
    }
    tabs.clear();
    activeTabId.value = null;
  }
```

- [ ] **Step 5: 跑 TabStore 测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/tab_store_test.dart`
Expected：全绿（16 旧例 + #8 新例；两条"未知 tabId 抛 ArgumentError"用例不在批量在途态，仍抛）。

- [ ] **Step 6: 核对全部 TabStore 构造点类型兼容**

Run：`grep -rn "TabStore(" simple_live_app/lib simple_live_app/test --include="*.dart"`
Expected：每个构造点的 `presenceGateway:` 实参要么省略，要么是 `DouyinPresenceGateway`（is-a 接口，app_pages.dart）、`IpcPresenceCoordinator`（T10 才出现）或测试假实现；无具体类型反向引用残留。同时 `grep -rn "DouyinPresenceGateway" simple_live_app/lib/app/multiwindow/shell/` 应零命中（shell 层不再 import 具体网关）。

- [ ] **Step 7: 全量门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功（shell 主链路类型改动，跑一次）。

- [ ] **Step 8: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_batch_releaser.dart \
  simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart \
  simple_live_app/lib/app/multiwindow/shell/tab_store.dart \
  simple_live_app/test/tab_store_test.dart
git commit -m "$(cat <<'EOF'
refactor(presence): TabStore 依赖批量释放接口并加批量菜单防抖

新增 PresenceBatchReleaser 单方法接口，网关 implements 之，TabStore
不再耦合具体网关，为子引擎注入 IPC coordinator 铺路；closeOthers/
closeRight/closeAll 在批量流程在途时 no-op（#8），消除刚 enter 即
exit 的抖动。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: PresenceProtocol（pr_ 协议：常量、encode/decode、reason 映射、日志脱敏）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/presence_protocol.dart`
- Test: `simple_live_app/test/multiwindow/presence_protocol_test.dart`

**Interfaces:**
- Consumes: Task 1 的 `PresenceFailureReason`（5 值）、`PresenceSendResult`（含 `notHolder` 常量）。
- Produces（T7/T9 消费，命名锁定）：
  - 方法名常量：`mRegister='pr_register'`、`mClaim='pr_claim'`、`mRelease='pr_release'`、`mDetach='pr_detach'`、`mBatchRelease='pr_batch_release'`、`mGuardSend='pr_guard_send'`、`mApplyEnter='pr_apply_enter'`、`mApplyYield='pr_apply_yield'`、`mApplySuspended='pr_apply_suspended'`。
  - kind 常量：`kDanmaku='danmaku'`、`kAction='action'`；reason 线值：`rNotLoggedIn='not_logged_in'`、`rNotConfigured='not_configured'`、`rDetailFailed='detail_failed'`、`rEnterFailed='enter_failed'`。
  - 载荷类型（全部 const 友好、不可变字段）：`PresenceRegisterCall{windowId,tabId,siteId,roomId,shareUrl}`、`PresenceClaimCall{windowId,tabId,roomId,shareUrl,guardRoomId,guardWebRid,guardExtra:Map<String,Object?>}`、`PresenceReleaseCall{windowId,tabId}`（release/detach 共用）、`PresenceBatchReleaseCall{windowId,tabIds:List<String>}`、`PresenceGuardSendCall{windowId,tabId,kind,content?,action?}`、`PresenceApplyEnterCall{tabId,cookie,status:Map<String,Object?>,reentered:bool}`。
  - 编解码：每个出站 `encodeX(call) → Map<String,Object?>` 配一个 `decodeX(Object?) → call?`；另有 `encodeTabApply(String tabId)`/`decodeTabApply(Object?) → String?`（yield/suspended 共用）；`encodeClaimOk()`、`encodeClaimFailure(PresenceFailureReason)`、`decodeClaimResult(Object?) → ({bool ok, PresenceFailureReason? reason})?`；`encodeSendResult(PresenceSendResult)`、`decodeSendResult(Object?) → PresenceSendResult?`；`reasonToWire(PresenceFailureReason) → String?`（ipcFailed → null）、`reasonFromWire(String?) → PresenceFailureReason?`；`sanitizeForLog(String method, Object? args) → String`。
  - 校验铁律：任何字段缺失/错类型/空 id/坏 kind/danmaku 缺非空 content/action 缺非空 action → decode 返回 null；`guardRoomId`/`guardWebRid`/`cookie` 允许空串但必须是 String（空 guardRoomId 是 #6 骨架房的合法值）。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/presence_protocol_test.dart` 全文：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';

void main() {
  test('子→主：register/claim/release/batch/guardSend encode/decode 往返', () {
    final register = PresenceProtocol.encodeRegister(
      const PresenceRegisterCall(
        windowId: 'w1',
        tabId: 't1',
        siteId: 'douyin',
        roomId: '711',
        shareUrl: '',
      ),
    );
    final dRegister = PresenceProtocol.decodeRegister(register)!;
    expect(dRegister.windowId, 'w1');
    expect(dRegister.tabId, 't1');
    expect(dRegister.siteId, 'douyin');
    expect(dRegister.roomId, '711');
    expect(dRegister.shareUrl, '');
    expect(PresenceProtocol.encodeRegister(dRegister), register);

    final claim = PresenceProtocol.encodeClaim(
      const PresenceClaimCall(
        windowId: 'w1',
        tabId: 't1',
        roomId: '711',
        shareUrl: 'http://x/711',
        guardRoomId: '', // 空串合法（#6 SSR 骨架房）
        guardWebRid: 'g711',
        guardExtra: <String, Object?>{},
      ),
    );
    final dClaim = PresenceProtocol.decodeClaim(claim)!;
    expect(dClaim.guardRoomId, '');
    expect(dClaim.guardWebRid, 'g711');
    expect(dClaim.guardExtra, isEmpty);
    expect(PresenceProtocol.encodeClaim(dClaim), claim);

    final release = PresenceProtocol.encodeRelease(
      const PresenceReleaseCall(windowId: 'w1', tabId: 't1'),
    );
    final dRelease = PresenceProtocol.decodeRelease(release)!;
    expect(dRelease.windowId, 'w1');
    expect(dRelease.tabId, 't1');
    expect(PresenceProtocol.encodeRelease(dRelease), release);

    final batch = PresenceProtocol.encodeBatchRelease(
      const PresenceBatchReleaseCall(windowId: 'w1', tabIds: ['t1', 't2']),
    );
    final dBatch = PresenceProtocol.decodeBatchRelease(batch)!;
    expect(dBatch.tabIds, ['t1', 't2']);
    expect(PresenceProtocol.encodeBatchRelease(dBatch), batch);

    final danmaku = PresenceProtocol.encodeGuardSend(
      const PresenceGuardSendCall(
        windowId: 'w1',
        tabId: 't1',
        kind: PresenceProtocol.kDanmaku,
        content: '你好',
      ),
    );
    final dDanmaku = PresenceProtocol.decodeGuardSend(danmaku)!;
    expect(dDanmaku.kind, PresenceProtocol.kDanmaku);
    expect(dDanmaku.content, '你好');
    expect(dDanmaku.action, isNull);

    final action = PresenceProtocol.encodeGuardSend(
      const PresenceGuardSendCall(
        windowId: 'w1',
        tabId: 't1',
        kind: PresenceProtocol.kAction,
        action: 'like',
      ),
    );
    final dAction = PresenceProtocol.decodeGuardSend(action)!;
    expect(dAction.action, 'like');
    expect(dAction.content, isNull);
  });

  test('主→子 apply 与 claim/send 响应编解码、reason 四值映射', () {
    final enter = PresenceProtocol.encodeApplyEnter(
      PresenceApplyEnterCall(
        tabId: 't1',
        cookie: 'sessionid=abc',
        status: const <String, Object?>{'inRoom': true},
        reentered: true,
      ),
    );
    final dEnter = PresenceProtocol.decodeApplyEnter(enter)!;
    expect(dEnter.cookie, 'sessionid=abc');
    expect(dEnter.status, {'inRoom': true});
    expect(dEnter.reentered, isTrue);
    expect(PresenceProtocol.encodeApplyEnter(dEnter), enter);

    expect(
      PresenceProtocol.decodeTabApply(PresenceProtocol.encodeTabApply('t9')),
      't9',
    );

    expect(
      PresenceProtocol.decodeClaimResult(PresenceProtocol.encodeClaimOk()),
      (ok: true, reason: null),
    );
    for (final reason in PresenceFailureReason.values
        .where((r) => r != PresenceFailureReason.ipcFailed)) {
      final decoded = PresenceProtocol.decodeClaimResult(
        PresenceProtocol.encodeClaimFailure(reason),
      )!;
      expect(decoded.ok, isFalse);
      expect(decoded.reason, reason);
      expect(
        PresenceProtocol.reasonFromWire(PresenceProtocol.reasonToWire(reason)),
        reason,
      );
    }
    expect(PresenceProtocol.reasonToWire(PresenceFailureReason.ipcFailed),
        isNull);
    expect(PresenceProtocol.reasonFromWire('bogus'), isNull);

    final notHolder = PresenceProtocol.decodeSendResult(
      PresenceProtocol.encodeSendResult(PresenceSendResult.notHolder),
    )!;
    expect(notHolder.success, isFalse);
    expect(notHolder.code, 'not_holder');
    expect(notHolder.message, isNull);

    final sent = PresenceProtocol.decodeSendResult(
      PresenceProtocol.encodeSendResult(
        const PresenceSendResult(success: true, message: '已发送'),
      ),
    )!;
    expect(sent.success, isTrue);
    expect(sent.code, isNull);
    expect(sent.message, '已发送');
  });

  test('坏载荷：全部 decode 为 null（不入仲裁栈、不发 HTTP）', () {
    expect(PresenceProtocol.decodeRegister(null), isNull);
    expect(PresenceProtocol.decodeRegister('x'), isNull);
    expect(
      PresenceProtocol.decodeRegister(<String, Object?>{'windowId': 'w1'}),
      isNull,
    );
    expect(
      PresenceProtocol.decodeRegister(const {
        'windowId': '',
        'tabId': 't',
        'siteId': 'douyin',
        'roomId': '1',
        'shareUrl': '',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeRegister(const {
        'windowId': 'w',
        'tabId': 't',
        'siteId': 'douyin',
        'roomId': '1',
        'shareUrl': 2,
      }),
      isNull,
    );

    final goodClaim = Map<String, Object?>.from(
      PresenceProtocol.encodeClaim(
        const PresenceClaimCall(
          windowId: 'w',
          tabId: 't',
          roomId: '1',
          shareUrl: '',
          guardRoomId: 'r',
          guardWebRid: 'g',
          guardExtra: <String, Object?>{},
        ),
      ),
    );
    final badExtra = Map<String, Object?>.from(goodClaim)
      ..['guardExtra'] = 'no';
    final badRoomIdType = Map<String, Object?>.from(goodClaim)
      ..['guardRoomId'] = 1;
    final missingWebRid = Map<String, Object?>.from(goodClaim)
      ..remove('guardWebRid');
    expect(PresenceProtocol.decodeClaim(badExtra), isNull);
    expect(PresenceProtocol.decodeClaim(badRoomIdType), isNull);
    expect(PresenceProtocol.decodeClaim(missingWebRid), isNull);

    expect(PresenceProtocol.decodeRelease(null), isNull);
    expect(
      PresenceProtocol.decodeRelease({'windowId': 'w'}),
      isNull,
    );
    expect(
      PresenceProtocol.decodeBatchRelease({
        'windowId': 'w',
        'tabIds': 'x',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeBatchRelease({
        'windowId': 'w',
        'tabIds': ['t', 1],
      }),
      isNull,
    );

    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'poke',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'danmaku',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'danmaku',
        'content': '',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'action',
        'action': '',
      }),
      isNull,
    );

    expect(
      PresenceProtocol.decodeApplyEnter({
        'tabId': 't',
        'cookie': 'c',
        'status': <String, Object?>{},
        'reentered': 'yes',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeApplyEnter({
        'tabId': 't',
        'cookie': 1,
        'status': <String, Object?>{},
        'reentered': false,
      }),
      isNull,
    );

    expect(PresenceProtocol.decodeTabApply('x'), isNull);
    expect(PresenceProtocol.decodeTabApply({'tabId': ''}), isNull);

    expect(PresenceProtocol.decodeClaimResult(null), isNull);
    expect(PresenceProtocol.decodeClaimResult({'ok': 'x'}), isNull);
    expect(
      PresenceProtocol.decodeClaimResult({'ok': false, 'reason': 'nope'}),
      isNull,
    );
    expect(PresenceProtocol.decodeClaimResult({'ok': false}), isNull);

    expect(PresenceProtocol.decodeSendResult(null), isNull);
    expect(PresenceProtocol.decodeSendResult({'success': 'x'}), isNull);
    expect(
      PresenceProtocol.decodeSendResult({'success': true, 'code': 1}),
      isNull,
    );
  });

  test('sanitizeForLog：cookie 脱敏，输出不含原文，非敏感字段正常序列化', () {
    const cookie = 'sessionid=secretvalue';
    final enter = PresenceProtocol.encodeApplyEnter(
      PresenceApplyEnterCall(
        tabId: 't1',
        cookie: cookie,
        status: const <String, Object?>{
          'inRoom': true,
          'nested': <String, Object?>{'cookie': 'x'},
        },
        reentered: false,
      ),
    );
    final log =
        PresenceProtocol.sanitizeForLog(PresenceProtocol.mApplyEnter, enter);
    expect(log, contains('pr_apply_enter'));
    expect(log, contains('<cookie:${cookie.length}chars>'));
    expect(log.contains('sessionid'), isFalse);
    expect(log.contains('secretvalue'), isFalse);
    expect(log, contains('<cookie:1chars>'), reason: '嵌套 map 内 cookie 同样脱敏');
    expect(log, contains('"tabId":"t1"'), reason: '非敏感字段正常序列化');

    final listLog = PresenceProtocol.sanitizeForLog('x', const [
      <String, Object?>{'cookie': 'sessionid=abc'},
    ]);
    expect(listLog.contains('sessionid'), isFalse);
    expect(listLog, contains('<cookie:'));

    expect(
      PresenceProtocol.sanitizeForLog('x', Object()),
      contains('unserializable'),
    );

    final claim = PresenceProtocol.encodeClaim(
      const PresenceClaimCall(
        windowId: 'w',
        tabId: 't',
        roomId: '1',
        shareUrl: '',
        guardRoomId: 'r',
        guardWebRid: 'g',
        guardExtra: <String, Object?>{},
      ),
    );
    final claimLog =
        PresenceProtocol.sanitizeForLog(PresenceProtocol.mClaim, claim);
    expect(claimLog, contains('"tabId":"t"'));
    expect(claimLog.contains('cookie'), isFalse, reason: 'claim 载荷无 cookie');
  });
}
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/presence_protocol_test.dart`
Expected: 编译失败——`presence_protocol.dart` 不存在。

- [ ] **Step 2: 实现协议文件**

`lib/app/multiwindow/presence/ipc/presence_protocol.dart` 全文：

```dart
import 'dart:convert';

import '../presence_client.dart';

/// 账号面 presence IPC 协议（pr_ 前缀）。形态对齐 DataPlaneProtocol：
/// 私有构造、常量方法名、显式 encode/decode、非法载荷返回 null。
///
/// 载荷全部 JSON 兼容（Map/List/num/String/bool/null）。dp_ 流量经
/// MainDataPlaneService，pr_ 流量经 MainPresenceService，两服务互不解析
/// 对方方法，唯一交点是主窗 handler 默认分支的一行委托。
class PresenceProtocol {
  PresenceProtocol._();

  // ---- 方法名：子 → 主 ----
  static const String mRegister = 'pr_register';
  static const String mClaim = 'pr_claim';
  static const String mRelease = 'pr_release';
  static const String mDetach = 'pr_detach';
  static const String mBatchRelease = 'pr_batch_release';
  static const String mGuardSend = 'pr_guard_send';

  // ---- 方法名：主 → 子 ----
  static const String mApplyEnter = 'pr_apply_enter';
  static const String mApplyYield = 'pr_apply_yield';
  static const String mApplySuspended = 'pr_apply_suspended';

  // ---- pr_guard_send 的 kind ----
  static const String kDanmaku = 'danmaku';
  static const String kAction = 'action';

  // ---- claim failure reason 线值 ----
  static const String rNotLoggedIn = 'not_logged_in';
  static const String rNotConfigured = 'not_configured';
  static const String rDetailFailed = 'detail_failed';
  static const String rEnterFailed = 'enter_failed';

  static const Map<PresenceFailureReason, String> _reasonToWire = {
    PresenceFailureReason.notLoggedIn: rNotLoggedIn,
    PresenceFailureReason.notConfigured: rNotConfigured,
    PresenceFailureReason.detailFailed: rDetailFailed,
    PresenceFailureReason.enterFailed: rEnterFailed,
  };

  static String? reasonToWire(PresenceFailureReason reason) =>
      _reasonToWire[reason]; // ipcFailed 是子端本地结果，无线上值

  static PresenceFailureReason? reasonFromWire(String? wire) {
    for (final entry in _reasonToWire.entries) {
      if (entry.value == wire) return entry.key;
    }
    return null;
  }

  static String? _nonEmptyStr(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  // ---- register ----

  static Map<String, Object?> encodeRegister(PresenceRegisterCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
      };

  static PresenceRegisterCall? decodeRegister(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    if (windowId == null ||
        tabId == null ||
        siteId == null ||
        roomId == null ||
        shareUrl is! String) {
      return null;
    }
    return PresenceRegisterCall(
      windowId: windowId,
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
    );
  }

  // ---- claim ----

  static Map<String, Object?> encodeClaim(PresenceClaimCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'guardRoomId': call.guardRoomId,
        'guardWebRid': call.guardWebRid,
        'guardExtra': call.guardExtra,
      };

  static PresenceClaimCall? decodeClaim(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    // 空串合法（#6 骨架房），但缺失/错类型非法
    final guardRoomId = args['guardRoomId'];
    final guardWebRid = args['guardWebRid'];
    final guardExtra = args['guardExtra'];
    if (windowId == null ||
        tabId == null ||
        roomId == null ||
        shareUrl is! String ||
        guardRoomId is! String ||
        guardWebRid is! String ||
        guardExtra is! Map) {
      return null;
    }
    return PresenceClaimCall(
      windowId: windowId,
      tabId: tabId,
      roomId: roomId,
      shareUrl: shareUrl,
      guardRoomId: guardRoomId,
      guardWebRid: guardWebRid,
      guardExtra: Map<String, Object?>.from(guardExtra),
    );
  }

  // ---- release / detach（同载荷）----

  static Map<String, Object?> encodeRelease(PresenceReleaseCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
      };

  static PresenceReleaseCall? decodeRelease(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    if (windowId == null || tabId == null) return null;
    return PresenceReleaseCall(windowId: windowId, tabId: tabId);
  }

  // ---- batch release ----

  static Map<String, Object?> encodeBatchRelease(
          PresenceBatchReleaseCall call) =>
      {
        'windowId': call.windowId,
        'tabIds': call.tabIds,
      };

  static PresenceBatchReleaseCall? decodeBatchRelease(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabIds = args['tabIds'];
    if (windowId == null || tabIds is! List) return null;
    for (final id in tabIds) {
      if (id is! String || id.isEmpty) return null;
    }
    return PresenceBatchReleaseCall(
      windowId: windowId,
      tabIds: List<String>.from(tabIds),
    );
  }

  // ---- guard send ----

  static Map<String, Object?> encodeGuardSend(PresenceGuardSendCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'kind': call.kind,
        if (call.content != null) 'content': call.content,
        if (call.action != null) 'action': call.action,
      };

  static PresenceGuardSendCall? decodeGuardSend(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final kind = args['kind'];
    if (windowId == null ||
        tabId == null ||
        (kind != kDanmaku && kind != kAction)) {
      return null;
    }
    if (kind == kDanmaku) {
      final content = args['content'];
      if (content is! String || content.isEmpty) return null;
      return PresenceGuardSendCall(
        windowId: windowId,
        tabId: tabId,
        kind: kDanmaku,
        content: content,
      );
    }
    final action = args['action'];
    if (action is! String || action.isEmpty) return null;
    return PresenceGuardSendCall(
      windowId: windowId,
      tabId: tabId,
      kind: kAction,
      action: action,
    );
  }

  // ---- 主 → 子 apply ----

  static Map<String, Object?> encodeApplyEnter(PresenceApplyEnterCall call) => {
        'tabId': call.tabId,
        'cookie': call.cookie,
        'status': call.status,
        'reentered': call.reentered,
      };

  static PresenceApplyEnterCall? decodeApplyEnter(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    final cookie = args['cookie'];
    final status = args['status'];
    final reentered = args['reentered'];
    if (tabId == null ||
        cookie is! String ||
        status is! Map ||
        reentered is! bool) {
      return null;
    }
    return PresenceApplyEnterCall(
      tabId: tabId,
      cookie: cookie,
      status: Map<String, Object?>.from(status),
      reentered: reentered,
    );
  }

  static Map<String, Object?> encodeTabApply(String tabId) => {'tabId': tabId};

  static String? decodeTabApply(Object? args) {
    if (args is! Map) return null;
    return _nonEmptyStr(args, 'tabId');
  }

  // ---- 响应 ----

  static Map<String, Object?> encodeClaimOk() => {'ok': true};

  static Map<String, Object?> encodeClaimFailure(
      PresenceFailureReason reason) {
    final wire = reasonToWire(reason);
    if (wire == null) {
      // ipcFailed 是 invoke 抛错时子端本地构造的结果，永不来自主端
      throw ArgumentError('不可上线的 claim reason: $reason');
    }
    return {'ok': false, 'reason': wire};
  }

  static ({bool ok, PresenceFailureReason? reason})? decodeClaimResult(
      Object? raw) {
    if (raw is! Map || raw['ok'] is! bool) return null;
    final ok = raw['ok'] as bool;
    if (ok) return (ok: true, reason: null);
    final wireReason = raw['reason'];
    final reason =
        wireReason is String ? reasonFromWire(wireReason) : null;
    if (reason == null) return null;
    return (ok: false, reason: reason);
  }

  static Map<String, Object?> encodeSendResult(PresenceSendResult result) => {
        'success': result.success,
        if (result.code != null) 'code': result.code,
        if (result.message != null) 'message': result.message,
      };

  static PresenceSendResult? decodeSendResult(Object? raw) {
    if (raw is! Map || raw['success'] is! bool) return null;
    final code = raw['code'];
    final message = raw['message'];
    if ((code != null && code is! String) ||
        (message != null && message is! String)) {
      return null;
    }
    return PresenceSendResult(
      success: raw['success'] as bool,
      code: code as String?,
      message: message as String?,
    );
  }

  /// 日志安全序列化：任何层级的 cookie 键替换为 <cookie:Nchars>，
  /// 调用方必须经此函数打印 pr_ 载荷，严禁直接打印原始 args。
  static String sanitizeForLog(String method, Object? args) {
    Object? scrub(Object? value) {
      if (value is Map) {
        return <String, Object?>{
          for (final entry in value.entries)
            entry.key.toString(): entry.key == 'cookie'
                ? '<cookie:${entry.value is String ? (entry.value as String).length : 0}chars>'
                : scrub(entry.value),
        };
      }
      if (value is List) return value.map(scrub).toList();
      return value;
    }

    try {
      return '$method ${jsonEncode(scrub(args))}';
    } catch (_) {
      return '$method <unserializable>';
    }
  }
}

class PresenceRegisterCall {
  const PresenceRegisterCall({
    required this.windowId,
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
  });

  final String windowId;
  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
}

class PresenceClaimCall {
  const PresenceClaimCall({
    required this.windowId,
    required this.tabId,
    required this.roomId,
    required this.shareUrl,
    required this.guardRoomId,
    required this.guardWebRid,
    required this.guardExtra,
  });

  final String windowId;
  final String tabId;
  final String roomId;
  final String shareUrl;
  final String guardRoomId;
  final String guardWebRid;
  final Map<String, Object?> guardExtra;
}

class PresenceReleaseCall {
  const PresenceReleaseCall({required this.windowId, required this.tabId});

  final String windowId;
  final String tabId;
}

class PresenceBatchReleaseCall {
  const PresenceBatchReleaseCall({
    required this.windowId,
    required this.tabIds,
  });

  final String windowId;
  final List<String> tabIds;
}

class PresenceGuardSendCall {
  const PresenceGuardSendCall({
    required this.windowId,
    required this.tabId,
    required this.kind,
    this.content,
    this.action,
  });

  final String windowId;
  final String tabId;
  final String kind;
  final String? content;
  final String? action;
}

class PresenceApplyEnterCall {
  const PresenceApplyEnterCall({
    required this.tabId,
    required this.cookie,
    required this.status,
    required this.reentered,
  });

  final String tabId;
  final String cookie;
  final Map<String, Object?> status;
  final bool reentered;
}
```

- [ ] **Step 3: 跑协议测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/presence_protocol_test.dart`
Expected：4 例全绿。

- [ ] **Step 4: 门禁（纯新增文件，无接线）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿（本任务无生产消费点，不需 build windows）。

- [ ] **Step 5: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/ipc/presence_protocol.dart \
  simple_live_app/test/multiwindow/presence_protocol_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 新增 pr_ 账号面 IPC 协议与日志脱敏

显式 encode/decode 覆盖 register/claim/release/detach/batch/guard_send
与主→子三个 apply；坏载荷一律 decode null；claim reason 四值与
PresenceFailureReason 双向映射，ipcFailed 不上线；sanitizeForLog
递归脱敏任意层级 cookie，单测钉死不含凭据原文。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: reconcile 返回摘除集、WindowOpenService.onChildWindowsClosed 广播

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/window/window_registry.dart`
- Modify: `simple_live_app/lib/app/multiwindow/window/window_open_service.dart`
- Test: `simple_live_app/test/multiwindow/window_open_service_test.dart`

**Interfaces:**
- Consumes: 现有 `WindowRegistry.reconcile(Iterable<String> aliveWindowIds)`（void，window_registry.dart:35-39）；`WindowOpenService.onInit` 的 windowsChanged 监听（window_open_service.dart:82-88）。
- Produces（T7 MainPresenceService 消费，命名锁定）：
  - `Set<String> WindowRegistry.reconcile(Iterable<String> aliveWindowIds)`——返回本次被摘除的 windowId 集合（无变化返回空集）。
  - `Stream<Set<String>> WindowOpenService.onChildWindowsClosed`——broadcast；每次对账摘除非空集合时推送一次，事件载荷恰为被摘除 windowId 集。

- [ ] **Step 1: 改测试（registry 返回值 + service 广播）**

`test/multiwindow/window_open_service_test.dart`：

(a) 现有 `test('WindowRegistry：登记/查询/对账', ...)`（第 84–96 行）中第 93 行起替换：

```dart
    final removed = registry.reconcile(['main', 'w2']);
    expect(removed, {'w1'}, reason: '返回值恰为被摘除窗口集');
    expect(registry.childCount, 1);
    expect(registry.windowForTab('douyin_a'), isNull);

    expect(registry.reconcile(['main', 'w2']), isEmpty,
        reason: '无变化时返回空集');
```

(b) 文件末尾（`onWindowsChanged：窗口消失后注册表自动对账摘除` 用例之后）追加：

```dart
  test('onChildWindowsClosed：摘除集推送一次，无变化不推送', () async {
    final closed = <Set<String>>[];
    final sub = service.onChildWindowsClosed.listen(closed.add);
    addTearDown(sub.cancel);

    await service.openInNewWindow(req('douyin', 'a'));
    await service.openInNewWindow(req('douyin', 'b'));
    await Future<void>.delayed(Duration.zero);
    expect(closed, isEmpty, reason: '开窗存活不产生死亡事件');

    port.alive.remove('w1');
    port.changedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(closed, [
      {'w1'}
    ], reason: '一次对账事件推送一个摘除集');

    port.changedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(closed.length, 1, reason: '窗口集无变化不推送');

    port.alive.remove('w2');
    port.changedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(closed.last, {'w2'});
  });
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_open_service_test.dart`
Expected：编译失败/断言失败——reconcile 返回 void、onChildWindowsClosed 不存在。

- [ ] **Step 2: WindowRegistry.reconcile 返回摘除集**

`window_registry.dart` 第 34–39 行替换：

```dart
  /// onWindowsChanged 后按存活窗口列表对账，摘除已关闭窗口。
  /// 返回本次被摘除的 windowId 集合（无变化为空集），供订阅者
  /// （MainPresenceService）批量释放该窗名下的远端 presence 标签。
  Set<String> reconcile(Iterable<String> aliveWindowIds) {
    final alive = aliveWindowIds.toSet();
    final removed = <String>{};
    _childTabs.removeWhere((id, _) {
      if (alive.contains(id)) return false;
      removed.add(id);
      return true;
    });
    _order.removeWhere((id) => !_childTabs.containsKey(id));
    return removed;
  }
```

- [ ] **Step 3: WindowOpenService 暴露广播流**

`window_open_service.dart`：

(a) 在 `StreamSubscription<void>? _windowsChangedSub;`（第 77 行）下方加：

```dart
  final StreamController<Set<String>> _childWindowsClosed =
      StreamController<Set<String>>.broadcast();

  /// 对账发现子窗进程消失（无临终消息）时推送被摘除 windowId 集。
  /// MainPresenceService 订阅后批量释放该窗名下远端 presence 标签。
  Stream<Set<String>> get onChildWindowsClosed =>
      _childWindowsClosed.stream;
```

(b) `onInit` 监听体（第 82–88 行）替换：

```dart
    _windowsChangedSub = port.windowsChanged.listen((_) async {
      try {
        final removed =
            registry.reconcile(await port.listWindowIds());
        if (removed.isNotEmpty) {
          _childWindowsClosed.add(removed);
        }
      } catch (_) {
        // 对账失败等下一事件自愈，不影响开窗主流程
      }
    });
```

(c) `onClose`（第 91–96 行）补流关闭：

```dart
  @override
  void onClose() {
    unawaited(_windowsChangedSub?.cancel());
    _windowsChangedSub = null;
    unawaited(_childWindowsClosed.close());
    super.onClose();
  }
```

- [ ] **Step 4: 跑测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_open_service_test.dart`
Expected：全绿（含原有 `onWindowsChanged` 用例——void 返回值调用点已全部更新，grep 确认无其他调用者）。

Run：`grep -rn "\.reconcile(" simple_live_app/lib --include="*.dart"`
Expected：仅 window_open_service.dart 一处生产调用。

- [ ] **Step 5: 全量门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功（主引擎服务改动）。

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/window/window_registry.dart \
  simple_live_app/lib/app/multiwindow/window/window_open_service.dart \
  simple_live_app/test/multiwindow/window_open_service_test.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 窗口死亡对账返回摘除集并广播关闭事件

WindowRegistry.reconcile 返回本次摘除的 windowId 集；WindowOpenService
新增 onChildWindowsClosed 广播流，为 presence 主服务批量释放死亡子窗
名下远端标签提供唯一入口，无变化不推送。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: DouyinAccountService.setBorrowedLoginCookie（子窗借用 cookie 内存单点）

**Files:**
- Modify: `simple_live_app/lib/services/douyin_account_service.dart`
- Test: `simple_live_app/test/services/douyin_account_service_test.dart`

**Interfaces:**
- Consumes: 现有内存字段 `loginCookie`（第 21 行）、`logined`/`loginName`/`hasCookie` obs；`DouyinSite.loginCookie`（setSite 第 38–43 行受 `logined` 门控，借用写入必须绕过它）。
- Produces（T9 coordinator 消费，命名锁定）：`void setBorrowedLoginCookie(String? cookie)`——只写 `loginCookie` 字段与 `DouyinSite.loginCookie`（null 写空串）；**不写 KV、不翻转 logined/loginName/hasCookie、不动设备 cookie、不调 `_registerGuardAccount`**。

- [ ] **Step 1: 写失败测试**

`test/services/douyin_account_service_test.dart` 在 `setSite 身份解耦` group 之后、`main()` 内追加：

```dart
  group('setBorrowedLoginCookie 借用态（子窗）', () {
    final site = Sites.allSites['douyin']!.liveSite as DouyinSite;
    late DouyinAccountService service;

    setUp(() {
      service = DouyinAccountService();
    });

    tearDown(() {
      site.cookie = '';
      site.loginCookie = '';
    });

    test('借用 cookie 只写内存与 site.loginCookie，不翻转登录态；置 null 即清',
        () {
      // 本测试不注册 LocalStorageService / GuardServerService：借用路径
      // 若误触 KV 写入或 guard 注册，Get.find 会同步抛错使测试失败
      service.setBorrowedLoginCookie('sessionid=borrowed; ttwid=x');

      expect(service.loginCookie, 'sessionid=borrowed; ttwid=x');
      expect(site.loginCookie, 'sessionid=borrowed; ttwid=x');
      expect(service.logined.value, isFalse, reason: '借用不翻转 logined');
      expect(service.loginName.value, '未登录');
      expect(service.hasCookie.value, isFalse);
      expect(service.cookie, '', reason: '设备 ttwid 不受借用影响');

      service.setBorrowedLoginCookie(null);
      expect(service.loginCookie, '');
      expect(site.loginCookie, '');
      expect(service.logined.value, isFalse);
    });
  });
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/services/douyin_account_service_test.dart`
Expected：编译失败——`setBorrowedLoginCookie` 未定义。

- [ ] **Step 2: 实现借用写入**

`douyin_account_service.dart` 在 `_registerGuardAccount()` 方法（第 89–102 行）之后插入：

```dart
  /// 子窗口借用主窗口登录身份（M4-3 presence IPC）。
  ///
  /// 纯内存单点：只写 loginCookie 字段与 DouyinSite.loginCookie，不写 KV、
  /// 不翻转 logined/loginName/hasCookie、不触发 guard 账号注册。cookie 仅
  /// 在 pr_apply_enter 载荷里下行一次；yield/suspended/子窗关闭三个失效
  /// 点立即传 null 清除，进程退出即消失。必须绕过 setSite()——那里受
  /// logined 门控会把借用 cookie 立刻清空。
  void setBorrowedLoginCookie(String? cookie) {
    loginCookie = cookie ?? '';
    final site =
        Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    site.loginCookie = loginCookie;
  }
```

- [ ] **Step 3: 跑测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/services/douyin_account_service_test.dart`
Expected：全绿（旧 3 例 + 新 1 例）。

- [ ] **Step 4: 门禁（纯服务新增方法，无接线）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿（不需 build windows）。

- [ ] **Step 5: Commit**

```bash
git add simple_live_app/lib/services/douyin_account_service.dart \
  simple_live_app/test/services/douyin_account_service_test.dart
git commit -m "$(cat <<'EOF'
feat(account): 新增子窗借用登录 cookie 的内存单点写入

setBorrowedLoginCookie 只写 loginCookie 与 DouyinSite.loginCookie，
不落 KV、不翻转登录态、不注册 guard 账号；传 null 即清。供 M4-3
presence 子端 apply/yield/suspended 三失效点使用。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: 子端 presence 端口、RemotePresenceTab、MainPresenceService（主端 6 handler + 死亡对账）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/sub_presence_port.dart`
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/remote_presence_tab.dart`
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart`
- Test: `simple_live_app/test/multiwindow/main_presence_service_test.dart`（6 例）

**Interfaces:**
- Consumes: Task 1 网关 `Future<PresenceClaimResult> claim(DouyinPresenceTab)`、`release/detach(String)`、`batchRelease(Set<String>)`、`sendDanmakuAsHolder({required tabId, required content})`、`sendActionAsHolder({required tabId, required action})`、`stopHeartbeatForTesting()`；Task 2 `DouyinPresenceTab.applySuspended()` 为 `Future<void>`；Task 4 全部 PresenceProtocol；Task 5 `WindowOpenService.onChildWindowsClosed`；Task 6 主窗 `DouyinAccountService.instance.loginCookie`；`DouyinSite.getRoomDetail({required String roomId, required bool asAccount})`（roomId 形参传 `'$roomId;$shareUrl'`）；`SubWindowPort.invoke(windowId, method, args)`（主→子）。
- Produces（T8/T9 消费，命名锁定）：
  - `abstract class SubPresencePort { Future<Object?> invokeMain(String method, [Object? arguments]); }` + `DmwSubPresencePort(String mainWindowId)`。
  - `RemotePresenceTab({required String tabId, required String windowId, required String roomId, required String shareUrl, required SubWindowPort port, Future<LiveRoomDetail> Function(String roomId, String shareUrl)? accountDetailFetcher, String Function()? cookieReader})`；`final String windowId`；`void updateGuardArgs({required String guardRoomId, required String guardWebRid, required Map<String,Object?> guardExtra})`；`void markClosed()`。
  - `MainPresenceService extends GetxService`，构造 `{required DouyinPresenceGateway gateway, required SubWindowPort port, required WindowOpenService windowOpenService, Future<LiveRoomDetail> Function(String roomId, String shareUrl)? accountDetailFetcher, String Function()? cookieReader}`（后两个仅测试接缝，生产不传）；入口 `Future<Object?> handleCall(String method, Object? arguments)`；onInit 订阅死亡流，onClose 取消。
  - handler 回执铁律：register/claim/release/detach/batch 的**坏载荷或未注册伪造**返回 `false`（claim 的正常业务失败返回 `encodeClaimFailure`）；未知 release/detach 幂等返回 `true`；pr_guard_send 未注册/非 holder 返回 `encodeSendResult(PresenceSendResult.notHolder)`，坏载荷返回 `false`。

- [ ] **Step 1: 创建子端 presence 端口**

`lib/app/multiwindow/presence/ipc/sub_presence_port.dart` 全文：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎账号面 presence 调用的单一出口（pr_ 前缀）。
/// 生产走 dmw，测试用内存 fake；与 SubDataPlanePort 物理隔离，
/// 两个通道在主端分别由两个服务解析。
abstract class SubPresencePort {
  Future<Object?> invokeMain(String method, [Object? arguments]);
}

class DmwSubPresencePort implements SubPresencePort {
  DmwSubPresencePort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, arguments);
  }
}
```

- [ ] **Step 2: 写失败测试**

`test/multiwindow/main_presence_service_test.dart` 全文：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/main_presence_service.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _Registry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
}

class _FakeSubWindowPort implements SubWindowPort {
  final List<(String, String, Object?)> invokes = [];
  final List<String> alive = ['main'];
  final StreamController<void> changed =
      StreamController<void>.broadcast();
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final id = 'w${++_seq}';
    alive.add(id);
    return SubWindowHandle(id);
  }

  @override
  Future<void> invoke(String windowId, String method, Object? arguments) async {
    invokes.add((windowId, method, arguments));
  }

  @override
  Future<List<String>> listWindowIds() async => List<String>.of(alive);

  @override
  Stream<void> get windowsChanged => changed.stream;
}

class _FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];
  final ensureAccounts = <String>[];
  final sendDanmakus = <Map<String, Object?>>[];
  final sendActions = <Map<String, Object?>>[];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async {
    ensureAccounts.add(platform);
    return 'acct1';
  }

  @override
  Future<String?> reregister(String platform) async => 'acct2';

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    enters.add('$accountId@$roomId');
    return {'joined': false, 'starGuard': false, 'badgeActive': true};
  }

  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async =>
      {'inRoom': true};

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add('$accountId@$roomId');
  }

  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    sendDanmakus.add({
      'platform': platform,
      'accountId': accountId,
      'roomId': roomId,
      'content': content,
    });
    return {'success': true};
  }

  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async {
    sendActions.add({
      'accountId': accountId,
      'roomId': roomId,
      'action': action,
    });
    return {'success': true};
  }
}

LiveRoomDetail _detail(String webRid) => LiveRoomDetail(
      roomId: webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$webRid',
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: 'room_$webRid',
        userId: 'u_$webRid',
        cookie: 'sessionid=new',
      ),
    );

void main() {
  late _FakeGuard guard;
  late _FakeSubWindowPort port;
  late WindowRegistry registry;
  late WindowOpenService windowOpenService;
  late DouyinPresenceGateway gateway;
  late MainPresenceService svc;
  late String cookieNow;

  Future<Object?> register(String windowId, String tabId,
          {String siteId = 'douyin', String roomId = '1'}) =>
      svc.handleCall(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(PresenceRegisterCall(
          windowId: windowId,
          tabId: tabId,
          siteId: siteId,
          roomId: roomId,
          shareUrl: '',
        )),
      );

  Future<Object?> claim(
    String windowId,
    String tabId, {
    required String roomId,
    required String guardRoomId,
    required String guardWebRid,
  }) =>
      svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(PresenceClaimCall(
          windowId: windowId,
          tabId: tabId,
          roomId: roomId,
          shareUrl: 'http://s/$tabId',
          guardRoomId: guardRoomId,
          guardWebRid: guardWebRid,
          guardExtra: const <String, Object?>{},
        )),
      );

  setUp(() {
    guard = _FakeGuard();
    port = _FakeSubWindowPort();
    registry = WindowRegistry(mainWindowId: 'main');
    windowOpenService = WindowOpenService(
      port: port,
      store: TabStore(registry: _Registry()),
      registry: registry,
    );
    windowOpenService.onInit();
    cookieNow = 'sessionid=old';
    gateway = DouyinPresenceGateway(guard);
    svc = MainPresenceService(
      gateway: gateway,
      port: port,
      windowOpenService: windowOpenService,
      // claim 在途期间"主窗换号"：fetcher 内改值，apply 当刻必须读到新值
      accountDetailFetcher: (roomId, shareUrl) async {
        cookieNow = 'sessionid=new';
        return _detail(roomId);
      },
      cookieReader: () => cookieNow,
    );
    svc.onInit();
  });

  tearDown(() {
    gateway.stopHeartbeatForTesting();
    svc.onClose();
    windowOpenService.onClose();
  });

  test('register 只建死亡对账索引：不进栈、零 HTTP、零 invoke；非抖音/坏载荷拒绝',
      () async {
    expect(await register('w1', 't1'), isTrue);
    expect(guard.ensureAccounts, isEmpty);
    expect(guard.enters, isEmpty);
    expect(port.invokes, isEmpty);

    expect(await register('w1', 'tb', siteId: 'bilibili'), isFalse);
    expect(await svc.handleCall(PresenceProtocol.mRegister, null), isFalse);

    // 未 register 直接 claim：拒绝，不触达网关
    expect(
      await svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(
          const PresenceClaimCall(
            windowId: 'w1',
            tabId: 'x',
            roomId: '1',
            shareUrl: '',
            guardRoomId: 'r',
            guardWebRid: 'g',
            guardExtra: <String, Object?>{},
          ),
        ),
      ),
      isFalse,
    );
    expect(guard.enters, isEmpty);
  });

  test('远端 claim 成功：进场一次、apply_enter 下行且 cookie 为当刻值', () async {
    await register('w1', 't1');
    port.invokes.clear();
    guard.enters.clear();
    cookieNow = 'sessionid=old';
    final resp = await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    expect(
      PresenceProtocol.decodeClaimResult(resp),
      (ok: true, reason: null),
    );
    expect(guard.ensureAccounts, ['douyin']);
    expect(guard.enters, ['acct1@room_1']);

    expect(port.invokes, hasLength(1));
    final invoke = port.invokes.single;
    expect(invoke.$1, 'w1');
    expect(invoke.$2, PresenceProtocol.mApplyEnter);
    final apply = PresenceProtocol.decodeApplyEnter(invoke.$3)!;
    expect(apply.tabId, 't1');
    expect(apply.cookie, 'sessionid=new', reason: 'cookie 必须 apply 当刻读取');
    expect(apply.status, {'joined': false, 'starGuard': false, 'badgeActive': true});
    expect(apply.reentered, isFalse);
  });

  test('混栈：t2 抢占 t1 收 yield；release t2 后 t1 以 reentered 接管', () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    await register('w2', 't2', roomId: '2');
    await claim('w2', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');

    final yields = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyYield)
        .toList();
    expect(yields, hasLength(1));
    expect(yields.single.$1, 'w1');
    expect(PresenceProtocol.decodeTabApply(yields.single.$3), 't1');

    port.invokes.clear();
    final resp = await svc.handleCall(
      PresenceProtocol.mRelease,
      PresenceProtocol.encodeRelease(
          const PresenceReleaseCall(windowId: 'w2', tabId: 't2')),
    );
    expect(resp, isTrue);
    expect(guard.exits, contains('acct1@room_2'));

    final reenters = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(reenters, hasLength(1));
    expect(reenters.single.$1, 'w1');
    final apply =
        PresenceProtocol.decodeApplyEnter(reenters.single.$3)!;
    expect(apply.tabId, 't1');
    expect(apply.reentered, isTrue);
  });

  test('detach：摘栈不发 exit、不摘索引；同窗重新 claim 再进场；未知 release 幂等',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    port.invokes.clear();
    guard.enters.clear();

    expect(
      await svc.handleCall(
        PresenceProtocol.mDetach,
        PresenceProtocol.encodeRelease(
            const PresenceReleaseCall(windowId: 'w1', tabId: 't1')),
      ),
      isTrue,
    );
    expect(guard.exits, isEmpty, reason: 'detach 不发 exit');
    expect(port.invokes, isEmpty);

    final displaced = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(displaced.code, 'not_holder');

    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    expect(guard.enters, ['acct1@room_1'], reason: '重新 claim 完整再进场一次');
    expect(
      port.invokes.any((i) => i.$2 == PresenceProtocol.mApplyEnter),
      isTrue,
    );

    expect(
      await svc.handleCall(
        PresenceProtocol.mRelease,
        PresenceProtocol.encodeRelease(
            const PresenceReleaseCall(windowId: 'w1', tabId: 'zzz')),
      ),
      isTrue,
      reason: '未知 tab 幂等',
    );
    expect(
      await svc.handleCall(PresenceProtocol.mRelease, null),
      isFalse,
      reason: '坏载荷 false',
    );
  });

  test('batch_release 整批一次 exit；子窗进程死亡经对账批量释放', () async {
    await register('w1', 't1', roomId: '1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');
    await register('w1', 't2', roomId: '2');
    await claim('w1', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');

    expect(
      await svc.handleCall(
        PresenceProtocol.mBatchRelease,
        PresenceProtocol.encodeBatchRelease(const PresenceBatchReleaseCall(
          windowId: 'w1',
          tabIds: ['t1', 't2'],
        )),
      ),
      isTrue,
    );
    expect(guard.exits, ['acct1@room_2'], reason: '整批仅 holder 一次 exit');

    // 正常开窗登记后 register+claim，再模拟进程被杀（无临终消息）
    registry.registerChild('w2', {'douyin_3'});
    port.alive.add('w2');
    await register('w2', 't3', roomId: '3');
    await claim('w2', 't3',
        roomId: '3', guardRoomId: 'room_3', guardWebRid: '3');

    port.alive.remove('w2');
    port.changed.add(null);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(guard.exits.where((e) => e == 'acct1@room_3').length, 1,
        reason: '死亡对账至多一次 exit');
    final send = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w2',
            tabId: 't3',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(send.code, 'not_holder', reason: '死亡 tab 索引已摘除');
  });

  test('guard_send：holder 弹幕/动作经网关执行；抢占后 not_holder 零 HTTP；坏载荷 false',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1',
        roomId: '1', guardRoomId: 'room_1', guardWebRid: '1');

    final danmaku = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kDanmaku,
            content: 'hello',
          ),
        ),
      ),
    )!;
    expect(danmaku.success, isTrue);
    expect(guard.sendDanmakus.single, containsPair('content', 'hello'));
    expect(guard.sendDanmakus.single, containsPair('platform', 'douyin'));

    final action = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kAction,
            action: 'like',
          ),
        ),
      ),
    )!;
    expect(action.success, isTrue);
    expect(guard.sendActions.single, containsPair('action', 'like'));
    expect(guard.sendActions.single.containsKey('platform'), isFalse,
        reason: 'sendAction 不带 platform');

    await register('w2', 't2', roomId: '2');
    await claim('w2', 't2',
        roomId: '2', guardRoomId: 'room_2', guardWebRid: '2');
    guard.sendDanmakus.clear();
    final displaced = PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          const PresenceGuardSendCall(
            windowId: 'w1',
            tabId: 't1',
            kind: PresenceProtocol.kDanmaku,
            content: 'x',
          ),
        ),
      ),
    )!;
    expect(displaced.code, 'not_holder');
    expect(guard.sendDanmakus, isEmpty);

    expect(
      await svc.handleCall(PresenceProtocol.mGuardSend, null),
      isFalse,
    );
  });
}
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_presence_service_test.dart`
Expected: 编译失败——`remote_presence_tab.dart`、`main_presence_service.dart` 不存在。

- [ ] **Step 3: 创建 RemotePresenceTab**

`lib/app/multiwindow/presence/ipc/remote_presence_tab.dart` 全文：

```dart
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../presence_claimant.dart';
import 'presence_protocol.dart';

/// 远端抖音标签在主引擎侧的端口：与主窗本地标签混栈仲裁，账号态 HTTP
/// 全在主端执行；apply 回调经 SubWindowPort 单向 invoke 到该 tabId
/// 所属子窗。单次 apply invoke 失败不置 closed——通道失败不等于窗口
/// 死亡，硬死亡由 windowsChanged 对账兜底。
class RemotePresenceTab implements DouyinPresenceTab {
  RemotePresenceTab({
    required this.tabId,
    required this.windowId,
    required this.roomId,
    required this.shareUrl,
    required SubWindowPort port,
    Future<LiveRoomDetail> Function(String roomId, String shareUrl)?
        accountDetailFetcher,
    String Function()? cookieReader,
  })  : _port = port,
        _fetchDetail = accountDetailFetcher ?? _defaultFetchDetail,
        _readCookie = cookieReader ?? _defaultCookieReader;

  final String windowId;
  final String roomId;
  final String shareUrl;
  final SubWindowPort _port;
  final Future<LiveRoomDetail> Function(String, String) _fetchDetail;
  final String Function() _readCookie;

  static Future<LiveRoomDetail> _defaultFetchDetail(
      String roomId, String shareUrl) {
    final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    return site.getRoomDetail(roomId: '$roomId;$shareUrl', asAccount: true);
  }

  static String _defaultCookieReader() =>
      DouyinAccountService.instance.loginCookie;

  @override
  final String tabId;

  String _guardRoomId = '';
  String _guardWebRid = '';
  Map<String, Object?> _guardExtra = const <String, Object?>{};

  /// 每次 pr_claim 同步最新 guard 参数；首次 claim 即 bindTab，
  /// 进过栈的远端 tab 必有参数，fallback 可直接重新 enter。
  void updateGuardArgs({
    required String guardRoomId,
    required String guardWebRid,
    required Map<String, Object?> guardExtra,
  }) {
    _guardRoomId = guardRoomId;
    _guardWebRid = guardWebRid;
    _guardExtra = Map<String, Object?>.from(guardExtra);
  }

  bool _closed = false;
  @override
  bool get isClosed => _closed;

  /// release/batch/窗口死亡对账置位
  void markClosed() {
    _closed = true;
  }

  @override
  Future<LiveRoomDetail> fetchAccountDetail() =>
      _fetchDetail(roomId, shareUrl);

  @override
  String get guardRoomId => _guardRoomId;

  @override
  String get guardWebRid => _guardWebRid;

  @override
  Map<String, dynamic> guardExtraArgs() =>
      Map<String, dynamic>.from(_guardExtra);

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    // accountDetail 不下发：danmakuData 是 dynamic，跨引擎 JSON 往返不对称；
    // cookie 在发送当刻读取（claim 在途期间主窗可能换号，spec §5.2）。
    await _port.invoke(
      windowId,
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: tabId,
          cookie: _readCookie(),
          status: Map<String, Object?>.from(guardStatus),
          reentered: reentered,
        ),
      ),
    );
  }

  @override
  Future<void> applyYieldToGuest() => _port.invoke(
        windowId,
        PresenceProtocol.mApplyYield,
        PresenceProtocol.encodeTabApply(tabId),
      );

  @override
  Future<void> applySuspended() => _port.invoke(
        windowId,
        PresenceProtocol.mApplySuspended,
        PresenceProtocol.encodeTabApply(tabId),
      );
}
```

- [ ] **Step 4: 创建 MainPresenceService**

`lib/app/multiwindow/presence/ipc/main_presence_service.dart` 全文：

```dart
import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../douyin_presence_gateway.dart';
import '../presence_client.dart';
import 'presence_protocol.dart';
import 'remote_presence_tab.dart';

/// 主引擎账号面 presence 服务：解析 pr_ 方法，把远端标签混入唯一网关
/// 仲裁栈；维护 tabId→windowId 死亡对账索引（register 只建索引，
/// 不进栈）；订阅子窗死亡流批量释放。dp_/pr_ 互不解析对方方法。
class MainPresenceService extends GetxService {
  MainPresenceService({
    required this.gateway,
    required this.port,
    required WindowOpenService windowOpenService,
    this.accountDetailFetcher,
    this.cookieReader,
  }) : _windowOpenService = windowOpenService;

  final DouyinPresenceGateway gateway;
  final SubWindowPort port;
  final WindowOpenService _windowOpenService;

  /// 测试接缝：生产为 null，RemotePresenceTab 用主窗 DouyinSite 取详情
  final Future<LiveRoomDetail> Function(String roomId, String shareUrl)?
      accountDetailFetcher;

  /// 测试接缝：生产为 null，apply 当刻读 DouyinAccountService.loginCookie
  final String Function()? cookieReader;

  /// tabId → windowId，register/claim 时建，release/batch/死亡时摘
  final Map<String, String> _tabWindow = {};

  /// tabId → 远端标签，首次 claim 时建（与 _tabWindow 分离：register
  /// 不建标签、不碰仲裁栈）
  final Map<String, RemotePresenceTab> _remoteTabs = {};

  StreamSubscription<Set<String>>? _closedSub;

  @override
  void onInit() {
    super.onInit();
    _closedSub = _windowOpenService.onChildWindowsClosed
        .listen(_onChildWindowsClosed);
  }

  @override
  void onClose() {
    unawaited(_closedSub?.cancel());
    _closedSub = null;
    super.onClose();
  }

  /// 主窗 method handler 默认分支委托入口（T8 接线）
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case PresenceProtocol.mRegister:
        return _register(arguments);
      case PresenceProtocol.mClaim:
        return _claim(arguments);
      case PresenceProtocol.mRelease:
        return _release(arguments, detach: false);
      case PresenceProtocol.mDetach:
        return _release(arguments, detach: true);
      case PresenceProtocol.mBatchRelease:
        return _batchRelease(arguments);
      case PresenceProtocol.mGuardSend:
        return _guardSend(arguments);
      default:
        return null;
    }
  }

  Future<Object?> _register(Object? arguments) async {
    final call = PresenceProtocol.decodeRegister(arguments);
    if (call == null || call.siteId != Constant.kDouyin) return false;
    // 只建死亡对账索引：不建 RemotePresenceTab、不碰仲裁栈
    _tabWindow[call.tabId] = call.windowId;
    return true;
  }

  Future<Object?> _claim(Object? arguments) async {
    final call = PresenceProtocol.decodeClaim(arguments);
    if (call == null) return false;
    final registeredWindow = _tabWindow[call.tabId];
    if (registeredWindow == null || registeredWindow != call.windowId) {
      return false;
    }
    final existing = _remoteTabs[call.tabId];
    if (existing != null && existing.windowId != call.windowId) {
      existing.markClosed();
      _remoteTabs.remove(call.tabId);
    }
    final tab = _remoteTabs.putIfAbsent(
      call.tabId,
      () => RemotePresenceTab(
        tabId: call.tabId,
        windowId: call.windowId,
        roomId: call.roomId,
        shareUrl: call.shareUrl,
        port: port,
        accountDetailFetcher: accountDetailFetcher,
        cookieReader: cookieReader,
      ),
    );
    tab.updateGuardArgs(
      guardRoomId: call.guardRoomId,
      guardWebRid: call.guardWebRid,
      guardExtra: call.guardExtra,
    );
    final result = await gateway.claim(tab);
    if (result.granted) {
      return PresenceProtocol.encodeClaimOk();
    }
    return PresenceProtocol.encodeClaimFailure(
      result.reason ?? PresenceFailureReason.enterFailed,
    );
  }

  Future<Object?> _release(Object? arguments,
      {required bool detach}) async {
    final call = PresenceProtocol.decodeRelease(arguments);
    if (call == null) return false;
    final registeredWindow = _tabWindow[call.tabId];
    if (registeredWindow == null || registeredWindow != call.windowId) {
      return true; // 未知 tab：幂等
    }
    if (detach) {
      // detach 只摘仲裁栈：不摘索引、不置 closed（M4-4 跨窗拖拽复用）
      await gateway.detach(call.tabId);
      return true;
    }
    _remoteTabs.remove(call.tabId)?.markClosed();
    _tabWindow.remove(call.tabId);
    await gateway.release(call.tabId);
    return true;
  }

  Future<Object?> _batchRelease(Object? arguments) async {
    final call = PresenceProtocol.decodeBatchRelease(arguments);
    if (call == null) return false;
    final ids = <String>{};
    for (final tabId in call.tabIds) {
      if (_tabWindow[tabId] != call.windowId) continue;
      _remoteTabs.remove(tabId)?.markClosed();
      _tabWindow.remove(tabId);
      ids.add(tabId);
    }
    if (ids.isNotEmpty) {
      await gateway.batchRelease(ids);
    }
    return true;
  }

  Future<Object?> _guardSend(Object? arguments) async {
    final call = PresenceProtocol.decodeGuardSend(arguments);
    if (call == null) return false;
    if (_tabWindow[call.tabId] != call.windowId) {
      return PresenceProtocol.encodeSendResult(
          PresenceSendResult.notHolder);
    }
    final result = call.kind == PresenceProtocol.kDanmaku
        ? await gateway.sendDanmakuAsHolder(
            tabId: call.tabId,
            content: call.content!,
          )
        : await gateway.sendActionAsHolder(
            tabId: call.tabId,
            action: call.action!,
          );
    return PresenceProtocol.encodeSendResult(result);
  }

  /// 子窗进程被杀（无临终消息）：汇总已死窗名下登记的全部 tab，
  /// 整批一次摘栈释放，然后清自身索引。
  Future<void> _onChildWindowsClosed(Set<String> windowIds) async {
    final tabIds = <String>{};
    _tabWindow.removeWhere((tabId, windowId) {
      if (!windowIds.contains(windowId)) return false;
      tabIds.add(tabId);
      return true;
    });
    for (final tabId in tabIds) {
      _remoteTabs.remove(tabId)?.markClosed();
    }
    if (tabIds.isNotEmpty) {
      await gateway.batchRelease(tabIds);
    }
  }
}
```

- [ ] **Step 5: 跑新测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_presence_service_test.dart`
Expected：6 例全绿。若出现 pending Timer 报错，确认 tearDown 的 `gateway.stopHeartbeatForTesting()` 已执行。

- [ ] **Step 6: 门禁（未接 app_pages，build 在 Task 8 接线后跑）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- 日志安全核验：`grep -n "print\|logPrint\|Log\." lib/app/multiwindow/presence/ipc/main_presence_service.dart lib/app/multiwindow/presence/ipc/remote_presence_tab.dart` 无任何载荷/cookie 日志。

- [ ] **Step 7: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/ipc/sub_presence_port.dart \
  simple_live_app/lib/app/multiwindow/presence/ipc/remote_presence_tab.dart \
  simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart \
  simple_live_app/test/multiwindow/main_presence_service_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 主端账号面服务与远端标签混栈仲裁

新增 SubPresencePort（pr_ 通道）、RemotePresenceTab（主端取详情、
apply 单向 invoke、cookie 当刻读取）与 MainPresenceService（六个
入站 handler、tabId→windowId 索引、子窗死亡批量释放、guard_send
走网关串行域）。register 只建索引不进栈，非法载荷一律拒绝。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: 数据面默认分支委托 pr_ 与主窗守卫块注册 MainPresenceService

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`（构造 L27-34 加参数；default 分支 L262-263）
- Modify: `simple_live_app/lib/routes/app_pages.dart`（import；守卫块 L95-115）
- Test: `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`（新增 1 例，沿用既有 `_FakePort`/`MemoryKvBox` 夹具）

**Interfaces:**
- Consumes: Task 7 `MainPresenceService.handleCall`（`Future<Object?> Function(String method, Object? arguments)` 形态）、构造 `{required DouyinPresenceGateway gateway, required SubWindowPort port, required WindowOpenService windowOpenService, ...}`；Task 5 `WindowOpenService.onChildWindowsClosed`。
- Produces（命名锁定）：`MainDataPlaneService` 构造新增可选具名参数
  `final Future<Object?> Function(String method, Object? arguments)? unhandledMethodHandler;`。
  语义：仅 dp_ switch 的 `default` 分支调用它并原样返回其结果；为 null 时保持现状返回 `null`。dp_ 已知分支一行不动，绝不调用委托。

**dmw 铁律（spec §3/§8）**：presence 不得再挂主窗 `setWindowMethodHandler`；唯一接线是本任务 default 分支这一处委托。

- [ ] **Step 1: 写失败测试**

在 `test/multiwindow/main_data_plane_service_test.dart` 的 `main()` 内、最后一个 test 之后追加：

```dart
  test('未知方法（pr_ 前缀）委托 unhandledMethodHandler 并原样返回；dp_ 方法不触达',
      () async {
    // 独立夹具：不经 bootstrap()，避免触碰 WindowSnapshotBuilder 的 Get 依赖
    final localStorage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    final localDb = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    final delegated = <(String, Object?)>[];
    final localSvc = MainDataPlaneService(
      port: _FakePort(),
      registry: WindowRegistry(mainWindowId: 'main'),
      storage: localStorage,
      db: localDb,
      unhandledMethodHandler: (method, arguments) async {
        delegated.add((method, arguments));
        return 'ok';
      },
    );
    localSvc.onInit();
    try {
      final result =
          await localSvc.handleCall('pr_register', {'tabId': 't1'});
      expect(result, 'ok');
      expect(delegated, [
        ('pr_register', {'tabId': 't1'})
      ]);

      // dp_ 已知分支（坏载荷）在本服务内返回 false，不得落到委托
      final badKvSet =
          await localSvc.handleCall(DataPlaneProtocol.mKvSet, null);
      expect(badKvSet, isFalse);
      expect(delegated, hasLength(1), reason: 'dp_ 方法不触达 presence 委托');
    } finally {
      localSvc.onClose();
    }
  });
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: 编译失败——`MainDataPlaneService` 无 `unhandledMethodHandler` 参数。

- [ ] **Step 2: 加构造参数与字段**

`main_data_plane_service.dart` 构造函数改为（L27-41 区域，仅加最后一行参数与字段）：

```dart
  MainDataPlaneService({
    required this.port,
    required this.registry,
    required this.storage,
    required this.db,
    this.onSettingsChanged,
    this.mainController,
    this.unhandledMethodHandler,
  });

  final SubWindowPort port;
  final WindowRegistry registry;
  final LocalStorageService storage;
  final DBService db;
  final void Function()? onSettingsChanged;
  final WindowController? mainController;

  /// 非 dp_ 方法（pr_ 账号面）的唯一委托点；null 时未知方法返回 null
  final Future<Object?> Function(String method, Object? arguments)?
      unhandledMethodHandler;
```

- [ ] **Step 3: default 分支委托**

`handleCall` 末尾（原 L262-263）改为：

```dart
      default:
        final handler = unhandledMethodHandler;
        if (handler == null) return null;
        return handler(method, arguments);
```

- [ ] **Step 4: 跑测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected：全绿（含新例）。

- [ ] **Step 5: app_pages.dart 守卫块接线**

import 区（L8 douyin_presence_gateway import 旁）加：

```dart
import 'package:simple_live_app/app/multiwindow/presence/ipc/main_presence_service.dart';
```

守卫块内，`WindowOpenService` 的 `Get.put(...)` 之后、`MainDataPlaneService` 的 `Get.put(...)` 之前插入注册，并给数据面构造追加委托参数。整块替换为：

```dart
          final mainPresenceService = Get.put(
            MainPresenceService(
              gateway: Get.find<DouyinPresenceGateway>(),
              port: subWindowPort,
              windowOpenService: Get.find<WindowOpenService>(),
            ),
            permanent: true,
          );
          Get.put(
            MainDataPlaneService(
              port: subWindowPort,
              registry: windowRegistry,
              storage: LocalStorageService.instance,
              db: DBService.instance,
              onSettingsChanged: () =>
                  AppSettingsController.instance.reloadFromStorage(),
              mainController: DmwSubWindowPort.mainController,
              unhandledMethodHandler: mainPresenceService.handleCall,
            ),
            permanent: true,
          );
```

注意：
- Task 2 的步骤 ⑨ 已把 L80 网关构造改为带 `isAccountLoggedIn:` 的形式，本任务不动该行。
- `MainPresenceService` 必须在 `WindowOpenService` 之后构造（它 `onInit` 即订阅 `onChildWindowsClosed`），顺序如上。
- 守卫条件（Windows + 非子窗 + mainWindowId 非空）不变；Android/TV/子窗不注册，零行为变化。

- [ ] **Step 6: 门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功（接线任务必须过构建）。
- 静态核验：`grep -rn "setWindowMethodHandler" lib/app/multiwindow/presence/` 无任何匹配（presence 目录下不得重挂 handler）。

- [ ] **Step 7: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart \
  simple_live_app/lib/routes/app_pages.dart \
  simple_live_app/test/multiwindow/main_data_plane_service_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 主窗 dp_ 默认分支一行委托 pr_ 并注册账号面服务

MainDataPlaneService 新增可选 unhandledMethodHandler，仅 default
分支转发，dp_ 行为零变化；kShell 主引擎守卫块装配
MainPresenceService（permanent），不另挂 method handler。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: 子端 IpcPresenceCoordinator（出站 proxy + 三 apply 回调 + 子窗批量释放）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/presence_apply_target.dart`
- Create: `simple_live_app/lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart`
- Test: `simple_live_app/test/multiwindow/ipc_presence_coordinator_test.dart`（6 例）

**Interfaces:**
- Consumes: Task 1 `PresenceClient`/`PresenceClaimResult`/`PresenceSendResult`/`PresenceFailureReason`；Task 3 `PresenceBatchReleaser`；Task 4 全部 `PresenceProtocol`；Task 6 `DouyinAccountService.setBorrowedLoginCookie`；Task 7 `SubPresencePort`；控制器四公开方法（现有签名）：`Future<LiveRoomDetail> fetchAccountDetail()`、`Future<void> applyAccountEnter({required LiveRoomDetail accountDetail, required Map<String,dynamic> guardStatus, required bool reentered})`、`Future<void> applyYieldToGuest()`、`Future<void> applySuspended()`（Task 2 起为 `Future<void>`）。
- Produces（T10/T11 消费，命名锁定）：
  - `abstract class PresenceApplyTarget`：上述四方法同签名。T10 令 `LiveRoomController implements PresenceApplyTarget`（方法已存在，仅加 implements 子类型与 import）。
  - `class PresenceClaimArgs`：不可变值类，字段 `final String roomId, shareUrl, guardRoomId, guardWebRid; final Map<String,Object?> guardExtra;`，const 构造。
  - `const String kPresenceCodeIpcFailed = 'ipc_failed';`（仅子端本地发送失败码，不上线）。
  - `class IpcPresenceCoordinator extends GetxService implements PresenceBatchReleaser`，构造
    `IpcPresenceCoordinator({required String windowId, required SubPresencePort port, required PresenceApplyTarget? Function(String tabId) resolveTarget, required DouyinAccountService accounts})`；
    方法 `Future<void> registerRemoteTab({required String tabId, required String siteId, required String roomId, required String shareUrl})`（best-effort，异常只 Log.d）、
    `PresenceClient clientForTab({required String tabId, required PresenceClaimArgs Function() args})`（per-tab proxy；guard 参数在每次 claim 当刻经 `args()` 读取最新值）、
    `Future<Object?> handleCall(String method, Object? arguments)`（三 apply case，default→null）、
    `@override Future<void> batchRelease(Set<String> tabIds)`、
    `@override void onClose()`（清借用 cookie）。
- **设计 Ruling（对 spec §5.2/§6.1 文字的细化，计划内裁定）**：spec 说三 apply「经 registry 找到控制器」。实现为构造注入 `PresenceApplyTarget? Function(String tabId) resolveTarget` 闭包，而非 coordinator 直接依赖 `RoomControllerRegistry`：生产闭包（T10 接线）就是 `(tabId) => registry.controllerForTabId(tabId)`，语义等价；直接依赖具体 `LiveRoomController?` 会迫使单测构造真实控制器并触网取详情。LiveRoomController 在 T10 加 `implements PresenceApplyTarget` 后闭包类型自然成立。
- 三 apply 顺序铁律（spec §6.1/§6.2）：
  - enter：target==null → 静默 `null`（不写 cookie）；否则**先** `setBorrowedLoginCookie(cookie)` → `fetchAccountDetail()` 自取；自取抛错 → Log.d 后正常返回 `null`，**不**调 applyAccountEnter（保留游客弹幕，不向主端抛错）；applyAccountEnter 本身抛错 → Log.d 吞掉。
  - yield/suspended：decode 失败→`false`；target==null→`null`；否则**先** `setBorrowedLoginCookie(null)` 再调控制器对应方法（best-effort 吞错）。
- proxy 回执：claim 成功 granted；业务失败按 `decodeClaimResult` 的 reason；invoke 抛错或回执 decode 为 null → `PresenceClaimResult.failure(reason: ipcFailed)`。send 的 invoke 抛错/坏回执 → `PresenceSendResult(success:false, code: kPresenceCodeIpcFailed, message: '主窗口服务无响应，请重试')`（文案逐字，spec §5.1）。release/detach/batch/register 一律 best-effort 不抛。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/ipc_presence_coordinator_test.dart` 全文：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_apply_target.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakePort implements SubPresencePort {
  final List<(String, Object?)> calls = [];
  Object? claimResult;
  Object? sendResult;
  final Set<String> throwing = <String>{};

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (throwing.contains(method)) throw StateError('main gone');
    if (method == PresenceProtocol.mClaim) {
      return claimResult ?? PresenceProtocol.encodeClaimOk();
    }
    if (method == PresenceProtocol.mGuardSend) {
      return sendResult ??
          PresenceProtocol.encodeSendResult(
              const PresenceSendResult(success: true));
    }
    return null;
  }
}

class _FakeTarget implements PresenceApplyTarget {
  _FakeTarget(this.detail);

  final LiveRoomDetail detail;
  int enters = 0;
  int yields = 0;
  int suspended = 0;
  int detailCalls = 0;
  bool detailThrows = false;
  bool enterThrows = false;
  LiveRoomDetail? lastDetail;
  Map<String, dynamic>? lastStatus;
  bool? lastReentered;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async {
    detailCalls++;
    if (detailThrows) throw StateError('limited');
    return detail;
  }

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    enters++;
    if (enterThrows) throw StateError('boom');
    lastDetail = accountDetail;
    lastStatus = guardStatus;
    lastReentered = reentered;
  }

  @override
  Future<void> applyYieldToGuest() async => yields++;

  @override
  Future<void> applySuspended() async => suspended++;
}

LiveRoomDetail _detail(String webRid) => LiveRoomDetail(
      roomId: webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$webRid',
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: 'room_$webRid',
        userId: 'u_$webRid',
        cookie: 'sessionid=x',
      ),
    );

void main() {
  late _FakePort port;
  late DouyinAccountService accounts;
  final site = Sites.allSites['douyin']!.liveSite as DouyinSite;

  IpcPresenceCoordinator coord(
    Map<String, PresenceApplyTarget> targets,
  ) =>
      IpcPresenceCoordinator(
        windowId: 'w1',
        port: port,
        resolveTarget: (tabId) => targets[tabId],
        accounts: accounts,
      );

  PresenceClaimArgs args({String guardRoomId = 'room_1'}) =>
      PresenceClaimArgs(
        roomId: '1',
        shareUrl: 'http://s',
        guardRoomId: guardRoomId,
        guardWebRid: '1',
        guardExtra: const <String, Object?>{'k': 'v'},
      );

  setUp(() {
    port = _FakePort();
    accounts = DouyinAccountService();
  });

  tearDown(() {
    site.loginCookie = '';
  });

  test('apply_enter：写借用 cookie（logined 不翻转）→ 自取详情 → apply 透传',
      () async {
    final detail = _detail('1');
    final target = _FakeTarget(detail);
    final c = coord({'t1': target});

    final result = await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: const <String, Object?>{
            'joined': false,
            'starGuard': false,
            'badgeActive': true,
          },
          reentered: true,
        ),
      ),
    );

    expect(result, isNull);
    expect(accounts.loginCookie, 'sessionid=zzz');
    expect(site.loginCookie, 'sessionid=zzz');
    expect(accounts.logined.value, isFalse, reason: '借用不翻转 logined');
    expect(target.detailCalls, 1);
    expect(target.enters, 1);
    expect(identical(target.lastDetail, detail), isTrue,
        reason: '传入的是子端自取详情，不是下发对象');
    expect(target.lastStatus, {
      'joined': false,
      'starGuard': false,
      'badgeActive': true,
    });
    expect(target.lastReentered, isTrue);
  });

  test('yield/suspended：先清 cookie 再调控制器；坏载荷 false', () async {
    final target = _FakeTarget(_detail('1'));
    final c = coord({'t1': target});

    await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: const <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(accounts.loginCookie, 'sessionid=zzz');

    expect(
      await c.handleCall(
          PresenceProtocol.mApplyYield,
          PresenceProtocol.encodeTabApply('t1')),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: 'yield 先清 cookie');
    expect(site.loginCookie, '');
    expect(target.yields, 1);
    expect(target.suspended, 0);

    await c.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=again',
          status: const <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(
      await c.handleCall(
          PresenceProtocol.mApplySuspended,
          PresenceProtocol.encodeTabApply('t1')),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: 'suspended 先清 cookie');
    expect(target.suspended, 1);

    expect(await c.handleCall(PresenceProtocol.mApplyYield, null), isFalse);
  });

  test('target 已销毁（查无控制器）：静默返回，不写 cookie、不抛', () async {
    final c = coord(<String, PresenceApplyTarget>{});
    expect(
      await c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          PresenceApplyEnterCall(
            tabId: 'gone',
            cookie: 'sessionid=zzz',
            status: const <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      isNull,
    );
    expect(accounts.loginCookie, '', reason: '无目标不写 cookie');
    expect(
      await c.handleCall(
          PresenceProtocol.mApplyYield,
          PresenceProtocol.encodeTabApply('gone')),
      isNull,
    );
  });

  test('自取详情失败不抛回主端、不调 applyAccountEnter；apply 抛错也被吞',
      () async {
    final target = _FakeTarget(_detail('1'))
      ..detailThrows = true
      ..enterThrows = true;
    final c = coord({'t1': target});

    await expectLater(
      c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          PresenceApplyEnterCall(
            tabId: 't1',
            cookie: 'sessionid=zzz',
            status: const <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      completes,
    );
    expect(target.enters, 0, reason: '自取失败不调 apply');
    expect(accounts.loginCookie, 'sessionid=zzz',
        reason: 'cookie 已写，等待失效点清理');

    // 恢复取详情；applyAccountEnter 自身抛错同样不外逸
    target.detailThrows = false;
    await expectLater(
      c.handleCall(
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          PresenceApplyEnterCall(
            tabId: 't1',
            cookie: 'sessionid=zzz',
            status: const <String, Object?>{},
            reentered: false,
          ),
        ),
      ),
      completes,
    );
    expect(target.enters, 1);
  });

  test('per-tab proxy：claim 载荷当刻读取、成功/业务失败/IPC 失败映射；release/detach',
      () async {
    var guardRoomId = 'room_1';
    final c = coord(<String, PresenceApplyTarget>{});
    final client = c.clientForTab(
      tabId: 't1',
      args: () => args(guardRoomId: guardRoomId),
    );

    var r = await client.claim();
    expect(r.granted, isTrue);
    expect(client.isClaimed, isTrue);
    final claimCall =
        PresenceProtocol.decodeClaim(port.calls.last.$2)!;
    expect(claimCall.windowId, 'w1');
    expect(claimCall.tabId, 't1');
    expect(claimCall.roomId, '1');
    expect(claimCall.guardRoomId, 'room_1');
    expect(claimCall.guardExtra, {'k': 'v'});

    // args 提供者在再次 claim 当刻读到新值
    guardRoomId = 'room_2';
    r = await client.claim();
    expect(PresenceProtocol.decodeClaim(port.calls.last.$2)!.guardRoomId,
        'room_2');

    port.claimResult =
        PresenceProtocol.encodeClaimFailure(PresenceFailureReason.notConfigured);
    r = await client.claim();
    expect(r.granted, isFalse);
    expect(r.reason, PresenceFailureReason.notConfigured);
    expect(client.isClaimed, isFalse);

    port.claimResult = 'junk';
    r = await client.claim();
    expect(r.reason, PresenceFailureReason.ipcFailed);

    port.claimResult = null;
    port.throwing.add(PresenceProtocol.mClaim);
    r = await client.claim();
    expect(r.reason, PresenceFailureReason.ipcFailed);
    expect(client.isClaimed, isFalse);
    port.throwing.clear();

    expect(await client.claim(), isA<PresenceClaimResult>());
    expect(client.isClaimed, isTrue);
    await client.release();
    final releaseCall =
        PresenceProtocol.decodeRelease(port.calls.last.$2)!;
    expect(releaseCall.windowId, 'w1');
    expect(releaseCall.tabId, 't1');
    expect(port.calls.last.$1, PresenceProtocol.mRelease);
    expect(client.isClaimed, isFalse);

    port.throwing.add(PresenceProtocol.mRelease);
    await expectLater(client.release(), completes);
    port.throwing.clear();

    final client2 = c.clientForTab(tabId: 't2', args: args);
    await client2.detach();
    expect(port.calls.last.$1, PresenceProtocol.mDetach);
  });

  test('guard_send 载荷/结果往返；IPC 失败码与文案；register/batch/onClose',
      () async {
    final c = coord(<String, PresenceApplyTarget>{});
    final client = c.clientForTab(tabId: 't1', args: args);

    final ok = await client.sendDanmaku('hi');
    expect(ok.success, isTrue);
    var send = PresenceProtocol.decodeGuardSend(port.calls.last.$2)!;
    expect(send.windowId, 'w1');
    expect(send.tabId, 't1');
    expect(send.kind, PresenceProtocol.kDanmaku);
    expect(send.content, 'hi');

    await client.sendAction('like');
    send = PresenceProtocol.decodeGuardSend(port.calls.last.$2)!;
    expect(send.kind, PresenceProtocol.kAction);
    expect(send.action, 'like');

    port.throwing.add(PresenceProtocol.mGuardSend);
    var failed = await client.sendDanmaku('x');
    expect(failed.success, isFalse);
    expect(failed.code, kPresenceCodeIpcFailed);
    expect(failed.message, '主窗口服务无响应，请重试');
    port.throwing.clear();

    port.sendResult = 'junk';
    failed = await client.sendAction('like');
    expect(failed.code, kPresenceCodeIpcFailed);
    expect(failed.message, '主窗口服务无响应，请重试');

    await c.registerRemoteTab(
        tabId: 't9', siteId: 'douyin', roomId: '9', shareUrl: '');
    final reg = PresenceProtocol.decodeRegister(port.calls.last.$2)!;
    expect(reg.windowId, 'w1');
    expect(reg.tabId, 't9');
    expect(reg.siteId, 'douyin');
    expect(reg.roomId, '9');
    port.throwing.add(PresenceProtocol.mRegister);
    await expectLater(
      c.registerRemoteTab(
          tabId: 't9', siteId: 'douyin', roomId: '9', shareUrl: ''),
      completes,
    );
    port.throwing.clear();

    final callsBefore = port.calls.length;
    await c.batchRelease(<String>{});
    expect(port.calls.length, callsBefore, reason: '空集不发 IPC');
    await c.batchRelease({'t1', 't2'});
    final batch =
        PresenceProtocol.decodeBatchRelease(port.calls.last.$2)!;
    expect(batch.windowId, 'w1');
    expect(batch.tabIds.toSet(), {'t1', 't2'});
    port.throwing.add(PresenceProtocol.mBatchRelease);
    await expectLater(c.batchRelease({'t1'}), completes);
    port.throwing.clear();

    // onClose 是第三个 cookie 失效点
    final target = _FakeTarget(_detail('1'));
    final c2 = IpcPresenceCoordinator(
      windowId: 'w1',
      port: port,
      resolveTarget: (_) => target,
      accounts: accounts,
    );
    await c2.handleCall(
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: 't1',
          cookie: 'sessionid=zzz',
          status: const <String, Object?>{},
          reentered: false,
        ),
      ),
    );
    expect(accounts.loginCookie, 'sessionid=zzz');
    c2.onClose();
    expect(accounts.loginCookie, '');
    expect(site.loginCookie, '');
  });
}
```

Run（cwd=simple_live_app）：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/ipc_presence_coordinator_test.dart`
Expected: 编译失败——`presence_apply_target.dart`、`ipc_presence_coordinator.dart` 不存在。

- [ ] **Step 2: 创建 PresenceApplyTarget 接口**

`lib/app/multiwindow/presence/ipc/presence_apply_target.dart` 全文：

```dart
import 'package:simple_live_core/simple_live_core.dart';

/// 子引擎侧可接收主端 presence apply 的目标（LiveRoomController 实现）。
/// 抽成独立接口：IpcPresenceCoordinator 依赖它而非具体控制器，单测可注入
/// 假目标，避免构造真实 LiveRoomController 触网取房间详情。
abstract class PresenceApplyTarget {
  Future<LiveRoomDetail> fetchAccountDetail();

  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  });

  Future<void> applyYieldToGuest();

  Future<void> applySuspended();
}
```

- [ ] **Step 3: 实现 IpcPresenceCoordinator**

`lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart` 全文：

```dart
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../presence_batch_releaser.dart';
import '../presence_client.dart';
import 'presence_apply_target.dart';
import 'presence_protocol.dart';
import 'sub_presence_port.dart';

/// 子端本地发送（pr_guard_send）失败码：invoke 抛错或主窗回执无法解析。
/// not_holder/not_login 由主端产生；此码仅出子端、不上线。
const String kPresenceCodeIpcFailed = 'ipc_failed';

/// 子端 claim 当刻读取的进房参数快照提供者：guard 房间标识随游客详情
/// 刷新可能变化，故不在工厂调用时固化。
class PresenceClaimArgs {
  const PresenceClaimArgs({
    required this.roomId,
    required this.shareUrl,
    required this.guardRoomId,
    required this.guardWebRid,
    required this.guardExtra,
  });

  final String roomId;
  final String shareUrl;
  final String guardRoomId;
  final String guardWebRid;
  final Map<String, Object?> guardExtra;
}

/// 子引擎每窗一个：出站 presence IPC、per-tab PresenceClient 工厂、
/// 主→子三个 apply 回调；同时以 PresenceBatchReleaser 身份承接子窗
/// TabStore 的批量关闭（整批经主端一次释放）。
class IpcPresenceCoordinator extends GetxService
    implements PresenceBatchReleaser {
  IpcPresenceCoordinator({
    required this.windowId,
    required SubPresencePort port,
    required PresenceApplyTarget? Function(String tabId) resolveTarget,
    required DouyinAccountService accounts,
  })  : _port = port,
        _resolveTarget = resolveTarget,
        _accounts = accounts;

  final String windowId;
  final SubPresencePort _port;
  final PresenceApplyTarget? Function(String tabId) _resolveTarget;
  final DouyinAccountService _accounts;

  /// 子端控制器绑定后调用：只在主端建死亡对账索引，不进仲裁栈。
  /// best-effort：主窗不可达不阻塞子端进房（主窗关闭=应用退出）。
  Future<void> registerRemoteTab({
    required String tabId,
    required String siteId,
    required String roomId,
    required String shareUrl,
  }) async {
    try {
      await _port.invokeMain(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(
          PresenceRegisterCall(
            windowId: windowId,
            tabId: tabId,
            siteId: siteId,
            roomId: roomId,
            shareUrl: shareUrl,
          ),
        ),
      );
    } catch (e) {
      Log.d('presence: pr_register 失败：$e');
    }
  }

  /// 控制器持有的 per-tab presence 客户端；guard 参数每次 claim 当刻
  /// 经 [args] 读取（游客详情刷新后 roomId/webRid 可能变化）。
  PresenceClient clientForTab({
    required String tabId,
    required PresenceClaimArgs Function() args,
  }) =>
      _IpcPresenceClient(
        windowId: windowId,
        tabId: tabId,
        args: args,
        port: _port,
      );

  @override
  Future<void> batchRelease(Set<String> tabIds) async {
    if (tabIds.isEmpty) return;
    try {
      await _port.invokeMain(
        PresenceProtocol.mBatchRelease,
        PresenceProtocol.encodeBatchRelease(
          PresenceBatchReleaseCall(
            windowId: windowId,
            tabIds: tabIds.toList(),
          ),
        ),
      );
    } catch (e) {
      Log.d('presence: pr_batch_release 失败：$e');
    }
  }

  /// 子引擎总 method handler 的 pr_apply_* 三 case 转交入口（T10 接线）。
  /// 查无控制器（已销毁）静默返回；任何子端异常不得回传主端——主端
  /// apply 本就是 best-effort，通道抛错只会变成主端日志噪音。
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case PresenceProtocol.mApplyEnter:
        final call = PresenceProtocol.decodeApplyEnter(arguments);
        if (call == null) return false;
        final target = _resolveTarget(call.tabId);
        if (target == null) return null;
        // 先写借用 cookie，自取详情才会带 sessionid
        _accounts.setBorrowedLoginCookie(call.cookie);
        final LiveRoomDetail detail;
        try {
          detail = await target.fetchAccountDetail();
        } catch (e) {
          // 自取失败：保留游客弹幕，不调 apply；不向主端抛错
          Log.d('presence: 子端自取账号详情失败，保持游客弹幕：$e');
          return null;
        }
        try {
          await target.applyAccountEnter(
            accountDetail: detail,
            guardStatus: Map<String, dynamic>.from(call.status),
            reentered: call.reentered,
          );
        } catch (e) {
          Log.d('presence: 子端 applyAccountEnter 失败：$e');
        }
        return null;

      case PresenceProtocol.mApplyYield:
      case PresenceProtocol.mApplySuspended:
        final tabId = PresenceProtocol.decodeTabApply(arguments);
        if (tabId == null) return false;
        // cookie 先于控制器切换失效（三失效点之二）
        _accounts.setBorrowedLoginCookie(null);
        final target = _resolveTarget(tabId);
        if (target == null) return null;
        try {
          if (method == PresenceProtocol.mApplyYield) {
            await target.applyYieldToGuest();
          } else {
            await target.applySuspended();
          }
        } catch (e) {
          Log.d('presence: 子端 $method apply 失败：$e');
        }
        return null;

      default:
        return null;
    }
  }

  @override
  void onClose() {
    // 三失效点之三：子窗关闭即清借用 cookie
    _accounts.setBorrowedLoginCookie(null);
    super.onClose();
  }
}

class _IpcPresenceClient implements PresenceClient {
  _IpcPresenceClient({
    required this.windowId,
    required this.tabId,
    required this.args,
    required this.port,
  });

  final String windowId;
  final String tabId;
  final PresenceClaimArgs Function() args;
  final SubPresencePort port;

  bool _claimed = false;

  @override
  bool get isClaimed => _claimed;

  @override
  Future<PresenceClaimResult> claim() async {
    final a = args();
    try {
      final raw = await port.invokeMain(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(
          PresenceClaimCall(
            windowId: windowId,
            tabId: tabId,
            roomId: a.roomId,
            shareUrl: a.shareUrl,
            guardRoomId: a.guardRoomId,
            guardWebRid: a.guardWebRid,
            guardExtra: a.guardExtra,
          ),
        ),
      );
      final r = PresenceProtocol.decodeClaimResult(raw);
      if (r == null) {
        _claimed = false;
        return const PresenceClaimResult.failure(
            reason: PresenceFailureReason.ipcFailed);
      }
      _claimed = r.ok;
      if (r.ok) return const PresenceClaimResult.granted();
      return PresenceClaimResult.failure(
          reason: r.reason ?? PresenceFailureReason.ipcFailed);
    } catch (_) {
      _claimed = false;
      return const PresenceClaimResult.failure(
          reason: PresenceFailureReason.ipcFailed);
    }
  }

  @override
  Future<void> release() => _leave(PresenceProtocol.mRelease);

  @override
  Future<void> detach() => _leave(PresenceProtocol.mDetach);

  Future<void> _leave(String method) async {
    _claimed = false;
    try {
      await port.invokeMain(
        method,
        PresenceProtocol.encodeRelease(
          PresenceReleaseCall(windowId: windowId, tabId: tabId),
        ),
      );
    } catch (e) {
      Log.d('presence: $method 失败：$e');
    }
  }

  @override
  Future<PresenceSendResult> sendDanmaku(String content) =>
      _send(PresenceProtocol.kDanmaku, content: content);

  @override
  Future<PresenceSendResult> sendAction(String action) =>
      _send(PresenceProtocol.kAction, action: action);

  Future<PresenceSendResult> _send(
    String kind, {
    String? content,
    String? action,
  }) async {
    try {
      final raw = await port.invokeMain(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          PresenceGuardSendCall(
            windowId: windowId,
            tabId: tabId,
            kind: kind,
            content: content,
            action: action,
          ),
        ),
      );
      final r = PresenceProtocol.decodeSendResult(raw);
      if (r != null) return r;
    } catch (_) {
      // 落到本地失败回执
    }
    return const PresenceSendResult(
      success: false,
      code: kPresenceCodeIpcFailed,
      message: '主窗口服务无响应，请重试',
    );
  }
}
```

- [ ] **Step 4: 跑测试**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/ipc_presence_coordinator_test.dart`
Expected：6 例全绿。

- [ ] **Step 5: 门禁（本任务无生产接线，不跑 build）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- 日志安全核验：`grep -n "cookie" lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart` 仅出现于 `setBorrowedLoginCookie(call.cookie)` 透传，无任何 print/logPrint 输出载荷。

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/presence/ipc/presence_apply_target.dart \
  simple_live_app/lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart \
  simple_live_app/test/multiwindow/ipc_presence_coordinator_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 子端 presence 协调者与 per-tab IPC 代理

IpcPresenceCoordinator 承接 pr_claim/release/detach/batch/guard_send
出站与主→子三 apply：借用 cookie 先写后自取、yield/suspended/onClose
三失效点立即清空；target 经 resolver 闭包解析，查无控制器静默；
IPC 异常映射 ipcFailed/ipc_failed 且不穿透。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: controllerForTabId 扩展、LiveRoomController implements、子引擎装配 coordinator

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/shell/room_controller_registry.dart`（接口加 1 方法）
- Modify: `simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart`（实现）
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（L52 类声明 + import）
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`（import ×3、presencePort、coordinator、TabStore 参数、总 handler 三 case）
- Modify（测试 fake 同步，5 处类）：`simple_live_app/test/tab_store_test.dart`（`FakeRegistry`、`ThrowingRegistry`；`FakeThenThrowRegistry` 继承自动获得）、`simple_live_app/test/multiwindow/window_open_service_test.dart`（`FakeRegistry`）、`simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`（`_FakeRegistry`）、`simple_live_app/test/multiwindow/main_presence_service_test.dart`（Task 7 的 `_Registry`）

**Interfaces:**
- Consumes: Task 9 `IpcPresenceCoordinator` 构造、`PresenceApplyTarget`、`DmwSubPresencePort(String)`（Task 7）；Task 3 `TabStore` 字段已换型 `PresenceBatchReleaser?`（构造参数名仍 `presenceGateway`）；`WindowController.windowId` 在 dmw 补丁版为 `String`，子引擎入口已有 `WindowController self`（main.dart L55-57），故自身 windowId 取 `self.windowId`。
- Produces（T11 消费）：
  - `RoomControllerRegistry.controllerForTabId(String tabId) → LiveRoomController?`；getx 实现按 tag 查找（已注销/未注册返 null）。
  - 子引擎 Get 容器中 `IpcPresenceCoordinator` 以 permanent 注册（仅 `args.mainWindowId` 非空时）；控制器 T11 经 `Get.isRegistered<IpcPresenceCoordinator>()` 守卫后 `Get.find`。
- 本任务为纯接线：接口新方法无行为分支，不新增测试；编译 + 全量测试 + windows debug 构建为门禁。

- [ ] **Step 1: 接口与 getx 实现加 controllerForTabId**

`room_controller_registry.dart` 在 `controllerForRoomKey` 声明后加：

```dart
  /// 按 tabId 找本引擎现存房间控制器（子端 presence apply 回调解析用），无则 null
  LiveRoomController? controllerForTabId(String tabId);
```

`getx_room_controller_registry.dart` 在 `controllerForRoomKey` 方法之后加：

```dart
  @override
  LiveRoomController? controllerForTabId(String tabId) {
    if (!Get.isRegistered<LiveRoomController>(tag: tabId)) return null;
    return Get.find<LiveRoomController>(tag: tabId);
  }
```

- [ ] **Step 2: 同步全部测试 fake（4 个文件、5 个类）**

下列每个类的 `controllerForRoomKey` 方法之后，逐字插入同一方法：

```dart
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
```

位置清单：
1. `test/tab_store_test.dart` → `class FakeRegistry`（约 L20-21 之后）
2. `test/tab_store_test.dart` → `class ThrowingRegistry`（约 L34-35 之后）
3. `test/multiwindow/window_open_service_test.dart` → `FakeRegistry`（约 L31-32 之后）
4. `test/multiwindow/sub_data_plane_client_test.dart` → `_FakeRegistry`（L35 `controllerForRoomKey` 之后）
5. `test/multiwindow/main_presence_service_test.dart` → Task 7 所写 `_Registry`（`controllerForRoomKey` 之后）

`FakeThenThrowRegistry extends FakeRegistry` 不新增（继承获得）。

- [ ] **Step 3: LiveRoomController implements PresenceApplyTarget**

`live_room_controller.dart` import 区加（与其他 multiwindow import 同区）：

```dart
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_apply_target.dart';
```

L52 类声明改为：

```dart
class LiveRoomController extends PlayerController
    with WidgetsBindingObserver
    implements PresenceApplyTarget {
```

四个方法（`fetchAccountDetail` L544、`applyAccountEnter` L552、`applyYieldToGuest` L572、Task 2 起为 `Future<void>` 的 `applySuspended`）签名已与接口一致，无需改方法体。`@override` 注解可选不补（lint 不要求 implements 方法标注）。

- [ ] **Step 4: 子引擎装配 coordinator**

`sub_engine_bootstrap.dart` 四处改动：

① import 区，在 `sub_data_plane_port.dart` import 之后插入（保持 data→presence→shell 字母序）：

```dart
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
```

② dataPort 声明（L67-69）之后插入：

```dart
  // 账号面 presence 通道与数据面同生命周期：仅在有主窗 id 时启用
  final SubPresencePort? presencePort = dataPort == null
      ? null
      : DmwSubPresencePort(args.mainWindowId);
```

③ 「标签壳」整段（L110-119）替换为：

```dart
  // —— 标签壳（无首页、无 presence 网关）——
  Get.put<RoomControllerRegistry>(GetxRoomControllerRegistry(),
      permanent: true);

  // 子端 presence 协调者：必须先于 TabStore（批量关闭经它整批释放）、
  // 先于 store.open（控制器 onInit 即发 pr_register，T11）就位
  final IpcPresenceCoordinator? presenceCoordinator = presencePort == null
      ? null
      : Get.put(
          IpcPresenceCoordinator(
            windowId: self.windowId,
            port: presencePort,
            resolveTarget: (tabId) => Get.find<RoomControllerRegistry>()
                .controllerForTabId(tabId),
            accounts: Get.find<DouyinAccountService>(),
          ),
          permanent: true,
        );

  final store = Get.put<TabStore>(
    TabStore(
      registry: Get.find<RoomControllerRegistry>(),
      hasHome: false,
      presenceGateway: presenceCoordinator,
    ),
    permanent: true,
  );
```

④ 总 handler（L134-153）在 `DataPlaneProtocol.mChanged` case 之后、`'focus_tab'` case 之前插入：

```dart
      case PresenceProtocol.mApplyEnter:
      case PresenceProtocol.mApplyYield:
      case PresenceProtocol.mApplySuspended:
        // coordinator 为 null（无主窗的独立子窗）时 await null → 返回 null
        return await presenceCoordinator?.handleCall(
            call.method, call.arguments);
```

注意：
- `resolveTarget` 闭包返回 `LiveRoomController?`，Step 3 后其即 `PresenceApplyTarget?`，协变合法，不要加显式 cast。
- 不注册 `MainPresenceService`/网关，不挂第二个 method handler；子引擎总 handler 仍是 `self.setWindowMethodHandler` 这唯一槽位。

- [ ] **Step 5: 门禁（接线任务，必须 build）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。重点确认 5 个 fake 文件无 "Missing concrete implementation"。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿（234 + 前序新增）。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功。
- 静态核验：
  - `grep -n "MainPresenceService\\|DouyinPresenceGateway" lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart` 无匹配（子引擎不装主端类）。
  - `grep -rn "setWindowMethodHandler" lib/app/multiwindow/presence/ lib/app/multiwindow/bootstrap/` 仅 bootstrap 既有的唯一 `self.setWindowMethodHandler` 一处。

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/shell/room_controller_registry.dart \
  simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart \
  simple_live_app/lib/modules/live_room/live_room_controller.dart \
  simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart \
  simple_live_app/test/tab_store_test.dart \
  simple_live_app/test/multiwindow/window_open_service_test.dart \
  simple_live_app/test/multiwindow/sub_data_plane_client_test.dart \
  simple_live_app/test/multiwindow/main_presence_service_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 子引擎装配 presence 协调者并扩展 tabId 控制器解析

RoomControllerRegistry 增 controllerForTabId；LiveRoomController
implements PresenceApplyTarget（四方法已在）；子引擎 bootstrap 仅在有
主窗时创建 DmwSubPresencePort 与 IpcPresenceCoordinator（permanent），
TabStore 批量关闭改道 coordinator，总 handler 增三 apply case，
不重挂 handler、不装主端服务。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: 控制器子窗 presence 绑定与子窗入口收口

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（import ×2、getter ×2、onInit 绑定段、enterAsAccount 登录门、handleKeyboardKey 守卫、showDanmakuInputDialog 守卫、showDanmakuLoginDialog 子窗分支、guardActionEnabled 析取、bindSubWindowPresence + presenceClaimArgs）
- Test: `simple_live_app/test/sub_window_presence_controller_test.dart`（新建，3 例）

**Interfaces:**
- Consumes:
  - Task 9 `IpcPresenceCoordinator`（Get 注册，permanent）：`registerRemoteTab({tabId, siteId, roomId, shareUrl})`、`clientForTab({tabId, required PresenceClaimArgs Function() args}) → PresenceClient`；Task 9 `PresenceClaimArgs({roomId, shareUrl, guardRoomId, guardWebRid, guardExtra})`。
  - Task 1 控制器已有：字段 `PresenceClient? _presenceClient`、`debugBindPresenceClient`、`_doEnterViaGateway(PresenceClient)`、`presenceFailureText`、发送改道（本任务不碰发送路径）。
  - Task 4 `PresenceProtocol.decodeRegister/decodeClaim/encodeClaimOk/mClaim/mRegister`。
  - `MultiWindowRole.isSubWindow`（静态可变 bool，`app/multiwindow/window/window_role.dart`）；`Utils.showMessageDialog(content, {title, confirm})`（单确认键，返回 bool）；`Platform.isWindows`（flutter test 在 Windows 主机执行恒 true）。
- Produces（T12 不消费；T13 门禁核验）：
  - `bool bindSubWindowPresence()`（公共接线入口，onInit 与测试共用，对齐既有 `bindPresenceGateway` 形态）；`PresenceClaimArgs presenceClaimArgs()`（public，args tear-off）。
  - 子窗抖音标签 onInit 后持有 IPC client；onClose 既有 `_leaveDouyinPresence(unconditional: true)` → `client.release()` 自动经 IPC 释放，本任务不新增关闭路径。
- 边界：子窗弹幕发送 UI 仍关闭（toast 拦截，M5 移除）；bili/huya/非抖音路径一行不动；无 tabId 路径一行不动。

- [ ] **Step 1: 写失败测试**

新建 `simple_live_app/test/sub_window_presence_controller_test.dart`，逐字：

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeDanmaku extends LiveDanmaku {
  @override
  Future<void> start(dynamic args) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<DanmakuSendResult> sendMessage(String message) async =>
      DanmakuSendResult(success: true);
}

class _Site extends DouyinSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();
  @override
  LiveDanmaku getDanmaku() => danmaku;
  LiveRoomDetail guestDetail() => LiveRoomDetail(
        roomId: '111',
        title: 't',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 1,
        status: true,
        url: 'https://live.douyin.com/111',
        danmakuData: const DouyinDanmakuArgs(
          webRid: '111',
          roomId: 'room_111',
          userId: 'uid',
          cookie: 'ttwid=guest',
        ),
      );
  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async =>
      guestDetail();
}

class _Guard extends GuardServerService {
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  bool get configured => false;
}

class _LoggedOutAccount extends DouyinAccountService {
  @override
  RxBool get logined => false.obs;
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _FakePort implements SubPresencePort {
  final List<(String, Object?)> calls = [];
  Object? claimResult;
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (method == PresenceProtocol.mClaim) {
      return claimResult ?? PresenceProtocol.encodeClaimOk();
    }
    return null;
  }
}

void main() {
  setUp(() {
    MultiWindowRole.isSubWindow = true;
  });

  tearDown(() {
    MultiWindowRole.isSubWindow = false;
    Get.reset();
  });

  LiveRoomController makeController({String tabId = 't1'}) {
    final site = _Site();
    final c = LiveRoomController(
      pSite: Site(id: Constant.kDouyin, name: '抖音', logo: '', liveSite: site),
      pRoomId: '111',
      pShareUrl: 'https://live.douyin.com/111',
      tabId: tabId,
    );
    c.detail.value = site.guestDetail();
    return c;
  }

  IpcPresenceCoordinator putCoordinator(_FakePort port) {
    Get.put<GuardServerService>(_Guard(), permanent: true);
    Get.put<DouyinAccountService>(_LoggedOutAccount(), permanent: true);
    return Get.put<IpcPresenceCoordinator>(
      IpcPresenceCoordinator(
        windowId: 'w1',
        port: port,
        resolveTarget: (_) => null,
        accounts: Get.find<DouyinAccountService>(),
      ),
      permanent: true,
    );
  }

  test('子窗绑定：pr_register 建索引；enterAsAccount 跳过本地登录门走 IPC claim',
      () async {
    final port = _FakePort();
    putCoordinator(port);
    final c = makeController();

    expect(c.bindSubWindowPresence(), isTrue);
    // register 为 unawaited best-effort，排空一轮微任务
    await Future<void>.delayed(Duration.zero);

    final register =
        PresenceProtocol.decodeRegister(port.calls.first.$2)!;
    expect(register.windowId, 'w1');
    expect(register.tabId, 't1');
    expect(register.siteId, Constant.kDouyin);
    expect(register.roomId, '111');
    expect(register.shareUrl, 'https://live.douyin.com/111');

    // 本地抖音登录态恒 false：子窗必须跳过 danmakuLogined 门直接 claim；
    // granted 后乐观置 account（不依赖主端 apply 回调）
    expect(await c.enterAsAccount(), isTrue);
    expect(c.presence.value, RoomPresence.account);

    final claimCall = PresenceProtocol.decodeClaim(
      port.calls.firstWhere((c) => c.$1 == PresenceProtocol.mClaim).$2,
    )!;
    expect(claimCall.windowId, 'w1');
    expect(claimCall.tabId, 't1');
    expect(claimCall.roomId, '111');
    expect(claimCall.shareUrl, 'https://live.douyin.com/111');
    expect(claimCall.guardRoomId, 'room_111',
        reason: 'guard 参数 claim 当刻从详情读取');
    expect(claimCall.guardWebRid, '111');
  });

  testWidgets('子窗入口收口：输入与全屏回车只 toast；登录提示为单确认框不导航',
      (tester) async {
    putCoordinator(_FakePort());
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    final c = makeController();

    await c.showDanmakuInputDialog();
    await tester.pump();
    expect(Get.isDialogOpen, isNot(true), reason: '不弹输入框/登录框');
    expect(find.text('请在主窗口发送弹幕'), findsOneWidget);

    c.fullScreenState.value = true;
    c.handleKeyboardKey(const KeyDownEvent(
      logicalKey: LogicalKeyboardKey.enter,
      physicalKey: PhysicalKeyboardKey.enter,
    ));
    await tester.pump();
    expect(Get.isDialogOpen, isNot(true));
    expect(find.text('请在主窗口发送弹幕'), findsNWidgets(2));

    await c.showDanmakuLoginDialog();
    await tester.pump();
    expect(
      find.text('子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务'),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsOneWidget,
        reason: '单确认键，无取消键、不导航账号管理');
    expect(find.text('登录后才能发送弹幕，是否前往账号管理？'), findsNothing);
    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(Get.isDialogOpen, isNot(true));

    // 冲掉 SmartDialog toast 的自动关闭 Timer，避免 pending timer
    await tester.pump(const Duration(seconds: 3));
  });

  test('guardActionEnabled 子窗抖音恒可见；非子窗不绑定 IPC 通道', () {
    final port = _FakePort();
    putCoordinator(port);
    final c = makeController();

    expect(c.guardActionEnabled, isTrue,
        reason: '子窗抖音未登录、guard 未配置仍恒可见');

    MultiWindowRole.isSubWindow = false;
    expect(c.guardActionEnabled, isFalse);
    expect(c.bindSubWindowPresence(), isFalse,
        reason: '非子窗不绑定 IPC presence 通道');
    expect(port.calls, isEmpty);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run（cwd=simple_live_app）：
`C:/tools/flutter347/flutter/bin/flutter.bat test test/sub_window_presence_controller_test.dart`
Expected：编译失败——`The method 'bindSubWindowPresence' isn't defined`、`presenceClaimArgs` 未定义（Step 3 后转绿）。

- [ ] **Step 3: 生产改动**

`simple_live_app/lib/modules/live_room/live_room_controller.dart`：

(a) import 区，Task 10 所加 `presence/ipc/presence_apply_target.dart` 之前按字母序插入一行，并在 multiwindow import 区末（`shell/tab_store.dart` 之后）加 window_role：

```dart
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
```

```dart
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
```

(b) Task 1 的 `debugBindPresenceClient` 之后新增两个 getter 与两个接线方法：

```dart
  /// 子窗弹幕发送 UI 本里程碑不开放（通道已铺好，输入 UI 留 M5）
  bool get _isSubWindow =>
      Platform.isWindows && MultiWindowRole.isSubWindow;

  /// 子窗抖音标签：借用主窗登录身份参与 presence
  bool get _isSubWindowDouyin =>
      _isSubWindow && site.id == Constant.kDouyin;

  /// 子引擎 presence 接线入口（onInit 与测试共用）：向主端登记死亡对账
  /// 索引并持有 per-tab IPC client。返回 true 表示已走子端通道，
  /// 调用方不再尝试本地网关绑定（子引擎不注册网关）。
  bool bindSubWindowPresence() {
    if (!_isSubWindowDouyin ||
        tabId == null ||
        !Get.isRegistered<IpcPresenceCoordinator>()) {
      return false;
    }
    final coordinator = Get.find<IpcPresenceCoordinator>();
    // best-effort：主窗不可达不阻塞子端进房（主窗关闭=整个应用退出）
    unawaited(coordinator.registerRemoteTab(
      tabId: tabId!,
      siteId: site.id,
      roomId: roomId,
      shareUrl: shareUrl,
    ));
    _presenceClient = coordinator.clientForTab(
      tabId: tabId!,
      args: presenceClaimArgs,
    );
    return true;
  }

  /// claim 当刻读取的进房参数：guard 房间标识随游客详情刷新可能变化
  PresenceClaimArgs presenceClaimArgs() => PresenceClaimArgs(
        roomId: roomId,
        shareUrl: shareUrl,
        guardRoomId: _guardRoomId,
        guardWebRid: _guardWebRid,
        guardExtra: Map<String, Object?>.from(_guardExtraArgs()),
      );
```

（`unawaited` 来自文件已有的 `dart:async` import；`Platform` 来自已有的 `dart:io`。）

(c) onInit 末尾的网关绑定段：

```dart
    final gateway = _resolveGateway();
    if (gateway != null) {
      bindPresenceGateway(gateway);
    }
```

替换为：

```dart
    // 子引擎抖音标签绑 IPC presence 通道；主窗/Android 维持本地网关直连
    if (!bindSubWindowPresence()) {
      final gateway = _resolveGateway();
      if (gateway != null) {
        bindPresenceGateway(gateway);
      }
    }
```

(d) `enterAsAccount` 登录门：

```dart
    if (!danmakuLogined) {
      await showDanmakuLoginDialog();
      return false;
    }
```

替换为：

```dart
    // 子窗抖音本地恒未登录：借用主窗身份直接 claim，失败文案由回执承接
    if (!danmakuLogined && !_isSubWindowDouyin) {
      await showDanmakuLoginDialog();
      return false;
    }
```

(e) `handleKeyboardKey` 回车分支：

```dart
      showDanmakuInputDialog();
      return;
```

替换为：

```dart
      if (_isSubWindow) {
        SmartDialog.showToast('请在主窗口发送弹幕');
        return;
      }
      showDanmakuInputDialog();
      return;
```

(f) `showDanmakuInputDialog` 首行：

```dart
  Future<void> showDanmakuInputDialog() async {
    if (!danmakuLogined) {
```

替换为：

```dart
  Future<void> showDanmakuInputDialog() async {
    if (_isSubWindow) {
      SmartDialog.showToast('请在主窗口发送弹幕');
      return;
    }
    if (!danmakuLogined) {
```

(g) `showDanmakuLoginDialog` 首行插入子窗分支：

```dart
  Future<void> showDanmakuLoginDialog() async {
    if (_isSubWindowDouyin) {
      // 子窗不提供登录入口、不导航账号管理（spec §6.6.2）
      await Utils.showMessageDialog(
        '子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务',
        title: '未登录',
      );
      return;
    }
    var result = await Utils.showAlertDialog(
      "登录后才能发送弹幕，是否前往账号管理？",
      title: "未登录",
    );
    if (result) {
      Get.toNamed(RoutePath.kSettingsAccount);
    }
  }
```

(h) `guardActionEnabled`：

```dart
  bool get guardActionEnabled =>
      (GuardServerService.instance.configured &&
          (site.id == "douyin" || site.id == "bilibili") &&
          danmakuLogined) ||
      _isSubWindowDouyin;
```

- [ ] **Step 4: 跑新测试确认通过**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/sub_window_presence_controller_test.dart`
Expected：3 例全绿。若 toast 用例报 pending timer，确认末尾 `pump(const Duration(seconds: 3))` 在位（smart_dialog toast 默认 1.5s 自动关闭）。

- [ ] **Step 5: 全量门禁**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- 静态核验：
  - `grep -n "Get.toNamed" lib/modules/live_room/live_room_controller.dart` 中 kSettingsAccount 导航仍只在 showDanmakuLoginDialog 主窗分支（子窗分支提前 return）。
  - `grep -cn "MultiWindowRole" lib/modules/live_room/live_room_controller.dart` 恰为 2（1 行 import + `_isSubWindow` getter 内 1 处引用）；所有子窗判断必须经 `_isSubWindow`/`_isSubWindowDouyin` 两个 getter，业务方法中不得散落 `MultiWindowRole.isSubWindow`。

- [ ] **Step 6: Commit**

```bash
git add simple_live_app/lib/modules/live_room/live_room_controller.dart \
  simple_live_app/test/sub_window_presence_controller_test.dart
git commit -m "$(cat <<'EOF'
feat(presence): 子窗抖音标签绑定 IPC presence 并收口子窗登录与发送入口

onInit 子窗抖音标签向 coordinator 登记 pr_register 并持有 per-tab IPC
client（claim 参数当刻快照）；enterAsAccount 跳过本地登录门直接借用
主窗身份 claim；弹幕输入入口（按钮/全屏回车）toast 拦截，未登录提示
改单确认框不导航；guardActionEnabled 子窗抖音恒可见。主窗/Android/
bili/huya/无 tabId 路径行为不变。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: SubWindowBlockedPage 子窗深路由防御包装

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/shell/sub_window_blocked_page.dart`
- Modify: `simple_live_app/lib/routes/app_pages.dart`（import + 4 条路由 page builder 包装）
- Test: `simple_live_app/test/multiwindow/sub_window_blocked_page_test.dart`（新建，2 例）

**Interfaces:**
- Consumes: `MultiWindowRole.isSubWindow`（静态 bool）；4 条路由既有 const page：`AccountPage`、`WebLoginPage`、`RemoteSyncWebDAVPage`、`OtherSettingsPage`（app_pages.dart L228/L252/L306/L321）。
- Produces: `SubWindowBlockedPage({required Widget child})`——子窗模式渲染拦截 Scaffold 且**不构建 child**；主窗模式直接返回 child。
- 纵深防御（spec §6.6.5）：不依赖 Task 11 的控制器入口收口；GetPage 的 binding 维持原样（子窗服务集下这些 controller 即使被 put 也无凭据可读，页面操作面已被拦截）。

- [ ] **Step 1: 写失败测试**

新建 `simple_live_app/test/multiwindow/sub_window_blocked_page_test.dart`，逐字：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/sub_window_blocked_page.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';

class _TaggedPage extends StatelessWidget {
  const _TaggedPage({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => Scaffold(body: Text(text));
}

void main() {
  tearDown(() => MultiWindowRole.isSubWindow = false);

  testWidgets('子窗：显示拦截文案与返回键，不构建子页', (tester) async {
    MultiWindowRole.isSubWindow = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: SubWindowBlockedPage(child: _TaggedPage(text: 'SECRET_CHILD')),
      ),
    );
    expect(find.text('该功能仅可在主窗口使用'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    expect(find.text('SECRET_CHILD'), findsNothing,
        reason: '子页在子窗模式不得构建');
  });

  testWidgets('主窗：透传子页', (tester) async {
    MultiWindowRole.isSubWindow = false;
    await tester.pumpWidget(
      const MaterialApp(
        home: SubWindowBlockedPage(child: _TaggedPage(text: 'SECRET_CHILD')),
      ),
    );
    expect(find.text('该功能仅可在主窗口使用'), findsNothing);
    expect(find.text('SECRET_CHILD'), findsOneWidget);
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run（cwd=simple_live_app）：
`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_window_blocked_page_test.dart`
Expected：编译失败——`URI doesn't exist ... sub_window_blocked_page.dart`。

- [ ] **Step 3: 实现 SubWindowBlockedPage**

新建 `simple_live_app/lib/app/multiwindow/shell/sub_window_blocked_page.dart`，逐字：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';

/// 子窗深路由防御包装：子窗模式渲染拦截页（AppBar 返回 + 居中提示、
/// 不构建子页），主窗模式透传。包装账号设置 / Web 登录 / 其他设置 /
/// WebDAV 等凭据与全局设置路由（spec §6.6.5，纵深防御）。
class SubWindowBlockedPage extends StatelessWidget {
  const SubWindowBlockedPage({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || !MultiWindowRole.isSubWindow) {
      return child;
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back<void>(),
        ),
      ),
      body: const Center(
        child: Text('该功能仅可在主窗口使用'),
      ),
    );
  }
}
```

- [ ] **Step 4: 跑测试确认通过**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_window_blocked_page_test.dart`
Expected：2 例全绿。

- [ ] **Step 5: 包装 4 条路由**

`simple_live_app/lib/routes/app_pages.dart`：

(a) import 区（multiwindow shell 既有 import 旁）加：

```dart
import 'package:simple_live_app/app/multiwindow/shell/sub_window_blocked_page.dart';
```

(b) 四处 page builder 逐字替换（binding 一律不动）：

L228：

```dart
      page: () => const SubWindowBlockedPage(child: AccountPage()),
```

L252：

```dart
      page: () => const SubWindowBlockedPage(child: WebLoginPage()),
```

L306：

```dart
      page: () => const SubWindowBlockedPage(child: RemoteSyncWebDAVPage()),
```

L321：

```dart
      page: () => const SubWindowBlockedPage(child: OtherSettingsPage()),
```

（只包 spec 指定的 4 条；`kBiliBiliWebLogin`/`kBiliBiliQRLogin`/`kRemoteSyncWebDavConfig`/`kSettingsGuardServer` 等本任务不包。）

- [ ] **Step 6: 门禁（路由表接线，必须 build）**

Run（cwd=simple_live_app）：
- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` → 相对基线零新增。
- `C:/tools/flutter347/flutter/bin/flutter.bat test` → 全绿。
- `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` → 成功。
- 静态核验：`grep -n "SubWindowBlockedPage" lib/routes/app_pages.dart` 恰 5 行（1 import + 4 builder）。

- [ ] **Step 7: Commit**

```bash
git add simple_live_app/lib/app/multiwindow/shell/sub_window_blocked_page.dart \
  simple_live_app/lib/routes/app_pages.dart \
  simple_live_app/test/multiwindow/sub_window_blocked_page_test.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 子窗账号/登录/设置/WebDAV 深路由防御性拦截

新增 SubWindowBlockedPage：子窗模式渲染返回+居中提示且不构建子页，
主窗透传；包装 kSettingsAccount/kWebLogin/kRemoteSyncWebDav/
kSettingsOther 四条路由，作为控制器入口收口之外的纵深防御。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: 里程碑收口门禁（无生产代码改动）

**Files:** 无（纯验收；如核验中发现缺陷，回到对应任务修复，不在本任务内顺手改代码）

**Interfaces:** 不消费、不产出。

- [ ] **Step 1: 静态分析**

Run（cwd=simple_live_app）：
`C:/tools/flutter347/flutter/bin/flutter.bat analyze`
Expected：零 error；warning/info 相对开工基线（2 warning + 20 info，共 22 条，Task 1 开工前已记录）零新增。若有新增，逐条判定：简报代码触发的冗余 import/const 等可就地删除并在终审报告记录为合法偏离，其余必须修掉。

- [ ] **Step 2: 全量测试并记录计数**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected：全绿。基线 234 例；本计划新增约 40 例（协议 4 + 网关/写动作/健壮性约 15 + MainPresenceService 6 + coordinator 6 + 数据面委托 1 + reconcile 1 + 借用 cookie 约 3 + 控制器子窗 3 + 路由包装 2，含 2 例为既有断言改写而非净增），全量期望在 272 例上下；以实际输出为准，把最终数记入终审报告。无 pending timer 警告（fakeAsync 用例与 toast 用例已各自排空）。

- [ ] **Step 3: Windows debug 构建**

Run：`C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`
Expected：成功。

- [ ] **Step 4: 架构红线静态核验**

仓库根 = git 根（`D:/project/dart_simple_live`）；fork base 用 `my_dev` 的 merge-base。逐条运行并核对期望：

1. dmw 单 handler 槽位——presence 目录零注册，全仓生产注册点仅两处：

```bash
grep -rn "setWindowMethodHandler" simple_live_app/lib --include=*.dart
```

期望：仅 `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`（主窗，onInit 经 mainController）与 `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`（子引擎 self）各一处；`simple_live_app/lib/app/multiwindow/presence/` 下无匹配。

2. 前缀隔离——dp_ 只被数据面服务解析、pr_ 只被 presence 两类解析：

```bash
grep -rn "DataPlaneProtocol\." simple_live_app/lib/app/multiwindow/presence/ ; grep -rn "PresenceProtocol\." simple_live_app/lib/app/multiwindow/data/
```

期望：两条均无匹配（两服务互不解析对方方法；唯一交点是 MainDataPlaneService default 分支一行 `unhandledMethodHandler` 委托）。

3. 凭据流——sessionid/cookie 不进 dp_ 通道、不进日志：

```bash
grep -rn "cookie" simple_live_app/lib/app/multiwindow/data/
grep -rn "sessionid" simple_live_app/lib/app/multiwindow/presence/ipc/
```

期望：data/ 下仅 `DataPlaneProtocol` 既有敏感键清单相关命中（DouyinLoginCookie 等键名字符串，无值流）；ipc/ 下生产代码无 `sessionid` 字样（仅协议文件脱敏占位逻辑与测试出现），cookie 值仅存在于 `pr_apply_enter` 载荷与 `setBorrowedLoginCookie` 写入点。

4. 非 Windows / 非子窗不注册 presence IPC：

```bash
grep -rn "MainPresenceService\|IpcPresenceCoordinator" simple_live_app/lib --include=*.dart
```

期望：`MainPresenceService` 仅出现在自身文件与 `routes/app_pages.dart` 的 `Platform.isWindows && !MultiWindowRole.isSubWindow && DmwSubWindowPort.mainWindowId != null` 守卫块；`IpcPresenceCoordinator` 仅出现在自身/测试接缝文件与 `sub_engine_bootstrap.dart`（该文件只在 main.dart 子引擎分支执行）。

5. Android / TV 零改动：

```bash
git diff --stat $(git merge-base my_dev HEAD)...HEAD -- simple_live_tv_app/ simple_live_console/ simple_live_core/
```

期望：无输出。app 侧非 multiwindow 生产改动只允许触及：`lib/modules/live_room/live_room_controller.dart`、`lib/routes/app_pages.dart`、`lib/services/douyin_account_service.dart` 三个文件：

```bash
git diff --name-only $(git merge-base my_dev HEAD)...HEAD -- simple_live_app/lib | grep -v "app/multiwindow/"
```

期望输出恰为上述三行（顺序不限）；无其他文件即通过。

6. 子窗发送 UI 仍关闭、bili/huya 发送路径未改：

```bash
grep -n "请在主窗口发送弹幕" simple_live_app/lib/modules/live_room/live_room_controller.dart
grep -n "sendDanmakuAsHolder\|sendActionAsHolder\|PresenceClient" simple_live_app/lib/services/guard_server_service.dart
```

期望：第一条恰 2 处（键盘回车分支 + showDanmakuInputDialog 首行）；第二条无匹配（guard 服务无 presence 概念，bili/huya 直连路径不变）。

- [ ] **Step 5: 记录验收结论，不产 commit**

在 SDD ledger（或终审派单材料）记录：analyze 基线对比数、`flutter test` 实际用例总数、build 结果、Step 4 六条核验的实际输出。随后进入整支终审（opus）与 spec §11 GUI 清单交接；本任务不创建提交。
