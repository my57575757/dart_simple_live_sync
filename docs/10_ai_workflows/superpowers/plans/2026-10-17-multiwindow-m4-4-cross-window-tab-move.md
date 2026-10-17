# M4-4 标签跨窗迁移（菜单先行 + presence 无缝 handoff）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 多窗口下，直播间标签可经右键菜单在主窗口与子窗口之间（新窗口 / 主窗口 / 已存在子窗口）迁移，tabId 保持不变；抖音账号态标签迁移全程不发 exitRoom/enterRoom、心跳会话不断，落地后自动在新窗复刻账号态。

**Architecture:** 唯一编排者是主引擎 `WindowOpenService`；presence 权威状态留在主引擎 `DouyinPresenceGateway`，迁移期间仲裁栈/holder/accountId/_ready/服务端会话/心跳 Timer 全部不动，只替换 tabId 对应的 `DouyinPresenceTab` 端口（本地适配器 ↔ RemotePresenceTab），并经新端口 `applyReentered(缓存 status)` 复刻账号态。新协议族 `mw_`（窗口管理）与 dp_/pr_ 物理隔离；新窗/已存在子窗的标签落地经「预定 tabId + pr_register 命中 handoff」驱动 rehome；目标主窗经 `rehomeLocal` 显式驱动。源标签以 closeForMove 关闭并抑制控制器 onClose 的 presence leave。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4（固定 `C:/tools/flutter347/flutter/bin/flutter.bat`）、GetX 4.7.3、desktop_multi_window 0.3.1（windowId 为 String、单 handler 槽位、handler 收不到来源 windowId、同引擎 FIFO）、Hive、fake_async、uuid、flutter_smart_dialog。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-17-multiwindow-m4-4-cross-window-tab-move-design.md`（spec 是权威；本计划是其论证，冲突以 spec 为准，记入 ledger Ruling）。

## Global Constraints

- 始终简体中文回复与撰写注释/文案/commit。
- Flutter 一律固定 SDK：`C:/tools/flutter347/flutter/bin/flutter.bat`（3.47.5/Dart 3.13.4，AGENTS.md 的 3.38 不作为依据）。flutter cwd=`D:\project\dart_simple_live\simple_live_app`；git 根在上一级 `D:\project\dart_simple_live`（路径带 `simple_live_app/` 前缀）。
- 每任务门禁：`C:/tools/flutter347/flutter/bin/flutter.bat analyze` 相对基线零新增（基线 **22 条 = 2 warning + 20 info**）；全量 `C:/tools/flutter347/flutter/bin/flutter.bat test` 绿（**基线 280**，只增不减）；接线任务（T7/T8）额外 `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` 成功。
- 新文件一律 `package:simple_live_app/...` 绝对 import。
- dmw 事实：windowId 是 String；每引擎单 handler 槽位，**绝不重挂**，只许委托；主端 handler 收不到来源 windowId，子端每个载荷必带；同引擎调用同 task runner FIFO。
- Android/TV/首页零行为变化：无 tabId 路径一行不动；非 Windows 不注册 M4-4 任何新服务、不显示新菜单项；bili/huya 控制器发送直连不改。
- 凭据安全：`mw_` 协议**不含任何凭据字段**；cookie 仍只在 pr_apply_enter 内存载荷下行；sensitive keys 17 具名 + GuardAccountId_ 前缀；开窗快照剥离逻辑不变。
- 执行者不得声称 GUI 已过；本计划 GUI 清单（spec §10）由用户本机执行。
- git：严禁 `git add -A`/`git add .`，只 add 精确路径；约 40 个无关存量脏文件（.idea/.opencode/generated_plugin_registrant/build reports/simple_live_tv_app gradle 等，含 test/build 重生）不碰、不还原、不清理；commit message 简体中文，结尾空行 + `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`；不 push、不合并。
- 测试 Timer 卫生：普通测试涉及 Timer 例尾排空或 `stopHeartbeatForTesting()`；fakeAsync 用例结束前 elapse 排空，不得遗留悬挂 Timer。
- 站点 id 字面量：`bilibili`/`douyin`/`douyu`/`huya`/`twitch`；抖音判定优先 `Constant.kDouyin`。
- 逐字代码若触发 lint，合法偏离仅限删冗余 import/补 const/去不可 const 的 const，并在任务报告「偏离记录」写明。
- 子窗弹幕发送 UI、bili/huya/douyu/twitch 子窗写动作仍留 M5，本计划不放开。
- pr_detach 协议/网关/arbiter/既有单测保留不删，本计划无生产调用点（spec §11 Ruling）。

## File Structure

新增（均在 `simple_live_app/lib/`）：

| 文件 | 职责 | 任务 |
|---|---|---|
| `app/multiwindow/window/window_control_protocol.dart` | mw_ 常量/线值/四组编解码/MoveResult | T1 |
| `app/multiwindow/window/sub_window_control_port.dart` | 子→主 mw_ 通道抽象 + dmw 实现 | T6 |
| `app/multiwindow/window/sub_window_control_service.dart` | 子端迁移服务：列表/请求/接收 open/close | T6 |
| `app/multiwindow/window/unhandled_method_router.dart` | pr_/mw_ 前缀路由闭包（可单测） | T7 |
| `app/multiwindow/shell/tab_move_menu.dart` | 菜单宿主决策/条目构建/value 编解码纯函数（可单测） | T8 |

修改：

| 文件 | 改动概要 | 任务 |
|---|---|---|
| `presence/presence_claimant.dart` | DouyinPresenceTab 加 `applyReentered(status)` | T2 |
| `presence/douyin_presence_gateway.dart` | `_lastEnterStatus`、`_pendingApplyReplay`、`rehome`、`isTrackedTab`、`currentGuardArgsFor`、claim 短路补放、离场清理 | T2 |
| `presence/ipc/remote_presence_tab.dart` | `applyReentered` | T2 |
| `modules/live_room/live_room_controller.dart` | 适配器 `applyReentered`+`reenterAfterWindowMove`；`_movedAway` 抑制 onClose leave | T2/T4 |
| `presence/ipc/main_presence_service.dart` | handoff 表/超时/register 改造/rehomeLocal/死亡失败结算 | T3（implements 窄接口在 T7） |
| `shell/tab_store.dart` | open 外部 tabId；closeForMove | T4 |
| `window/window_args.dart` | RoomTabArg.tabId 可空 | T4 |
| `bootstrap/sub_engine_bootstrap.dart` | tabId 透传；control port/service 装配；handler 两 case | T4/T6 |
| `window/window_registry.dart` | addChildTab/removeChildTab/moveChildTab/ordinal/mainWindowId 已有 | T5 |
| `window/window_open_service.dart` | moveTabToWindow 编排、handleWindowCall、listMoveTargets、presenceService 后绑、删 moveTabToNewWindow | T7 |
| `routes/app_pages.dart` | 路由闭包接线；MPS 后绑 WOS | T7 |
| `shell/tab_strip.dart` | 菜单两入口（主/子窗） | T8 |

测试新增：`test/multiwindow/window_control_protocol_test.dart`、`test/multiwindow/gateway_rehome_test.dart`、`test/multiwindow/main_presence_handoff_test.dart`、`test/multiwindow/window_registry_tabs_test.dart`、`test/multiwindow/sub_window_control_service_test.dart`、`test/multiwindow/window_move_orchestration_test.dart`、`test/multiwindow/unhandled_method_router_test.dart`、`test/tab_move_menu_test.dart`、`test/multiwindow/tab_strip_move_menu_test.dart`；并修改既有测试（window_args_test、tab_store_test、main_presence_service_test、window_open_service_test、douyin_presence_gateway_test 的 FakeTab、sub_window_presence_controller_test）。

---

### Task 1: mw_ 窗口管理协议（常量/线值/编解码）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/window/window_control_protocol.dart`
- Test: `simple_live_app/test/multiwindow/window_control_protocol_test.dart`

**Interfaces:**
- Produces（后续任务消费，命名锁定）：
  - `class WindowControlProtocol`（私有构造）：方法名 `mRequestMove='mw_request_move'`、`mListWindows='mw_list_windows'`、`mOpenTab='mw_open_tab'`、`mCloseTab='mw_close_tab'`；线值 `targetNew='__new__'`、`targetMain='__main__'`。
  - call 类：`WindowMoveCall { final String sourceWindowId, tabId, siteId, roomId, shareUrl, target; }`；`OpenTabCall { final String tabId, siteId, roomId, shareUrl; final bool activate; }`；`CloseTabCall { final String tabId; }`；`WindowListEntry { final String id, label; }`；`class MoveResult { const MoveResult(this.ok, this.message); final bool ok; final String? message; }`（message 仅固定中文文案，禁止回显异常）。
  - 编解码：`encodeRequestMove(WindowMoveCall)`/`decodeRequestMove(Object?)`、`encodeOpenTab(OpenTabCall)`/`decodeOpenTab(Object?)`、`encodeCloseTab(CloseTabCall)`/`decodeCloseTab(Object?)`、`encodeWindowList(List<WindowListEntry>)`/`decodeWindowList(Object?)`、`encodeMoveResult(bool ok, {String? message})`/`decodeMoveResult(Object?)`。
- Consumes: 无（纯 Dart）。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/window_control_protocol_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

void main() {
  group('request_move', () {
    test('往返保留全部字段；shareUrl 允许空串', () {
      const c = WindowMoveCall(
        sourceWindowId: 'w2',
        tabId: 't1',
        siteId: 'douyin',
        roomId: 'r1',
        shareUrl: '',
        target: '__main__',
      );
      final d = WindowControlProtocol.decodeRequestMove(
          WindowControlProtocol.encodeRequestMove(c))!;
      expect(d.sourceWindowId, 'w2');
      expect(d.tabId, 't1');
      expect(d.siteId, 'douyin');
      expect(d.roomId, 'r1');
      expect(d.shareUrl, '');
      expect(d.target, '__main__');
    });

    test('非法载荷：非 Map / 缺字段 / 空串 / 错类型 → null', () {
      expect(WindowControlProtocol.decodeRequestMove(null), isNull);
      expect(WindowControlProtocol.decodeRequestMove('x'), isNull);
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': 'w2',
            'tabId': 't1',
            'siteId': 'douyin',
            'roomId': 'r1',
            // shareUrl 缺失
            'target': '__new__',
          }),
          isNull);
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': '',
            'tabId': 't1',
            'siteId': 'douyin',
            'roomId': 'r1',
            'shareUrl': '',
            'target': '__new__',
          }),
          isNull,
          reason: 'sourceWindowId 不得空串');
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': 'w2',
            'tabId': 1,
            'siteId': 'douyin',
            'roomId': 'r1',
            'shareUrl': '',
            'target': '__new__',
          }),
          isNull);
    });
  });

  group('open_tab / close_tab', () {
    test('open_tab 往返含 activate', () {
      const c = OpenTabCall(
        tabId: 't9',
        siteId: 'bilibili',
        roomId: '9',
        shareUrl: 'u',
        activate: false,
      );
      final d = WindowControlProtocol.decodeOpenTab(
          WindowControlProtocol.encodeOpenTab(c))!;
      expect(d.tabId, 't9');
      expect(d.siteId, 'bilibili');
      expect(d.activate, isFalse);
    });

    test('open_tab activate 错类型/缺失 → null；close_tab 空 id → null', () {
      expect(
          WindowControlProtocol.decodeOpenTab({
            'tabId': 't',
            'siteId': 'douyin',
            'roomId': 'r',
            'shareUrl': '',
          }),
          isNull);
      expect(WindowControlProtocol.decodeCloseTab({'tabId': ''}), isNull);
      expect(WindowControlProtocol.decodeCloseTab(null), isNull);
    });

    test('close_tab 往返', () {
      final d = WindowControlProtocol.decodeCloseTab(
          WindowControlProtocol.encodeCloseTab(
              const CloseTabCall(tabId: 'x')))!;
      expect(d.tabId, 'x');
    });
  });

  group('window list / move result', () {
    test('列表往返保序', () {
      const list = [
        WindowListEntry(id: '__main__', label: '主窗口'),
        WindowListEntry(id: 'w1', label: '直播间窗口 1'),
      ];
      final d = WindowControlProtocol.decodeWindowList(
          WindowControlProtocol.encodeWindowList(list))!;
      expect(d.map((e) => e.id), ['__main__', 'w1']);
      expect(d.map((e) => e.label), ['主窗口', '直播间窗口 1']);
    });

    test('列表非 List / 元素缺字段 → null', () {
      expect(WindowControlProtocol.decodeWindowList('x'), isNull);
      expect(
          WindowControlProtocol.decodeWindowList([
            {'id': 'w1'}
          ]),
          isNull);
    });

    test('move result 往返；失败缺省 message 允许', () {
      final ok = WindowControlProtocol.decodeMoveResult(
          WindowControlProtocol.encodeMoveResult(true))!;
      expect(ok.ok, isTrue);
      expect(ok.message, isNull);
      final fail = WindowControlProtocol.decodeMoveResult(
          WindowControlProtocol.encodeMoveResult(false,
              message: '目标窗口无响应'))!;
      expect(fail.ok, isFalse);
      expect(fail.message, '目标窗口无响应');
      expect(WindowControlProtocol.decodeMoveResult({'ok': 'x'}), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_control_protocol_test.dart`
Expected: 编译失败（uri 不存在）。

- [ ] **Step 3: 实现协议**

`simple_live_app/lib/app/multiwindow/window/window_control_protocol.dart`：

```dart
/// 窗口管理面 IPC 协议（mw_ 前缀）：标签跨窗迁移与窗口枚举。
/// 形态对齐 PresenceProtocol：私有构造、常量方法名/线值、显式 encode/decode、
/// 非法载荷返回 null。载荷全部 JSON 兼容；本协议不含任何凭据字段。
class WindowControlProtocol {
  WindowControlProtocol._();

  // ---- 方法名：子 → 主 ----
  static const String mRequestMove = 'mw_request_move';
  static const String mListWindows = 'mw_list_windows';

  // ---- 方法名：主 → 子 ----
  static const String mOpenTab = 'mw_open_tab';
  static const String mCloseTab = 'mw_close_tab';

  // ---- target 线值 ----
  static const String targetNew = '__new__';
  static const String targetMain = '__main__';

  static String? _nonEmptyStr(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  // ---- request_move ----

  static Map<String, Object?> encodeRequestMove(WindowMoveCall call) => {
        'sourceWindowId': call.sourceWindowId,
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'target': call.target,
      };

  static WindowMoveCall? decodeRequestMove(Object? args) {
    if (args is! Map) return null;
    final sourceWindowId = _nonEmptyStr(args, 'sourceWindowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final target = _nonEmptyStr(args, 'target');
    final shareUrl = args['shareUrl'];
    if (sourceWindowId == null ||
        tabId == null ||
        siteId == null ||
        roomId == null ||
        target == null ||
        shareUrl is! String) {
      return null;
    }
    return WindowMoveCall(
      sourceWindowId: sourceWindowId,
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
      target: target,
    );
  }

  // ---- open_tab ----

  static Map<String, Object?> encodeOpenTab(OpenTabCall call) => {
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'activate': call.activate,
      };

  static OpenTabCall? decodeOpenTab(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    final activate = args['activate'];
    if (tabId == null ||
        siteId == null ||
        roomId == null ||
        shareUrl is! String ||
        activate is! bool) {
      return null;
    }
    return OpenTabCall(
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
      activate: activate,
    );
  }

  // ---- close_tab ----

  static Map<String, Object?> encodeCloseTab(CloseTabCall call) =>
      {'tabId': call.tabId};

  static CloseTabCall? decodeCloseTab(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    if (tabId == null) return null;
    return CloseTabCall(tabId: tabId);
  }

  // ---- window list ----

  static List<Object?> encodeWindowList(List<WindowListEntry> entries) => [
        for (final e in entries)
          {'id': e.id, 'label': e.label},
      ];

  static List<WindowListEntry>? decodeWindowList(Object? args) {
    if (args is! List) return null;
    final out = <WindowListEntry>[];
    for (final raw in args) {
      if (raw is! Map) return null;
      final id = _nonEmptyStr(raw, 'id');
      final label = _nonEmptyStr(raw, 'label');
      if (id == null || label == null) return null;
      out.add(WindowListEntry(id: id, label: label));
    }
    return out;
  }

  // ---- move result ----

  static Map<String, Object?> encodeMoveResult(bool ok, {String? message}) => {
        'ok': ok,
        if (message != null) 'message': message,
      };

  static MoveResult? decodeMoveResult(Object? args) {
    if (args is! Map || args['ok'] is! bool) return null;
    final message = args['message'];
    if (message != null && message is! String) return null;
    return MoveResult(args['ok'] as bool, message as String?);
  }
}

class WindowMoveCall {
  const WindowMoveCall({
    required this.sourceWindowId,
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
    required this.target,
  });

  final String sourceWindowId;
  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
  final String target;
}

class OpenTabCall {
  const OpenTabCall({
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
    required this.activate,
  });

  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
  final bool activate;
}

class CloseTabCall {
  const CloseTabCall({required this.tabId});

  final String tabId;
}

class WindowListEntry {
  const WindowListEntry({required this.id, required this.label});

  final String id;
  final String label;
}

/// 迁移回执：message 仅允许固定中文文案，禁止回显异常对象。
class MoveResult {
  const MoveResult(this.ok, this.message);

  factory MoveResult.success() => const MoveResult(true, null);
  factory MoveResult.failure(String message) => MoveResult(false, message);

  final bool ok;
  final String? message;
}
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_control_protocol_test.dart`
Expected: 全绿。

- [ ] **Step 5: analyze + 全量测试 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（不超 22 基线）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（280 全绿 + 新增）。

```bash
git add simple_live_app/lib/app/multiwindow/window/window_control_protocol.dart simple_live_app/test/multiwindow/window_control_protocol_test.dart
git commit -m "feat(multiwindow): 新增 mw_ 标签跨窗迁移窗口管理协议

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 2: DouyinPresenceTab.applyReentered 与网关 rehome（无缝换端口）

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart`（接口加方法）
- Modify: `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/remote_presence_tab.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（控制器方法 + `_ControllerPresenceTab` 适配器）
- Modify: `simple_live_app/test/douyin_presence_gateway_test.dart`（FakeTab 补实现 + 新增 `rehome` 测试组；复用本文件 FakeGuard/FakeTab，不新建夹具文件）

**Interfaces:**
- Consumes: 无（T2 是 presence 层最底层；协议层 mw_ 与本任务无关）。
- Produces（T3 消费，命名锁定）：
  - `DouyinPresenceTab` 新增 `Future<void> applyReentered(Map<String, dynamic> guardStatus);`
  - `DouyinPresenceGateway` 新增：
    - `Future<void> rehome(String tabId, {DouyinPresenceTab? newPort})`
    - `bool isTrackedTab(String tabId)`
    - `({String roomId, String webRid, Map<String, Object?> extra})? currentGuardArgsFor(String tabId)`
  - 记录类型直接以 positional record 返回（无 typedef）。
- 全仓 `implements DouyinPresenceTab` 仅三处：`RemotePresenceTab`、`_ControllerPresenceTab`、gateway 测试里的 `FakeTab`，本任务全部改齐。`PresenceApplyTarget` 接口**不动**（控制器的 applyReentered 是具体类公开方法，无需 @override）。

- [ ] **Step 1: 写失败测试（追加到 gateway 测试文件末尾 main() 内）**

先在 `FakeTab` 中把 `applyThrows` 的作用域扩到 applyReentered，并新增记录字段（修改 `test/douyin_presence_gateway_test.dart` 的 FakeTab）：

```dart
  int reenteredOnlyCalls = 0;
  final reenteredStatusCalls = <Map<String, dynamic>>[];

  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    reenteredOnlyCalls++;
    reenteredStatusCalls.add(Map<String, dynamic>.from(guardStatus));
    if (applyThrows) throw StateError('reenter apply failed');
  }
```

然后在 `main()` 末尾追加测试组：

```dart
  group('rehome 跨窗换端口', () {
    test('holder+ready：零 enter/exit、新端口收 applyReentered（=进场 status）、'
        '心跳经新端口 guard 参数、holder/accountId 不变', () {
      fakeAsync((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(guard);
        addTearDown(gw.stopHeartbeatForTesting);
        final a = FakeTab('A', '111');

        expect(gw.isTrackedTab('A'), isFalse);
        expect(await gw.claim(a), isA<PresenceClaimResult>());
        // 上面 await 在 fakeAsync 中需要推进微任务
        async.flushMicrotasks();
        expect(guard.enters, ['acct1@room_111']);
        expect(gw.isTrackedTab('A'), isTrue);
        expect(gw.currentGuardArgsFor('A')?.roomId, 'room_111');

        final b = FakeTab('A', '222'); // 同 tabId、不同 guard 三元组
        await gw.rehome('A', newPort: b);
        async.flushMicrotasks();

        expect(guard.enters, ['acct1@room_111'], reason: 'rehome 不重走进场');
        expect(guard.exits, isEmpty, reason: 'rehome 不发 exit');
        expect(b.reenteredOnlyCalls, 1);
        expect(b.reenteredStatusCalls.single,
            {'joined': false, 'starGuard': false, 'badgeActive': true});
        expect(a.reenteredOnlyCalls, 0, reason: '旧端口不接收复刻');

        async.elapse(const Duration(seconds: 21));
        expect(guard.beats, ['acct1@room_222'],
            reason: '心跳 Timer 重挂到新端口，guard 参数取自新端口');
        expect(gw.holderTabId, 'A');
        expect(gw.currentGuardArgsFor('A')?.roomId, 'room_222');
      });
    });

    test('栈中非 holder：只换端口，不 apply、不动心跳', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b); // b 成为 holder，a 在栈中非 holder
      final a2 = FakeTab('A', '111');

      await gw.rehome('A', newPort: a2);

      expect(a2.reenteredOnlyCalls, 0);
      expect(guard.enters.length, 2);
    });

    test('suspended：换端口但不 apply，suspended 语义保留', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      guard.inRoomFalseBeats = 1;
      await Future<void>.delayed(const Duration(seconds: 21));
      expect(a.suspended, 1);

      final a2 = FakeTab('A', '111');
      await gw.rehome('A', newPort: a2);
      expect(a2.reenteredOnlyCalls, 0);
    });

    test('网关不跟踪的 tab：no-op，不绑定新端口', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final z = FakeTab('Z', '999');

      await gw.rehome('Z', newPort: z);

      expect(gw.isTrackedTab('Z'), isFalse);
      expect(z.reenteredOnlyCalls, 0);
    });

    test('newPort=null：不换端口，仅对现有 holder 重挂心跳+复刻', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      a.reenteredOnlyCalls = 0; // 清掉 claim 路径可能的计数（claim 不调它）

      await gw.rehome('A');

      expect(a.reenteredOnlyCalls, 1, reason: '主窗落地路径复刻一次');
      expect(guard.enters, ['acct1@room_111']);
      expect(guard.exits, isEmpty);
    });

    test('applyReentered 抛错：rehome 不抛、心跳已重挂；下次 claim 短路补放，'
        '成功后不再补', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final a = FakeTab('A', '111');
      await gw.claim(a);

      final b = FakeTab('A', '222');
      b.applyThrows = true;
      await gw.rehome('A', newPort: b); // 吞异常
      expect(b.reenteredOnlyCalls, 1);

      // claim 短路 granted + 补放一次（仍失败，保留待补）
      final r1 = await gw.claim(b);
      expect(r1.granted, isTrue, reason: 'holder+ready 短路，不重走进场');
      await Future<void>.delayed(Duration.zero);
      expect(b.reenteredOnlyCalls, 2);

      // 恢复后再 claim：补放成功
      b.applyThrows = false;
      await gw.claim(b);
      await Future<void>.delayed(Duration.zero);
      expect(b.reenteredOnlyCalls, 3);

      // 之后 claim 不再补放
      await gw.claim(b);
      await Future<void>.delayed(Duration.zero);
      expect(b.reenteredOnlyCalls, 3);
      expect(guard.enters, ['acct1@room_111'], reason: '全程无额外进场');
    });

    test('release 后 _lastEnterStatus 清除：同 tab 再 claim 为完整进场且再 rehome '
        '能复刻新 status', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      addTearDown(gw.stopHeartbeatForTesting);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      await gw.release('A');

      final a2 = FakeTab('A', '111');
      await gw.claim(a2); // release 后 ready 已清：完整进场
      expect(guard.enters.length, 2);
      a2.reenteredOnlyCalls = 0;
      await gw.rehome('A');
      expect(a2.reenteredOnlyCalls, 1, reason: '新进场 status 已重新缓存');
    });
  });
```

注意：
- `fakeAsync` 用例中不要 `await` gw 的 Future（fakeAsync 禁止真实异步穿过 zone 边界）——`await gw.claim(a)` 这类链上全是同步微任务时用 `await ... ; async.flushMicrotasks();` 的既有用法；若该风格在本组首条用例中编译/运行有困难，允许把首条用例改为**不用 fakeAsync**：用 `stopHeartbeatForTesting` + 反射式断言改为「rehome 后等待 0ms、断言 enters/exits/reentered/currentGuardArgs，Timer 重挂行为由 `currentGuardArgsFor` 已切换 + 既有心跳闭包 holder 校验测试间接覆盖」。这是允许的实现期偏离，必须在报告中写明；优先保留 fakeAsync 版本。
- `PresenceClaimResult` 已在该文件 import 链中（既有测试在用 `r.granted`）。

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/douyin_presence_gateway_test.dart`
Expected: 编译失败（applyReentered 未实现 / rehome 不存在）。

- [ ] **Step 3: 最小实现**

3a. `presence_claimant.dart`，在 `applyAccountEnter(...)` 之后加：

```dart
  /// 跨窗迁移落地：以最近一次进场 status 在新引擎复刻账号态（reentered:true）。
  /// 远端实现下发 pr_apply_enter（cookie 当刻读、不下发 accountDetail）；
  /// 本地实现自取账号详情后复用 applyAccountEnter。
  Future<void> applyReentered(Map<String, dynamic> guardStatus);
```

3b. `douyin_presence_gateway.dart`：

新增字段（与 `_ready` 同区）：

```dart
  /// 每次完整进场成功的 guard status：迁移复刻（applyReentered）用。
  /// release/detach/batch 随 tab 清除；rehome 保留（tabId 延续）。
  final Map<String, Map<String, Object?>> _lastEnterStatus = {};

  /// rehome 后尚未在新端口复刻成功的 tab：claim 短路分支补放一次。
  final Set<String> _pendingApplyReplay = <String>{};
```

`_claim` 两处改动：

短路分支改为：

```dart
    if (arbiter.holder == tab.tabId && _ready.contains(tab.tabId)) {
      if (_pendingApplyReplay.remove(tab.tabId)) {
        // best-effort，不阻塞 granted：失败由补放函数自行重新置位
        unawaited(_replayEnter(tab));
      }
      return const PresenceClaimResult.granted();
    }
```

在 `_accountIds[tab.tabId] = entered.accountId;` 之后加：

```dart
    _lastEnterStatus[tab.tabId] = Map<String, Object?>.from(entered.status);
```

`_applyFallback` 在 `_accountIds[fallbackId] = entered.accountId;` 后加：

```dart
    _lastEnterStatus[fallbackId] =
        Map<String, Object?>.from(entered.status);
```

`_remove`：在 `_ready.remove(tabId);` 同行区加两行：

```dart
    _lastEnterStatus.remove(tabId);
    _pendingApplyReplay.remove(tabId);
```

`_batchRelease` 的 for 循环内同样加这两行。

新增公开方法与私有实现（放在 `detach` 之后）：

```dart
  /// tabId 是否在网关有端口（含栈中非 holder、suspended；非抖音/纯游客 false）
  bool isTrackedTab(String tabId) => _tabs.containsKey(tabId);

  /// 当前端口缓存的 guard 三元组（主→子迁移时复制给新 RemotePresenceTab）
  ({String roomId, String webRid, Map<String, Object?> extra})?
      currentGuardArgsFor(String tabId) {
    final tab = _tabs[tabId];
    if (tab == null) return null;
    return (
      roomId: tab.guardRoomId,
      webRid: tab.guardWebRid,
      extra: tab.guardExtraArgs(),
    );
  }

  /// 跨窗迁移：仲裁栈/holder/accountId/_ready/服务端会话/心跳节奏全不动，
  /// 仅把 tabId 的端口换成 [newPort]（null=端口已由 bindTab 换好的主窗路径），
  /// 重挂心跳 Timer（cancel+periodic，零 HTTP）并在新端口复刻账号态。
  Future<void> rehome(String tabId, {DouyinPresenceTab? newPort}) =>
      _serialized(() => _rehome(tabId, newPort));

  Future<void> _rehome(String tabId, DouyinPresenceTab? newPort) async {
    if (newPort != null) {
      _tabs[tabId] = newPort;
    }
    final tab = _tabs[tabId];
    if (tab == null) return; // 非抖音/纯游客：网关无事可做
    final holderReady =
        arbiter.holder == tabId && _ready.contains(tabId);
    if (!holderReady) return; // guest/suspended：新窗本就是游客态
    final accountId = _accountIds[tabId];
    if (accountId != null) {
      _startHeartbeat(tab, accountId); // 零 HTTP：旧 Timer cancel、新 Timer 起
    }
    if (tab.isClosed) return;
    final status = _lastEnterStatus[tabId];
    if (status == null) return;
    _pendingApplyReplay.add(tabId);
    try {
      await tab.applyReentered(Map<String, dynamic>.from(status));
      _pendingApplyReplay.remove(tabId);
    } catch (e) {
      // 不回滚：会话/心跳仍健康；下次 claim 短路补放，再失败由用户写动作驱动
      Log.logPrint('presence: 迁移复刻账号态失败: $e');
    }
  }

  Future<void> _replayEnter(DouyinPresenceTab tab) async {
    final status = _lastEnterStatus[tab.tabId];
    if (status == null) {
      _pendingApplyReplay.remove(tab.tabId);
      return;
    }
    try {
      await tab.applyReentered(Map<String, dynamic>.from(status));
      _pendingApplyReplay.remove(tab.tabId);
    } catch (e) {
      _pendingApplyReplay.add(tab.tabId);
      Log.logPrint('presence: claim 短路补放复刻失败: $e');
    }
  }
```

3c. `remote_presence_tab.dart`，在 `applyAccountEnter` 之后加（与现有下发体同构，reentered 固定 true、不用 accountDetail）：

```dart
  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    await _port.invoke(
      windowId,
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: tabId,
          cookie: _readCookie(),
          status: Map<String, Object?>.from(guardStatus),
          reentered: true,
        ),
      ),
    );
  }
```

3d. `live_room_controller.dart`：

在 `applyAccountEnter(...)` 方法之后加具体类方法：

```dart
  /// 跨窗迁入主窗：自取账号详情后复用进场复刻流程（网关 rehome 本地路径调用）
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    final accountDetail = await fetchAccountDetail();
    await applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: guardStatus,
      reentered: true,
    );
  }
```

`_ControllerPresenceTab` 在 `applyAccountEnter` 委托后加：

```dart
  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) =>
      _c.applyReentered(guardStatus);
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/douyin_presence_gateway_test.dart`
Expected: 全绿（既有 280 中该文件全部用例 + 新增组）。

- [ ] **Step 5: analyze + 全量测试 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿，数量增加）。

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart simple_live_app/lib/app/multiwindow/presence/ipc/remote_presence_tab.dart simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/test/douyin_presence_gateway_test.dart
git commit -m "feat(presence): 网关 rehome 支持跨窗换端口无缝复刻账号态

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 3: MainPresenceService handoff 表与 register 改挂

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart`
- Test: Create `simple_live_app/test/multiwindow/main_presence_handoff_test.dart`

**Interfaces:**
- Consumes: T2 的 `gateway.rehome/isTrackedTab/currentGuardArgsFor`、`RemotePresenceTab.{guardRoomId,guardWebRid,guardExtraArgs,updateGuardArgs,markClosed}`（均既有/公开）；`_windowOpenService.registry.mainWindowId`（WOS.registry 是既有 final 字段）。
- Produces（T7 消费，命名锁定）：
  - `Future<void>? prepareHandoff(String tabId, String destWindowId)`
  - `Future<void> rehomeLocal(String tabId)`
  - 异常类型（同文件顶层）：`HandoffTimeoutException`、`HandoffSupersededException`、`HandoffSourceClosedException`（均 `const` 构造、implements Exception）。
  - `static const Duration handoffTimeout = Duration(seconds: 10);`
- claim/release/detach/batch/guardSend 一行不改；pr_detach case 保留。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/main_presence_handoff_test.dart`：

```dart
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/main_presence_service.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
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
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _Port implements SubWindowPort {
  final List<(String, String, Object?)> invokes = [];
  final List<String> alive = ['main'];
  final changed = StreamController<void>.broadcast();
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

class _Guard extends GuardServerService {
  final sends = <Map<String, Object?>>[];
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  bool get configured => true;
  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';
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
  }) async =>
      {'joined': false, 'starGuard': false, 'badgeActive': true};
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
  }) async {}
  @override
  Future<Map<String, dynamic>> sendDanmaku({
    required String platform,
    required String accountId,
    required String roomId,
    String webRid = '',
    required String content,
    Map<String, dynamic>? extra,
  }) async {
    sends.add({'platform': platform, 'roomId': roomId});
    return {'success': true};
  }
  @override
  Future<Map<String, dynamic>> sendAction({
    required String accountId,
    required String roomId,
    String webRid = '',
    required String action,
  }) async =>
      {'success': true};
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

class _FakeTab implements DouyinPresenceTab {
  _FakeTab(this.id, this.webRid);
  @override
  final String id;
  final String webRid;
  int reentered = 0;
  @override
  String get tabId => id;
  @override
  bool get isClosed => false;
  @override
  Future<LiveRoomDetail> fetchAccountDetail() async => _detail(webRid);
  @override
  String get guardRoomId => 'room_$webRid';
  @override
  String get guardWebRid => webRid;
  @override
  Map<String, dynamic> guardExtraArgs() => const {};
  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {}
  @override
  Future<void> applyYieldToGuest() async {}
  @override
  Future<void> applySuspended() async {}
  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    reentered++;
  }
}

void main() {
  late _Port port;
  late _Guard guard;
  late WindowRegistry registry;
  late WindowOpenService wos;
  late DouyinPresenceGateway gateway;
  late MainPresenceService svc;

  Future<Object?> register(String windowId, String tabId,
          {String roomId = '1'}) =>
      svc.handleCall(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(PresenceRegisterCall(
          windowId: windowId,
          tabId: tabId,
          siteId: Constant.kDouyin,
          roomId: roomId,
          shareUrl: '',
        )),
      );

  Future<Object?> claim(String windowId, String tabId, String webRid) =>
      svc.handleCall(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(PresenceClaimCall(
          windowId: windowId,
          tabId: tabId,
          roomId: webRid,
          shareUrl: 'http://s/$tabId',
          guardRoomId: 'room_$webRid',
          guardWebRid: webRid,
          guardExtra: const <String, Object?>{},
        )),
      );

  Future<void> flush([int times = 5]) async {
    for (var i = 0; i < times; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<PresenceSendResult> guardSend(String windowId, String tabId) async {
    return PresenceProtocol.decodeSendResult(
      await svc.handleCall(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(PresenceGuardSendCall(
          windowId: windowId,
          tabId: tabId,
          kind: PresenceProtocol.kDanmaku,
          content: 'hi',
        )),
      ),
    )!;
  }

  setUp(() {
    port = _Port();
    guard = _Guard();
    registry = WindowRegistry(mainWindowId: 'main');
    wos = WindowOpenService(
      port: port,
      store: TabStore(registry: _Registry()),
      registry: registry,
    );
    wos.onInit();
    gateway = DouyinPresenceGateway(guard);
    svc = MainPresenceService(
      gateway: gateway,
      port: port,
      windowOpenService: wos,
      // 接缝必传：handoff 路径新建的 RemotePresenceTab 在 claim/rehome
      // applyReentered 当刻取详情/cookie；留空会落到 Sites.allSites 真实联网
      accountDetailFetcher: (roomId, shareUrl) async => _detail(roomId),
      cookieReader: () => 'sessionid=new',
    );
    svc.onInit();
  });

  tearDown(() {
    gateway.stopHeartbeatForTesting();
    svc.onClose();
    wos.onClose();
  });

  test('非跟踪 tab：prepareHandoff 返回 null（纯壳迁移不等）', () {
    expect(svc.prepareHandoff('none', 'w1'), isNull);
  });

  test('10s 超时：completer completeError 且条目清理（register 不再触发 rehome）',
      () {
    fakeAsync((async) {
      gateway.bindTab(_FakeTab('t1', '1'));
      final future = svc.prepareHandoff('t1', 'w1')!;
      async.elapse(const Duration(seconds: 10));
      expectLater(future, throwsA(isA<HandoffTimeoutException>()));
      async.flushMicrotasks();

      // 条目已清：迟到 register 走普通路径，不产生 apply invoke
      register('w1', 't1');
      async.flushMicrotasks();
      expect(port.invokes, isEmpty);
    });
  });

  test('主→子：register 命中 handoff，guard 三元组从网关旧端口复制，'
      'rehome 复刻下行且 guard_send 经新 windowId 成功', () async {
    // 主窗本地标签先经网关完整进场成为 holder+ready（生产中由主窗控制器
    // onInit bindTab + enterAsAccount 完成）：否则 rehome 的 holderReady
    // 判定不成立，currentGuardArgsFor 也读不到 guard 三元组
    final local = _FakeTab('t1', '1');
    gateway.bindTab(local);
    expect((await gateway.claim(local)).granted, isTrue);
    port.invokes.clear();

    final future = svc.prepareHandoff('t1', 'w1')!;
    await register('w1', 't1');
    await flush();
    await future; // 成功结算

    final apply = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(apply.single.$1, 'w1');
    expect(PresenceProtocol.decodeApplyEnter(apply.single.$3)!.reentered,
        isTrue);

    final send = await guardSend('w1', 't1');
    expect(send.success, isTrue);
    expect(guard.sends.single['roomId'], 'room_1',
        reason: '主→子新 RemoteTab 的 guard 来自 currentGuardArgsFor');
  });

  test('子→子：旧 RemoteTab guard 复制到新 tab，复刻发往新窗，旧窗 guard 被拒',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    port.invokes.clear();

    final future = svc.prepareHandoff('t1', 'w2')!;
    await register('w2', 't1');
    await flush();
    await future;

    final apply = port.invokes
        .where((i) => i.$2 == PresenceProtocol.mApplyEnter)
        .toList();
    expect(apply.single.$1, 'w2');
    expect(PresenceProtocol.decodeApplyEnter(apply.single.$3)!.reentered,
        isTrue);

    final send = await guardSend('w2', 't1');
    expect(send.success, isTrue);
    expect(guard.sends.single['roomId'], 'room_1');
    expect((await guardSend('w1', 't1')).code, 'not_holder');
  });

  test('rehomeLocal（子→主）：摘远端索引、网关换到本地端口复刻；旧窗 guard 被拒',
      () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    final local = _FakeTab('t1', '1');
    gateway.bindTab(local); // 主窗新控制器 onInit bindTab

    svc.prepareHandoff('t1', 'main');
    await svc.rehomeLocal('t1');

    expect(local.reentered, 1);
    expect((await guardSend('w1', 't1')).code, 'not_holder',
        reason: '索引已摘，旧窗迟到 guard 裸拒');
  });

  test('handoff 在途源窗死亡：失败结算 HandoffSourceClosedException', () async {
    await register('w1', 't1');
    await claim('w1', 't1', '1');
    final future = svc.prepareHandoff('t1', 'w2')!;

    port.alive.remove('w1');
    port.changed.add(null);
    await flush(10);

    expectLater(future, throwsA(isA<HandoffSourceClosedException>()));
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_presence_handoff_test.dart`
Expected: 编译失败（prepareHandoff/HandoffTimeoutException 等不存在）。

- [ ] **Step 3: 实现 handoff**

在 `main_presence_service.dart`：

3a. 文件顶层（import 之后、class 之前）加异常类型：

```dart
class HandoffTimeoutException implements Exception {
  const HandoffTimeoutException();
  @override
  String toString() => 'HandoffTimeoutException';
}

class HandoffSupersededException implements Exception {
  const HandoffSupersededException();
  @override
  String toString() => 'HandoffSupersededException';
}

class HandoffSourceClosedException implements Exception {
  const HandoffSourceClosedException();
  @override
  String toString() => 'HandoffSourceClosedException';
}

class _Handoff {
  _Handoff(this.destWindowId) : completer = Completer<void>();

  final String destWindowId;
  final Completer<void> completer;
  Timer? timer;
  bool settled = false;
}
```

3b. class 字段区（`_remoteTabs` 之后）加：

```dart
  static const Duration handoffTimeout = Duration(seconds: 10);
  final Map<String, _Handoff> _handoffs = {};
```

3c. `_register` 整体替换为：

```dart
  Future<Object?> _register(Object? arguments) async {
    final call = PresenceProtocol.decodeRegister(arguments);
    if (call == null || call.siteId != Constant.kDouyin) return false;
    // 索引先于一切（既有改挂语义；迁移在途旧窗迟到消息由归属门天然过滤）
    _tabWindow[call.tabId] = call.windowId;

    final handoff = _handoffs[call.tabId];
    if (handoff != null) {
      if (call.windowId != _windowOpenService.registry.mainWindowId) {
        // 目标必为子窗：无条件换新 RemotePresenceTab。
        // guard 双来源：子→子复制旧 RemoteTab；主→子问网关当前端口要。
        final old = _remoteTabs.remove(call.tabId);
        final guard = old != null
            ? (
                roomId: old.guardRoomId,
                webRid: old.guardWebRid,
                extra: old.guardExtraArgs(),
              )
            : gateway.currentGuardArgsFor(call.tabId);
        old?.markClosed();
        final fresh = RemotePresenceTab(
          tabId: call.tabId,
          windowId: call.windowId,
          roomId: call.roomId,
          shareUrl: call.shareUrl,
          port: port,
          accountDetailFetcher: accountDetailFetcher,
          cookieReader: cookieReader,
        );
        if (guard != null) {
          fresh.updateGuardArgs(
            guardRoomId: guard.roomId,
            guardWebRid: guard.webRid,
            guardExtra: guard.extra,
          );
        }
        _remoteTabs[call.tabId] = fresh;
        unawaited(
          gateway.rehome(call.tabId, newPort: fresh).then(
            (_) => _settleHandoff(call.tabId),
            onError: (Object e) => _failHandoff(call.tabId, e),
          ),
        );
      } else {
        // 主窗不发 register，此路不可达；防御性直接结算
        _settleHandoff(call.tabId);
      }
    }
    return true;
  }
```

3d. 在 `_onChildWindowsClosed` 的 `for (final tabId in tabIds) { _remoteTabs... }` 循环之后、`if (tabIds.isNotEmpty)` 之前插入：

```dart
    for (final tabId in tabIds) {
      _failHandoff(tabId, const HandoffSourceClosedException());
    }
```

3e. 新增方法（放在 `_onChildWindowsClosed` 之前）：

```dart
  /// 编排层迁移前置：网关跟踪该 tab 时建 10s handoff 并返回其 future；
  /// 非跟踪（非抖音/纯游客）返回 null，编排层按纯壳迁移处理。
  Future<void>? prepareHandoff(String tabId, String destWindowId) {
    if (!gateway.isTrackedTab(tabId)) return null;
    final previous = _handoffs.remove(tabId);
    if (previous != null && !previous.settled) {
      previous.settled = true;
      previous.timer?.cancel();
      if (!previous.completer.isCompleted) {
        previous.completer
            .completeError(const HandoffSupersededException());
      }
    }
    final handoff = _Handoff(destWindowId);
    handoff.timer = Timer(handoffTimeout, () {
      if (!handoff.settled) {
        handoff.settled = true;
        _handoffs.remove(tabId);
        if (!handoff.completer.isCompleted) {
          handoff.completer.completeError(
            const HandoffTimeoutException(),
          );
        }
      }
    });
    _handoffs[tabId] = handoff;
    return handoff.completer.future;
  }

  /// 子→主：主窗 store.open 后控制器已 bindTab 本地端口。摘远端索引/
  /// RemoteTab，网关 rehome(newPort:null) 换到本地端口并复刻；幂等。
  Future<void> rehomeLocal(String tabId) async {
    final old = _remoteTabs.remove(tabId);
    old?.markClosed();
    _tabWindow.remove(tabId);
    if (gateway.isTrackedTab(tabId)) {
      await gateway.rehome(tabId);
    }
    _settleHandoff(tabId);
  }

  void _settleHandoff(String tabId) {
    final handoff = _handoffs[tabId];
    if (handoff == null || handoff.settled) return;
    handoff.settled = true;
    handoff.timer?.cancel();
    _handoffs.remove(tabId);
    if (!handoff.completer.isCompleted) {
      handoff.completer.complete();
    }
  }

  void _failHandoff(String tabId, Object error) {
    final handoff = _handoffs[tabId];
    if (handoff == null || handoff.settled) return;
    handoff.settled = true;
    handoff.timer?.cancel();
    _handoffs.remove(tabId);
    if (!handoff.completer.isCompleted) {
      handoff.completer.completeError(error);
    }
  }
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_presence_handoff_test.dart test/multiwindow/main_presence_service_test.dart`
Expected: 两个文件全绿（既有 M4-3 测试零回归）。

- [ ] **Step 5: analyze + 全量测试 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿）。

```bash
git add simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart simple_live_app/test/multiwindow/main_presence_handoff_test.dart
git commit -m "feat(presence): 主端 presence 服务增加跨窗迁移 handoff 协议

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 4: 预定 tabId 开窗 / closeForMove / 控制器迁移抑制 leave

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/window/window_args.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_store.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（`_movedAway` + onClose）
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`（仅开窗循环透传 tabId；mw_ 装配在 T6）
- Modify: `simple_live_app/test/multiwindow/window_args_test.dart`
- Modify: `simple_live_app/test/tab_store_test.dart`
- Modify: `simple_live_app/test/sub_window_presence_controller_test.dart`

**Interfaces:**
- Consumes: 无（T1–T3 均不被本任务依赖）。
- Produces（T6/T7 消费，命名锁定）：
  - `TabStore.open(TabOpenRequest request, {bool activate = true, String? tabId})`
  - `TabStore.closeForMove(String tabId)`（返回 `TabDescriptor`，行为同 close 但先 `debugMarkMovedAway` 抑制控制器 presence leave）
  - `RoomTabArg` 增加 `final String? tabId`。
  - `LiveRoomController.debugMarkMovedAway()`（@visibleForTesting）。

- [ ] **Step 1: 写失败测试**

1a. `test/multiwindow/window_args_test.dart` 末尾追加：

```dart
  test('RoomTabArg.tabId 往返；旧 JSON 缺字段为 null', () {
    const args = RoomWindowArgs(
      tabs: [
        RoomTabArg(siteId: 'douyin', roomId: '1', tabId: 'fixed-id'),
        RoomTabArg(siteId: 'douyin', roomId: '2'),
      ],
    );
    final decoded = RoomWindowArgs.decode(args.encode());
    expect(decoded.tabs[0].tabId, 'fixed-id');
    expect(decoded.tabs[1].tabId, isNull);

    final legacy = RoomTabArg.fromJson(
        jsonDecode('{"siteId":"douyin","roomId":"9","shareUrl":""}')
            as Map<String, dynamic>);
    expect(legacy.tabId, isNull);
  });
```

并在文件顶部加 `import 'dart:convert';`。

1b. `test/tab_store_test.dart` 末尾（main() 内最后）追加：

```dart
  test('open 接受外部 tabId：迁移落地保持 id 不变', () {
    final t = store.open(req('douyin', 'r1'), tabId: 'fixed-tab-id');
    expect(t.tabId, 'fixed-tab-id');
    expect(store.tabs.single.tabId, 'fixed-tab-id');
    expect(registry.registered.containsKey('fixed-tab-id'), isTrue);
  });

  test('closeForMove：行为同 close（注销/摘除/激活相邻）', () {
    final t1 = store.open(req('douyin', 'r1'), tabId: 'a');
    final t2 = store.open(req('douyin', 'r2'), tabId: 'b');
    final removed = store.closeForMove('a');
    expect(removed.tabId, 'a');
    expect(store.tabs.single.tabId, 'b');
    expect(store.activeTabId.value, 'b');
    expect(registry.registered.containsKey('a'), isFalse);
  });
```

（FakeRegistry.controllerForTabId 返回 null，closeForMove 的 markMovedAway 为 null-safe 跳过；控制器侧抑制由 1c 覆盖。）

1c. `test/sub_window_presence_controller_test.dart` main() 内追加：

```dart
  test('closeForMove 语义：debugMarkMovedAway 后 onClose 不发 pr_release；'
      '普通 onClose 仍发', () async {
    // 迁移关闭路径
    final movedPort = _FakePort();
    putCoordinator(movedPort);
    final moved = makeController();
    moved.bindSubWindowPresence();
    await Future<void>.delayed(Duration.zero);
    movedPort.calls.clear();

    moved.debugMarkMovedAway();
    moved.onClose();
    await Future<void>.delayed(Duration.zero);
    expect(
      movedPort.calls.any((c) => c.$1 == PresenceProtocol.mRelease),
      isFalse,
      reason: '迁移关闭不发 leave，心跳/栈由主端 rehome 延续',
    );

    // 普通关闭路径（Get.reset 在 tearDown，手动新建一套）
    Get.reset();
    final normalPort = _FakePort();
    putCoordinator(normalPort);
    final normal = makeController();
    normal.bindSubWindowPresence();
    await Future<void>.delayed(Duration.zero);
    normalPort.calls.clear();

    normal.onClose();
    await Future<void>.delayed(Duration.zero);
    expect(
      normalPort.calls.any((c) => c.$1 == PresenceProtocol.mRelease),
      isTrue,
      reason: '普通 onClose 行为不变',
    );
  });
```

注意：若 `onClose()` 在该夹具下因 player/observer 清理抛错，允许用 `tester.pumpWidget(GetMaterialApp(home: const SizedBox()))` 先提供绑定（沿用本文件既有 testWidgets 夹具），但断言内容不变；偏离写入报告。

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart test/tab_store_test.dart test/sub_window_presence_controller_test.dart`
Expected: 编译失败（tabId 参数/closeForMove/debugMarkMovedAway 不存在）。

- [ ] **Step 3: 最小实现**

3a. `window_args.dart` 的 `RoomTabArg` 改为：

```dart
class RoomTabArg {
  const RoomTabArg({
    required this.siteId,
    required this.roomId,
    this.shareUrl = '',
    this.tabId,
  });

  final String siteId;
  final String roomId;
  final String shareUrl;

  /// 跨窗迁移预定的标签 id；null=新开窗由 TabStore 生成 uuid
  final String? tabId;

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'roomId': roomId,
        'shareUrl': shareUrl,
        if (tabId != null) 'tabId': tabId,
      };

  factory RoomTabArg.fromJson(Map<String, dynamic> json) => RoomTabArg(
        siteId: json['siteId'] as String,
        roomId: json['roomId'] as String,
        shareUrl: (json['shareUrl'] as String?) ?? '',
        tabId: json['tabId'] as String?,
      );
}
```

3b. `tab_store.dart`：

`open` 签名与 id 行改为：

```dart
  TabDescriptor open(TabOpenRequest request,
      {bool activate = true, String? tabId}) {
    final existing =
        tabs.firstWhereOrNull((t) => t.request.key == request.key);
    if (existing != null) {
      if (activate) {
        activeTabId.value = existing.tabId;
      }
      return existing;
    }
    final id = tabId ?? _uuid.v4();
```

（方法体其余一行不动。）

在 `close(...)` 之后新增：

```dart
  /// 跨窗迁移关闭：先标记控制器「已迁走」抑制其 onClose 的 presence leave
  /// （心跳/仲裁栈由主端 rehome 延续），其余与 close 完全相同。
  TabDescriptor closeForMove(String tabId) {
    registry.controllerForTabId(tabId)?.debugMarkMovedAway();
    return close(tabId);
  }
```

3c. `live_room_controller.dart`：

字段区（`_presenceTab` 附近）加：

```dart
  /// 跨窗迁移关闭：onClose 时不再发 presence leave（栈/心跳在主端延续）
  bool _movedAway = false;

  @visibleForTesting
  void debugMarkMovedAway() {
    _movedAway = true;
  }
```

onClose 中把：

```dart
    unawaited(_leaveDouyinPresence(unconditional: true));
```

改为：

```dart
    if (!_movedAway) {
      unawaited(_leaveDouyinPresence(unconditional: true));
    }
```

（onClose 其余清理一律不动。）

3d. `sub_engine_bootstrap.dart` 开窗循环改为透传 tabId：

```dart
  for (final tab in args.tabs) {
    try {
      store.open(
        TabOpenRequest(
          siteId: tab.siteId,
          roomId: tab.roomId,
          shareUrl: tab.shareUrl,
        ),
        tabId: tab.tabId,
      );
    } catch (e, st) {
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart test/tab_store_test.dart test/sub_window_presence_controller_test.dart`
Expected: 全绿。

- [ ] **Step 5: analyze + 全量测试 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿）。

```bash
git add simple_live_app/lib/app/multiwindow/window/window_args.dart simple_live_app/lib/app/multiwindow/shell/tab_store.dart simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart simple_live_app/test/multiwindow/window_args_test.dart simple_live_app/test/tab_store_test.dart simple_live_app/test/sub_window_presence_controller_test.dart
git commit -m "feat(shell): 标签支持预定 tabId 与迁移关闭语义

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 5: WindowRegistry 子窗标签挪动与开窗序

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/window/window_registry.dart`
- Test: Create `simple_live_app/test/multiwindow/window_registry_tabs_test.dart`

**Interfaces:**
- Consumes: 无。
- Produces（T7 消费，命名锁定）：
  - `void addChildTab(String windowId, String tabKey)`
  - `void removeChildTab(String windowId, String tabKey)`
  - `void moveChildTab(String fromWindowId, String toWindowId, String tabKey)`
  - `List<({String id, int ordinal})> childWindowOrder()`（ordinal = 开窗序，1 起）
- 既有 `registerChild/reconcile/windowForTab/tabsOf/childWindowIds` 行为不变；注意现存数据是 **tabKey（siteId_roomId）**，不是 tabId。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/window_registry_tabs_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';

void main() {
  test('addChildTab 合并不覆盖；未注册窗抛 StateError', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a'});
    r.addChildTab('w1', 'douyin_b');
    expect(r.tabsOf('w1'), {'douyin_a', 'douyin_b'});

    r.addChildTab('w1', 'douyin_a'); // 幂等
    expect(r.tabsOf('w1'), {'douyin_a', 'douyin_b'});

    expect(() => r.addChildTab('w9', 'douyin_x'), throwsStateError);
  });

  test('removeChildTab 摘除 key；空 set 保留（窗存活由 reconcile 对账）', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a', 'douyin_b'});
    r.removeChildTab('w1', 'douyin_a');
    expect(r.tabsOf('w1'), {'douyin_b'});
    expect(r.childWindowIds, ['w1'], reason: '空窗不立即摘除');

    r.removeChildTab('w1', 'douyin_b');
    expect(r.tabsOf('w1'), isEmpty);
    expect(r.childWindowIds, ['w1']);
    expect(r.windowForTab('douyin_b'), isNull);

    // 未知窗/未知 key 静默 no-op
    r.removeChildTab('w9', 'x');
    r.removeChildTab('w1', 'x');
  });

  test('moveChildTab：源摘除、目标合并；windowForTab 更新', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w1', {'douyin_a'});
    r.registerChild('w2', {'douyin_b'});
    r.moveChildTab('w1', 'w2', 'douyin_a');
    expect(r.tabsOf('w1'), isEmpty);
    expect(r.tabsOf('w2'), {'douyin_a', 'douyin_b'});
    expect(r.windowForTab('douyin_a'), 'w2');
  });

  test('childWindowOrder：按开窗序给 1 起 ordinal；reconcile 后重算列表', () {
    final r = WindowRegistry(mainWindowId: 'main');
    r.registerChild('w10', {'a_1'});
    r.registerChild('w20', {'a_2'});
    final order = r.childWindowOrder();
    expect(order.map((e) => e.id), ['w10', 'w20']);
    expect(order.map((e) => e.ordinal), [1, 2]);

    r.reconcile(['main', 'w20']);
    final after = r.childWindowOrder();
    expect(after.single.id, 'w20');
    expect(after.single.ordinal, 1, reason: '摘除后剩余窗 ordinal 连续重排');
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_registry_tabs_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 最小实现**

在 `window_registry.dart` 的 `reconcile` 之前插入：

```dart
  /// 子窗新增一个标签 key（跨窗落地）。窗必须先 registerChild，否则 StateError。
  void addChildTab(String windowId, String tabKey) {
    final set = _childTabs[windowId];
    if (set == null) {
      throw StateError('window not registered: $windowId');
    }
    set.add(tabKey);
  }

  /// 摘除单个标签 key；空 set 保留，窗进程死活由 reconcile 对账。
  void removeChildTab(String windowId, String tabKey) {
    _childTabs[windowId]?.remove(tabKey);
  }

  /// 标签在两个子窗之间挪动（源空窗保留待 reconcile/自动关闭）。
  void moveChildTab(String fromWindowId, String toWindowId, String tabKey) {
    removeChildTab(fromWindowId, tabKey);
    addChildTab(toWindowId, tabKey);
  }

  /// 开窗序列（1 起 ordinal）：窗口列表菜单编号用。
  List<({String id, int ordinal})> childWindowOrder() => [
        for (var i = 0; i < _order.length; i++)
          (id: _order[i], ordinal: i + 1),
      ];
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_registry_tabs_test.dart test/multiwindow/window_open_service_test.dart`
Expected: 全绿（既有 WOS 测试内含 registry 断言，零回归）。

- [ ] **Step 5: analyze + 全量测试 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿）。

```bash
git add simple_live_app/lib/app/multiwindow/window/window_registry.dart simple_live_app/test/multiwindow/window_registry_tabs_test.dart
git commit -m "feat(multiwindow): 注册表支持子窗标签挪动与开窗序编号

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 6: 子端窗口管理通道与落窗服务

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/window/sub_window_control_port.dart`
- Create: `simple_live_app/lib/app/multiwindow/window/sub_window_control_service.dart`
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`（import 3 个、controlPort 门控构造、service put、唯一 handler 加两 case）
- Test: Create `simple_live_app/test/multiwindow/sub_window_control_service_test.dart`

**Interfaces:**
- Consumes:
  - T1：`WindowControlProtocol.mListWindows/mRequestMove/mOpenTab/mCloseTab`、`encodeRequestMove/decodeMoveResult/decodeWindowList/encodeOpenTab` 无需（子端只收）、`decodeOpenTab/decodeCloseTab`；`WindowMoveCall/OpenTabCall/CloseTabCall/WindowListEntry`。
  - T4：`TabStore.open(request, {activate, tabId})`、`TabStore.closeForMove(tabId)`。
  - 既有：`SubWindowControlPort` 同形于 `SubPresencePort`（`sub_presence_port.dart`）；dmw windowId 全线 **String**（`self.windowId` 即 String，与 `IpcPresenceCoordinator(windowId: self.windowId)` 一致）。
  - 最后一个标签被 mw_close_tab 关走后，子窗自动关闭由既有 `room_shell_page.dart` 的 `_emptyWorker`（ever(store.tabs) 空→windowManager.close）负责，service 不关窗。
- Produces（T7/T8 消费，命名锁定）：
  - `abstract class SubWindowControlPort { Future<Object?> invokeMain(String method, [Object? args]); }`
  - `class DmwSubWindowControlPort implements SubWindowControlPort { DmwSubWindowControlPort(this.mainWindowId); }`
  - `class SubWindowControlService extends GetxService`：
    - 构造 `{required String windowId, required SubWindowControlPort port, required TabStore store, void Function(String)? showToast}`（showToast 仅测试注入，生产默认 `SmartDialog.showToast`）
    - `static SubWindowControlService get instance => Get.find<SubWindowControlService>();`
    - `Future<List<WindowListEntry>> requestWindowList()`
    - `Future<bool> requestMove({required TabDescriptor tab, required String target})`
    - `Future<Object?> handleCall(String method, Object? arguments)`
  - 子端兜底 toast 文案锁定 `'移动失败，请重试'`（主端有固定 message 时显示 message）。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/sub_window_control_service_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_descriptor.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class _FakeRegistry implements RoomControllerRegistry {
  final registered = <String, TabOpenRequest>{};
  int unregisterCount = 0;
  @override
  void register(String tabId, TabOpenRequest request) =>
      registered[tabId] = request;
  @override
  void unregister(String tabId) {
    registered.remove(tabId);
    unregisterCount++;
  }
  @override
  bool isRegistered(String tabId) => registered.containsKey(tabId);
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _ThrowingRegistry extends _FakeRegistry {
  @override
  void register(String tabId, TabOpenRequest request) =>
      throw ArgumentError('unknown site: ${request.siteId}');
}

class _FakeControlPort implements SubWindowControlPort {
  final calls = <(String, Object?)>[];
  Object? result;
  Object? error;
  @override
  Future<Object?> invokeMain(String method, [Object? args]) async {
    calls.add((method, args));
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  late _FakeControlPort port;
  late TabStore store;
  final toasts = <String>[];

  SubWindowControlService buildService({TabStore? givenStore}) {
    return SubWindowControlService(
      windowId: 'w1',
      port: port,
      store: givenStore ?? store,
      showToast: toasts.add,
    );
  }

  setUp(() {
    port = _FakeControlPort();
    store = TabStore(registry: _FakeRegistry(), hasHome: false);
    toasts.clear();
  });

  group('requestWindowList', () {
    test('解码主端窗口列表', () async {
      port.result = WindowControlProtocol.encodeWindowList(const [
        WindowListEntry(id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
      final list = await buildService().requestWindowList();
      expect(port.calls.single.$1, WindowControlProtocol.mListWindows);
      expect(list.map((e) => e.id), ['__main__', 'w2']);
      expect(list.map((e) => e.label), ['主窗口', '直播间窗口 2']);
    });

    test('非法/空回执返回空列表', () async {
      port.result = 'nope';
      expect(await buildService().requestWindowList(), isEmpty);
      port.result = null;
      expect(await buildService().requestWindowList(), hasLength(1));
    });
  });

  group('requestMove', () {
    TabDescriptor tab() => TabDescriptor(
          tabId: 'tab-1',
          request: const TabOpenRequest(
            siteId: 'douyin',
            roomId: 'r1',
            shareUrl: 'https://live.douyin.com/r1',
          ),
        );

    test('成功：载荷带 sourceWindowId/预定 tabId/四元组/target，无 toast',
        () async {
      port.result =
          WindowControlProtocol.encodeMoveResult(true);
      final ok = await buildService()
          .requestMove(tab: tab(), target: 'w2');
      expect(ok, isTrue);
      expect(toasts, isEmpty);

      final call = WindowControlProtocol.decodeRequestMove(
          port.calls.single.$2)!;
      expect(call.sourceWindowId, 'w1');
      expect(call.tabId, 'tab-1');
      expect(call.siteId, 'douyin');
      expect(call.roomId, 'r1');
      expect(call.shareUrl, 'https://live.douyin.com/r1');
      expect(call.target, 'w2');
    });

    test('主端回执 ok:false：显示主端 message 并返回 false', () async {
      port.result = WindowControlProtocol.encodeMoveResult(
          false,
          message: '目标窗口无响应');
      final ok = await buildService()
          .requestMove(tab: tab(), target: 'w2');
      expect(ok, isFalse);
      expect(toasts, ['目标窗口无响应']);
    });

    test('回执非法/null：兜底文案 toast，不抛错', () async {
      port.result = {'ok': 'x'};
      expect(
          await buildService().requestMove(tab: tab(), target: 'w2'), isFalse);
      expect(toasts, ['移动失败，请重试']);

      port.result = null;
      expect(
          await buildService().requestMove(tab: tab(), target: 'w2'), isFalse);
      expect(toasts, ['移动失败，请重试', '移动失败，请重试']);
    });

    test('invokeMain 抛错：兜底文案 toast，不 rethrow', () async {
      port.error = StateError('channel gone');
      expect(
          await buildService().requestMove(tab: tab(), target: '__main__'),
          isFalse);
      expect(toasts, ['移动失败，请重试']);
    });
  });

  group('handleCall', () {
    test('mw_open_tab：以预定 tabId 落标签；activate 透传', () async {
      final svc = buildService();
      final result = await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'fixed-id',
            siteId: 'douyin',
            roomId: 'r9',
            shareUrl: '',
            activate: false,
          ),
        ),
      );
      expect(result, isTrue);
      expect(store.tabs.single.tabId, 'fixed-id');
      expect(store.activeTabId.value, isNull, reason: 'activate:false 不切换');

      await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'fixed-id-2',
            siteId: 'douyu',
            roomId: 'r10',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(store.activeTabId.value, 'fixed-id-2');
    });

    test('mw_open_tab：载荷非法返回 false', () async {
      expect(await buildService().handleCall(
          WindowControlProtocol.mOpenTab, null), isFalse);
    });

    test('mw_open_tab：register 抛错（未知 site）返回 false、不留标签',
        () async {
      final throwingStore = TabStore(
        registry: _ThrowingRegistry(),
        hasHome: false,
      );
      final result = await buildService(givenStore: throwingStore).handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'x',
            siteId: 'unknown-site',
            roomId: '1',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(result, isFalse);
      expect(throwingStore.tabs, isEmpty);
    });

    test('mw_close_tab：迁移关闭走 closeForMove；未知 tabId/非法载荷 false',
        () async {
      final svc = buildService();
      await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 't1',
            siteId: 'douyin',
            roomId: '111',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(
        await svc.handleCall(
          WindowControlProtocol.mCloseTab,
          WindowControlProtocol.encodeCloseTab(const CloseTabCall(tabId: 't1')),
        ),
        isTrue,
      );
      expect(store.tabs, isEmpty);

      expect(
        await svc.handleCall(
          WindowControlProtocol.mCloseTab,
          WindowControlProtocol.encodeCloseTab(const CloseTabCall(tabId: 'gone')),
        ),
        isFalse,
      );
      expect(
        await svc.handleCall(WindowControlProtocol.mCloseTab, null),
        isFalse,
      );
    });

    test('未知方法返回 null（单 handler 槽位继续向 default 回落）', () async {
      expect(await buildService().handleCall('something_else', null), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_window_control_service_test.dart`
Expected: 编译失败（port/service 文件不存在）。

- [ ] **Step 3: 最小实现**

`lib/app/multiwindow/window/sub_window_control_port.dart`：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎窗口管理面调用的单一出口（mw_ 前缀）。
/// 与 SubPresencePort / SubDataPlanePort 物理隔离：主端分别由
/// WindowOpenService 与 MainPresenceService 解析，凭据永不进入本通道。
abstract class SubWindowControlPort {
  Future<Object?> invokeMain(String method, [Object? args]);
}

class DmwSubWindowControlPort implements SubWindowControlPort {
  DmwSubWindowControlPort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? args]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, args);
  }
}
```

`lib/app/multiwindow/window/sub_window_control_service.dart`：

```dart
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import '../shell/tab_descriptor.dart';
import '../shell/tab_open_request.dart';
import '../shell/tab_store.dart';
import 'sub_window_control_port.dart';
import 'window_control_protocol.dart';

/// 子引擎窗口管理服务：应主端要求落标签/关标签，并向主端发起跨窗移动。
/// 仅在带主窗 id 的子窗装配（bootstrap presencePort 同款门控）。
class SubWindowControlService extends GetxService {
  SubWindowControlService({
    required this.windowId,
    required this.port,
    required this.store,
    void Function(String message)? showToast,
  }) : _showToast = showToast ?? SmartDialog.showToast;

  final String windowId;
  final SubWindowControlPort port;
  final TabStore store;
  final void Function(String message) _showToast;

  static SubWindowControlService get instance =>
      Get.find<SubWindowControlService>();

  /// 拉取可移入窗口列表（含主窗口）；调用方自行排除本窗 windowId。
  Future<List<WindowListEntry>> requestWindowList() async {
    final raw = await port.invokeMain(WindowControlProtocol.mListWindows);
    return WindowControlProtocol.decodeWindowList(raw) ?? const [];
  }

  /// 请求把本窗标签移到 target（__main__/__new__/windowId）。
  /// 成败由主端裁定；失败只 toast 不抛异常，返回 false 供菜单收口。
  Future<bool> requestMove({
    required TabDescriptor tab,
    required String target,
  }) async {
    final args = WindowControlProtocol.encodeRequestMove(
      WindowMoveCall(
        sourceWindowId: windowId,
        tabId: tab.tabId,
        siteId: tab.request.siteId,
        roomId: tab.request.roomId,
        shareUrl: tab.request.shareUrl,
        target: target,
      ),
    );
    try {
      final result = WindowControlProtocol.decodeMoveResult(
        await port.invokeMain(WindowControlProtocol.mRequestMove, args),
      );
      if (result != null && result.ok) return true;
      _showToast(result?.message ?? '移动失败，请重试');
      return false;
    } catch (_) {
      _showToast('移动失败，请重试');
      return false;
    }
  }

  /// 子端总 handler 的 mw_ 委托点；未知方法返回 null 交由 default 回落。
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case WindowControlProtocol.mOpenTab:
        final call = WindowControlProtocol.decodeOpenTab(arguments);
        if (call == null) return false;
        try {
          store.open(
            TabOpenRequest(
              siteId: call.siteId,
              roomId: call.roomId,
              shareUrl: call.shareUrl,
            ),
            activate: call.activate,
            tabId: call.tabId,
          );
          return true;
        } catch (_) {
          return false;
        }
      case WindowControlProtocol.mCloseTab:
        final call = WindowControlProtocol.decodeCloseTab(arguments);
        if (call == null) return false;
        try {
          store.closeForMove(call.tabId);
          return true;
        } catch (_) {
          return false;
        }
      default:
        return null;
    }
  }
}
```

`sub_engine_bootstrap.dart` 三处修改：

3a. import（按既有字母序插入 `simple_live_app` 段）：

```dart
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
```

3b. 在 `presencePort` 构造之后加同款门控；在 `store` 的 `Get.put` 之后、`dataClient` 构造之前装配 service：

```dart
  // 窗口管理通道与 presence 通道同门控：只有挂在主窗下的子窗才能跨窗迁移
  final SubWindowControlPort? controlPort = presencePort == null
      ? null
      : DmwSubWindowControlPort(args.mainWindowId);
```

```dart
  final SubWindowControlService? controlService = controlPort == null
      ? null
      : Get.put(
          SubWindowControlService(
            windowId: self.windowId,
            port: controlPort,
            store: store,
          ),
          permanent: true,
        );
```

3c. 唯一 handler 内（`PresenceProtocol.mApplySuspended` case 之后、`'focus_tab'` 之前）加委托，不重挂 handler：

```dart
      case WindowControlProtocol.mOpenTab:
      case WindowControlProtocol.mCloseTab:
        // controlService 为 null（无主窗的独立子窗）时返回 null
        return await controlService?.handleCall(call.method, call.arguments);
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_window_control_service_test.dart`
Expected: 全绿。

- [ ] **Step 5: analyze + 全量测试 + Windows 编译 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22，零新增）；`C:/tools/flutter347/flutter/bin/flutter.bat test`（基线 280 只增不减，本任务 +13）。
本任务改动每个子窗的 bootstrap 启动装配，跑 `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug` 保接线编译通过（预期仅编译验证，不运行）。

```bash
git add simple_live_app/lib/app/multiwindow/window/sub_window_control_port.dart simple_live_app/lib/app/multiwindow/window/sub_window_control_service.dart simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart simple_live_app/test/multiwindow/sub_window_control_service_test.dart
git commit -m "feat(multiwindow): 子端窗口管理通道与标签落窗服务

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 7: 主端跨窗编排与 mw_ 协议路由

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/window/sub_window_port.dart`（invoke 返回值 void→Object?）
- Modify: `simple_live_app/lib/app/multiwindow/window/dmw_sub_window_port.dart`（透传 invokeMethod 回执）
- Create: `simple_live_app/lib/app/multiwindow/presence/handoff_controller.dart`（窄接口，解耦 window 层对 MPS 的具体依赖）
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart`（implements 窄接口 + import）
- Modify: `simple_live_app/lib/app/multiwindow/window/window_open_service.dart`（编排核心；删 moveTabToNewWindow）
- Create: `simple_live_app/lib/app/multiwindow/window/unhandled_method_router.dart`
- Modify: `simple_live_app/lib/routes/app_pages.dart`（WOS 接变量、presenceService 后绑、前缀路由闭包 + 2 import）
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart`（仅替换 move_window 调用点保编译；菜单结构在 T8）
- Test: Create `simple_live_app/test/multiwindow/unhandled_method_router_test.dart`
- Test: Create `simple_live_app/test/multiwindow/window_move_orchestration_test.dart`
- Test: Modify `simple_live_app/test/multiwindow/window_open_service_test.dart`（fake invoke 签名；删旧 moveTabToNewWindow 用例）
- Test: Modify `simple_live_app/test/multiwindow/main_presence_service_test.dart`（fake invoke 签名）
- Test: Modify `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`（fake invoke 签名）
- Test: Modify `simple_live_app/test/multiwindow/main_presence_handoff_test.dart`（T3 的 _Port.invoke 签名）

**Interfaces:**
- Consumes：T1 协议全家；T2 `gateway.rehome/isTrackedTab/currentGuardArgsFor`（经 MPS）；T3 `MainPresenceService.prepareHandoff/rehomeLocal`；T4 `TabStore.open(tabId:)/closeForMove`、`RoomTabArg(tabId:)`；T5 `addChildTab/removeChildTab/moveChildTab/childWindowOrder`；T6 子端 mw_open_tab/mw_close_tab 回执 true/false。
- Produces（T8 消费，命名锁定）：
  - `abstract class PresenceHandoffController { Future<void>? prepareHandoff(String tabId, String destWindowId); Future<void> rehomeLocal(String tabId); }`（`presence/handoff_controller.dart`；MPS implements）
  - `WindowOpenService.PresenceHandoffController? presenceService`（可空 setter 风格字段，app_pages 后绑）
  - `Future<Object?> handleWindowCall(String method, Object? arguments)`
  - `List<WindowListEntry> listMoveTargets({required String? excludeWindowId})`（仅子窗，label `'直播间窗口 $ordinal'`）
  - `List<WindowListEntry> listWindowEntries()`（首项固定 `{id:'__main__', label:'主窗口'}` + 子窗）
  - `Future<String?> moveTabToWindow({required String tabId, String? sourceWindowId, required String target, String? siteId, String? roomId, String? shareUrl})`（null=成功；非空=固定中文失败文案。**主源失败在主端 toast；子源失败不 toast，文案随回执回子端**——跨引擎 toast 不共享）
  - 顶层 `typedef UnhandledMethodHandler = Future<Object?> Function(String method, Object? arguments);` 与 `Future<Object?> routeUnhandledMethod(method, arguments, {required presenceHandler, required windowHandler})`
- **Ruling（偏离 spec §7.1 一处，记录）**：spec 写 `MainPresenceService? presenceService;` 与 `Future<Map> handleWindowCall`；实现取窄接口 `PresenceHandoffController`（编排测试无需真 guard/gateway 栈，window 层不反向依赖 ipc 具体类），`handleWindowCall` 返回 `Future<Object?>`（mListWindows 回执是 List 不是 Map）。行为与 spec 完全一致。
- **Ruling（spec 无 cancelHandoff）**：新窗进程创建提前到 prepareHandoff 之前（仍属 spec 步骤 4「落标签」起点）；createRoomWindow 抛错发生在 handoff 建表之前，无需取消接口。其余失败路径 spec §8 已全部有收口（超时 Timer/死亡对账/子端 false）。
- 失败文案锁定：`'未找到要移动的标签'`、`'目标窗口不存在'`、`'新建窗口失败'`、`'目标窗口无响应'`、`'移动超时，标签可能已在目标窗口'`、handler 载荷兜底 `'移动失败，请重试'`。

- [ ] **Step 0: 放宽 SubWindowPort.invoke 回执类型（支撑性重构，先保绿）**

编排要读 mw_open_tab 子端 true/false 回执；既有抽象把 invokeMethod 结果丢弃为 void。放宽为 Object?，所有既有调用方不读返回值，行为不变。

`sub_window_port.dart`：

```dart
  /// 调用子窗 method handler；返回值为子端回执（如 mw_open_tab 的 bool）。
  /// 既有 focus_tab/close_window/apply_* 调用方忽略返回值。
  Future<Object?> invoke(String windowId, String method, Object? arguments);
```

`dmw_sub_window_port.dart`：

```dart
  @override
  Future<Object?> invoke(
      String windowId, String method, Object? arguments) async {
    return WindowController.fromWindowId(windowId)
        .invokeMethod(method, arguments);
  }
```

四个测试 fake 同步签名（返回 null；保留各自原有 throw 逻辑）：

- `test/multiwindow/window_open_service_test.dart`：
```dart
  @override
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    invocations.add((windowId, method, arguments));
    return null;
  }
```
- `test/multiwindow/main_presence_service_test.dart`：
```dart
  @override
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    invokes.add((windowId, method, arguments));
    return null;
  }
```
- `test/multiwindow/main_data_plane_service_test.dart`：
```dart
  @override
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    calls.add((windowId, method, arguments));
    if (windowId == throwingWindow) throw StateError('window gone');
    return null;
  }
```
- `test/multiwindow/main_presence_handoff_test.dart`（T3 已创建）：
```dart
  @override
  Future<Object?> invoke(String windowId, String method, Object? arguments)
      async {
    invokes.add((windowId, method, arguments));
    return null;
  }
```

运行 `C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿，零行为变化）。

- [ ] **Step 1: 路由函数——先写失败测试**

`test/multiwindow/unhandled_method_router_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/unhandled_method_router.dart';

void main() {
  test('pr_ 前缀走 presence，mw_ 前缀走 window，互不串线', () async {
    final seen = <String>[];
    Future<Object?> presence(String method, Object? arguments) async {
      seen.add('p:$method');
      return 'p-result';
    }

    Future<Object?> window(String method, Object? arguments) async {
      seen.add('w:$method');
      return 'w-result';
    }

    expect(
      await routeUnhandledMethod('pr_claim', null,
          presenceHandler: presence, windowHandler: window),
      'p-result',
    );
    expect(
      await routeUnhandledMethod('mw_open_tab', null,
          presenceHandler: presence, windowHandler: window),
      'w-result',
    );
    expect(seen, ['p:pr_claim', 'w:mw_open_tab']);
  });

  test('dp_ 与其他未知方法返回 null，不触达任一 handler', () async {
    var calls = 0;
    Future<Object?> noop(String method, Object? arguments) async {
      calls++;
      return null;
    }

    expect(
      await routeUnhandledMethod('dp_set', 1,
          presenceHandler: noop, windowHandler: noop),
      isNull,
    );
    expect(
      await routeUnhandledMethod('focus_tab', 'a_b',
          presenceHandler: noop, windowHandler: noop),
      isNull,
    );
    expect(calls, 0, reason: 'dp_ 由数据面自身 switch 先行，focus_tab 是子端方法');
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/unhandled_method_router_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现路由函数与窄接口**

`lib/app/multiwindow/window/unhandled_method_router.dart`：

```dart
/// 主引擎 method channel default 分支的协议族前缀路由。
/// dp_ 由 MainDataPlaneService 自身 switch 先行处理，不到这里；
/// pr_ 去账号面，mw_ 去窗口面，其余返回 null（dmw 对未处理方法回空）。
typedef UnhandledMethodHandler = Future<Object?> Function(
    String method, Object? arguments);

Future<Object?> routeUnhandledMethod(
  String method,
  Object? arguments, {
  required UnhandledMethodHandler presenceHandler,
  required UnhandledMethodHandler windowHandler,
}) async {
  if (method.startsWith('pr_')) {
    return presenceHandler(method, arguments);
  }
  if (method.startsWith('mw_')) {
    return windowHandler(method, arguments);
  }
  return null;
}
```

`lib/app/multiwindow/presence/handoff_controller.dart`：

```dart
/// WindowOpenService 对账号面无缝迁移能力的窄依赖：窗口层不具体依赖
/// presence/ipc 的 MainPresenceService。生产实现为 MainPresenceService，
/// 单测用内存 fake。
abstract class PresenceHandoffController {
  /// tab 未被 presence 跟踪（非抖音/未绑定）时返回 null，壳流程不等；
  /// 否则返回在目标窗 register 驱动 rehome（或 rehomeLocal）时结算的
  /// Future，10s 超时以异常失败，编排层按 spec §8 收口。
  Future<void>? prepareHandoff(String tabId, String destWindowId);

  /// 目标为主窗：摘远端死亡索引，并驱动网关把 tabId 端口换给主窗
  /// 本地控制器（控制器 onInit 的 bindTab 已先行完成）。
  Future<void> rehomeLocal(String tabId);
}
```

`main_presence_service.dart`：class 声明改为
`class MainPresenceService extends GetxService implements PresenceHandoffController {`，并加 import `import '../handoff_controller.dart';`（`prepareHandoff/rehomeLocal` 签名已与接口一致，不加 @override 也不触发 lint，勿顺手改动方法体）。

运行 `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/unhandled_method_router_test.dart`，全绿。

- [ ] **Step 4: 编排——先写失败测试**

`test/multiwindow/window_move_orchestration_test.dart`：

```dart
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/presence/handoff_controller.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

TabOpenRequest req(String site, String room, [String share = '']) =>
    TabOpenRequest(siteId: site, roomId: room, shareUrl: share);

class _Registry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _FakePort implements SubWindowPort {
  final created = <String, String>{};
  final invocations = <(String, String, Object?)>[];
  final StreamController<void> changedController =
      StreamController<void>.broadcast();
  Object? createError;
  Object? Function(String windowId, String method, Object? args)? onInvoke;
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    if (createError != null) throw createError!;
    final id = 'new${++_seq}';
    created[id] = argumentsJson;
    return SubWindowHandle(id);
  }

  @override
  Future<Object?> invoke(
      String windowId, String method, Object? arguments) async {
    invocations.add((windowId, method, arguments));
    return onInvoke?.call(windowId, method, arguments);
  }

  @override
  Future<List<String>> listWindowIds() async => const ['main'];

  @override
  Stream<void> get windowsChanged => changedController.stream;
}

/// mode：'immediate'（跟踪、rehome 立即成功）、'none'（非跟踪 null）、
/// 'timeout'（10s 定时器以异常失败）
class _FakeHandoff implements PresenceHandoffController {
  String mode = 'immediate';
  final prepares = <(String, String)>[];
  int rehomeLocalCount = 0;

  @override
  Future<void>? prepareHandoff(String tabId, String destWindowId) {
    prepares.add((tabId, destWindowId));
    if (mode == 'none') return null;
    if (mode == 'timeout') {
      final completer = Completer<void>();
      Timer(const Duration(seconds: 10),
          () => completer.completeError(StateError('timeout')));
      return completer.future;
    }
    return Future.value();
  }

  @override
  Future<void> rehomeLocal(String tabId) async {
    rehomeLocalCount++;
  }
}

void main() {
  late _FakePort port;
  late TabStore store;
  late WindowRegistry registry;
  late _FakeHandoff handoff;
  late WindowOpenService service;
  final toasts = <String>[];
  var focusMainCount = 0;

  WindowOpenService build() => WindowOpenService(
        port: port,
        store: store,
        registry: registry,
        presenceService: handoff,
        showToast: toasts.add,
        showAndFocusMain: () async => focusMainCount++,
      );

  setUp(() {
    Get.put<LocalStorageService>(InMemoryLocalStorageService(),
        permanent: true);
    Get.put<DBService>(InMemoryDBService(), permanent: true);
    port = _FakePort();
    store = TabStore(registry: _Registry());
    registry = WindowRegistry(mainWindowId: 'main');
    handoff = _FakeHandoff();
    service = build();
    service.onInit();
    toasts.clear();
    focusMainCount = 0;
  });

  tearDown(() async {
    service.onClose();
    await port.changedController.close();
    Get.reset();
  });

  List<(String, String, Object?)> calls(String windowId, String method) =>
      port.invocations.where((i) => i.$1 == windowId && i.$2 == method).toList();

  test('主→新窗：预定 tabId 建窗、登记 registry、关主窗源标签；不发 focus/close',
      () async {
    handoff.mode = 'none';
    final tab = store.open(req('douyin', 'a', 'http://a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );
    expect(message, isNull);

    expect(port.created.length, 1);
    final args =
        RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.tabId, tab.tabId);
    expect(args.tabs.single.roomId, 'a');
    expect(registry.tabsOf(port.created.keys.single), {'douyin_a'});
    expect(store.tabs, isEmpty);
    expect(port.invocations, isEmpty, reason: '新窗 bootstrap 自 show，无 IPC');
    expect(handoff.prepares, isEmpty, reason: '非跟踪不建 handoff');
    expect(toasts, isEmpty);
  });

  test('主→新窗（抖音跟踪）：prepareHandoff 目标为新窗 id', () async {
    final tab = store.open(req('douyin', 'a'));

    await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );

    expect(handoff.prepares.single.$1, tab.tabId);
    expect(handoff.prepares.single.$2, port.created.keys.single);
  });

  test('主→已存在子窗：mw_open_tab(activate:true) 后登记并 focus_tab',
      () async {
    handoff.mode = 'none';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_old'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, isNull);

    final openCalls = calls('w1', WindowControlProtocol.mOpenTab);
    expect(openCalls, hasLength(1));
    final open =
        WindowControlProtocol.decodeOpenTab(openCalls.single.$3)!;
    expect(open.tabId, tab.tabId);
    expect(open.activate, isTrue);
    expect(registry.tabsOf('w1'), {'douyin_old', 'douyin_a'});
    final focus = calls('w1', 'focus_tab').single;
    expect(focus.$3, 'douyin_a');
    expect(store.tabs, isEmpty);
  });

  test('子→已存在子窗：落目标、关源、moveChildTab、focus 目标', () async {
    handoff.mode = 'none';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_a'});
    registry.registerChild('w2', {'douyin_b'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: 'w2',
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    final close = calls('w1', WindowControlProtocol.mCloseTab).single;
    expect(WindowControlProtocol.decodeCloseTab(close.$3)!.tabId, 'ta');
    expect(registry.tabsOf('w1'), isEmpty, reason: '空窗保留待 reconcile/自关');
    expect(registry.tabsOf('w2'), {'douyin_a', 'douyin_b'});
    expect(calls('w2', 'focus_tab').single.$3, 'douyin_a');
    expect(toasts, isEmpty, reason: '子源成功不在主端 toast');
  });

  test('子→主窗：主窗预定 tabId 落标签、rehomeLocal、摘源登记、主窗置前',
      () async {
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetMain,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    expect(store.tabs.single.tabId, 'ta');
    expect(handoff.rehomeLocalCount, 1);
    expect(registry.tabsOf('w1'), isEmpty);
    expect(focusMainCount, 1, reason: '源是子窗才置前主窗');
    final close = calls('w1', WindowControlProtocol.mCloseTab).single;
    expect(WindowControlProtocol.decodeCloseTab(close.$3)!.tabId, 'ta');
  });

  test('子→新窗：建窗（预定 tabId）、关源、挪动登记；无 focus、不置前主窗',
      () async {
    handoff.mode = 'none';
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetNew,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    final newId = port.created.keys.single;
    expect(RoomWindowArgs.decode(port.created[newId]!).tabs.single.tabId,
        'ta');
    expect(registry.tabsOf('w1'), isEmpty);
    expect(registry.tabsOf(newId), {'douyin_a'});
    expect(calls(newId, 'focus_tab'), isEmpty);
    expect(focusMainCount, 0);
    expect(calls('w1', WindowControlProtocol.mCloseTab), hasLength(1));
  });

  test('失败：主源 descriptor 不存在', () async {
    final message = await service.moveTabToWindow(
      tabId: 'nope',
      target: 'w1',
    );
    expect(message, '未找到要移动的标签');
    expect(toasts, ['未找到要移动的标签'], reason: '主源失败在主端 toast');
    expect(port.invocations, isEmpty);
  });

  test('失败：子源缺 siteId/roomId 四元组', () async {
    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: 'w2',
    );
    expect(message, '未找到要移动的标签');
    expect(toasts, isEmpty, reason: '子源失败不主端 toast，文案随回执回子端');
  });

  test('失败：目标子窗未注册', () async {
    final tab = store.open(req('douyin', 'a'));
    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'wx',
    );
    expect(message, '目标窗口不存在');
    expect(toasts, ['目标窗口不存在']);
  });

  test('失败：createRoomWindow 抛错——toast 新建失败、不建 handoff、源不动',
      () async {
    port.createError = StateError('native');
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );
    expect(message, '新建窗口失败');
    expect(toasts, ['新建窗口失败']);
    expect(handoff.prepares, isEmpty, reason: '建窗先于 prepareHandoff');
    expect(store.tabs.single.tabId, tab.tabId);
    expect(registry.childCount, 0);
  });

  test('失败：mw_open_tab 回执 false——目标无响应、不登记、源不动', () async {
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab ? false : null;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '目标窗口无响应');
    expect(toasts, ['目标窗口无响应']);
    expect(registry.tabsOf('w1'), {'douyin_b'});
    expect(store.tabs.single.tabId, tab.tabId);
    expect(calls('w1', 'focus_tab'), isEmpty);
  });

  test('失败：mw_open_tab invoke 抛错（目标窗已死）同样收口', () async {
    port.onInvoke = (w, m, a) =>
        m == WindowControlProtocol.mOpenTab ? throw StateError('gone') : null;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '目标窗口无响应');
    expect(registry.tabsOf('w1'), {'douyin_b'});
    expect(store.tabs, hasLength(1));
  });

  test('源关闭 best-effort 失败不阻断：子→主仍成功、登记已挪、主窗置前',
      () async {
    port.onInvoke = (w, m, a) =>
        m == WindowControlProtocol.mCloseTab ? throw StateError('dead') : null;
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetMain,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);
    expect(registry.tabsOf('w1'), isEmpty);
    expect(focusMainCount, 1);
  });

  test('handoff 超时（新窗）：best-effort close_window、源标签保留、超时文案',
      () {
    fakeAsync((async) {
      handoff.mode = 'timeout';
      final tab = store.open(req('douyin', 'a'));
      final future = service.moveTabToWindow(
        tabId: tab.tabId,
        target: WindowControlProtocol.targetNew,
      );
      async.flushMicrotasks();
      final newId = port.created.keys.single;
      expect(calls(newId, 'close_window'), isEmpty, reason: '超时前不关');

      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();

      expect(calls(newId, 'close_window'), hasLength(1));
      expect(store.tabs.single.tabId, tab.tabId, reason: '源不动继续播放');
      expect(toasts.single, '移动超时，标签可能已在目标窗口');
      // future 已以失败文案完成（排空验证无悬挂）
      unawaited(future.then((message) {
        expect(message, '移动超时，标签可能已在目标窗口');
      }));
      async.flushMicrotasks();
    });
  });

  test('listMoveTargets：仅子窗、按开窗序编号、exclude 过滤', () {
    registry.registerChild('w1', {'a_1'});
    registry.registerChild('w2', {'a_2'});

    final all = service.listMoveTargets(excludeWindowId: null);
    expect(all.map((e) => e.id), ['w1', 'w2']);
    expect(all.map((e) => e.label), ['直播间窗口 1', '直播间窗口 2']);

    final filtered = service.listMoveTargets(excludeWindowId: 'w1');
    expect(filtered.single.id, 'w2');
  });

  test('handleWindowCall：mListWindows 主窗口固定符号项在前', () async {
    registry.registerChild('w1', {'a_1'});
    final raw = await service.handleWindowCall(
        WindowControlProtocol.mListWindows, null);
    final list = WindowControlProtocol.decodeWindowList(raw)!;
    expect(list.first.id, WindowControlProtocol.targetMain);
    expect(list.first.label, '主窗口');
    expect(list.last.id, 'w1');
    expect(list.last.label, '直播间窗口 1');
  });

  test('handleWindowCall：mRequestMove 子→主端到端回执 true', () async {
    registry.registerChild('w1', {'douyin_a'});
    final raw = await service.handleWindowCall(
      WindowControlProtocol.mRequestMove,
      WindowControlProtocol.encodeRequestMove(
        const WindowMoveCall(
          sourceWindowId: 'w1',
          tabId: 'ta',
          siteId: 'douyin',
          roomId: 'a',
          shareUrl: '',
          target: WindowControlProtocol.targetMain,
        ),
      ),
    );
    final result = WindowControlProtocol.decodeMoveResult(raw)!;
    expect(result.ok, isTrue);
    expect(store.tabs.single.tabId, 'ta');
  });

  test('handleWindowCall：非法载荷与未知方法', () async {
    final bad = await service.handleWindowCall(
        WindowControlProtocol.mRequestMove, null);
    expect(WindowControlProtocol.decodeMoveResult(bad)!.ok, isFalse);
    expect(
      await service.handleWindowCall('mw_unknown', null),
      isNull,
    );
  });
}
```

- [ ] **Step 5: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_move_orchestration_test.dart`
Expected: 编译失败（presenceService/moveTabToWindow 等不存在）。

- [ ] **Step 6: 实现编排**

`window_open_service.dart` 改动：

6a. import 区调整（保留既有 data_plane_protocol/db/local_storage；新增三项）：

```dart
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:window_manager/window_manager.dart';

import 'package:simple_live_app/app/multiwindow/presence/handoff_controller.dart';
```
以及与 window_args.dart 同区加：
```dart
import 'window_control_protocol.dart';
```

6b. 构造与字段（替换现有构造块 L65-77 区域，保留 port/store/registry 与 _windowsChangedSub/_childWindowsClosed 全部既有字段）：

```dart
  WindowOpenService({
    required this.port,
    required this.store,
    required this.registry,
    this.presenceService,
    void Function(String message)? showToast,
    Future<void> Function()? showAndFocusMain,
  })  : _showToast = showToast ?? SmartDialog.showToast,
        _focusMainOverride = showAndFocusMain;

  final SubWindowPort port;
  final TabStore store;
  final WindowRegistry registry;

  /// MPS 构造晚于本服务：app_pages 装配 MainPresenceService 后后绑。
  PresenceHandoffController? presenceService;

  final void Function(String message) _showToast;
  final Future<void> Function()? _focusMainOverride;

  Future<void> _showAndFocusMain() async {
    final override = _focusMainOverride;
    if (override != null) {
      await override();
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }
```

6c. **删除**整个旧 `moveTabToNewWindow` 方法（含其上方三行文档注释）。

6d. 在 `requestCloseAllChildren` 之前插入编排方法（逐字）：

```dart
  /// 主窗右键菜单候选：仅已存在子窗（主窗自身不作为主窗发起的目标）。
  List<WindowListEntry> listMoveTargets({required String? excludeWindowId}) {
    return [
      for (final e in registry.childWindowOrder())
        if (e.id != excludeWindowId)
          WindowListEntry(id: e.id, label: '直播间窗口 ${e.ordinal}'),
    ];
  }

  /// mw_list_windows 回执：主窗口固定符号项 + 全部子窗（开窗序编号）。
  List<WindowListEntry> listWindowEntries() => [
        const WindowListEntry(
            id: WindowControlProtocol.targetMain, label: '主窗口'),
        ...listMoveTargets(excludeWindowId: null),
      ];

  Future<Object?> handleWindowCall(String method, Object? arguments) async {
    switch (method) {
      case WindowControlProtocol.mRequestMove:
        final call =
            WindowControlProtocol.decodeRequestMove(arguments);
        if (call == null) {
          return WindowControlProtocol.encodeMoveResult(false,
              message: '移动失败，请重试');
        }
        final message = await moveTabToWindow(
          tabId: call.tabId,
          sourceWindowId: call.sourceWindowId,
          target: call.target,
          siteId: call.siteId,
          roomId: call.roomId,
          shareUrl: call.shareUrl,
        );
        return WindowControlProtocol.encodeMoveResult(message == null,
            message: message);
      case WindowControlProtocol.mListWindows:
        return WindowControlProtocol.encodeWindowList(listWindowEntries());
      default:
        return null;
    }
  }

  /// 跨窗迁移标签。null=成功；非空=固定中文失败文案（禁止回显异常对象）。
  /// 主窗发起（sourceWindowId==null）失败在主窗 toast；子窗发起只返回文案，
  /// 由 mw_request_move 回执送子端 toast（跨引擎 SmartDialog 不共享）。
  Future<String?> moveTabToWindow({
    required String tabId,
    String? sourceWindowId,
    required String target,
    String? siteId,
    String? roomId,
    String? shareUrl,
  }) async {
    final fromMain = sourceWindowId == null;

    String? fail(String message) {
      if (fromMain) _showToast(message);
      return message;
    }

    // 1. 取请求四元组（tabId 为权威身份，presence 全程不换）
    TabOpenRequest? request;
    if (fromMain) {
      request = store.tabs
          .firstWhereOrNull((t) => t.tabId == tabId)
          ?.request;
    } else if (siteId != null && roomId != null) {
      request = TabOpenRequest(
          siteId: siteId, roomId: roomId, shareUrl: shareUrl ?? '');
    }
    final req0 = request;
    if (req0 == null) {
      return fail('未找到要移动的标签');
    }
    final tabKey = req0.key;

    // 2. 解析目标；__new__ 此刻创建进程（早于 prepareHandoff：创建失败
    //    时根本没有 handoff 需要取消，spec §8）
    var destIsNew = false;
    var destIsMain = false;
    var destWindowId = '';
    if (target == WindowControlProtocol.targetMain) {
      destIsMain = true;
      destWindowId = registry.mainWindowId;
    } else if (target == WindowControlProtocol.targetNew) {
      destIsNew = true;
      try {
        final handle = await port.createRoomWindow(
          RoomWindowArgs(
            mainWindowId: DmwSubWindowPort.mainWindowId ?? '',
            tabs: [
              RoomTabArg(
                siteId: req0.siteId,
                roomId: req0.roomId,
                shareUrl: req0.shareUrl,
                tabId: tabId,
              ),
            ],
            snapshot: WindowSnapshotBuilder.buildDataSnapshot(),
          ).encode(),
        );
        destWindowId = handle.windowId;
        // 新窗空集覆盖式登记（registerChild 语义）
        registry.registerChild(handle.windowId, {tabKey});
      } catch (_) {
        return fail('新建窗口失败');
      }
    } else {
      if (!registry.childWindowIds.contains(target)) {
        return fail('目标窗口不存在');
      }
      destWindowId = target;
    }

    // 3. presence 无缝 handoff（非抖音/未跟踪得 null，壳流程不等）
    final handoff =
        presenceService?.prepareHandoff(tabId, destWindowId);

    // 4. 目标落标签
    if (destIsMain) {
      // 主窗控制器在 store.open 同步头内 onInit→bindTab，先于 rehomeLocal
      store.open(req0, tabId: tabId);
      try {
        await presenceService?.rehomeLocal(tabId);
      } catch (_) {
        // 本地复刻失败不阻断壳迁移：pending 补放/写动作 claim 自愈（spec §8）
      }
    } else {
      if (!destIsNew) {
        Object? accepted;
        try {
          accepted = await port.invoke(
            destWindowId,
            WindowControlProtocol.mOpenTab,
            WindowControlProtocol.encodeOpenTab(
              OpenTabCall(
                tabId: tabId,
                siteId: req0.siteId,
                roomId: req0.roomId,
                shareUrl: req0.shareUrl,
                activate: true,
              ),
            ),
          );
        } catch (_) {
          accepted = false;
        }
        if (accepted != true) {
          // 不登记 registry；handoff 由 10s 超时自清；源不动（spec §8）
          return fail('目标窗口无响应');
        }
        registry.addChildTab(destWindowId, tabKey);
      }
      // new 的 pr_register 与 child 的 register 均已在途：等 rehome 结算
      if (handoff != null) {
        try {
          await handoff;
        } catch (_) {
          if (destIsNew) {
            // 无法确认新窗状态：best-effort 关窗（成功则 reconcile 摘表）
            try {
              await port.invoke(destWindowId, 'close_window', null);
            } catch (_) {}
          }
          // child：保守保留目标标签（其 store.open 已成功），源不动
          return fail('移动超时，标签可能已在目标窗口');
        }
      }
    }

    // 5. 关源（best-effort：源窗若已死，reconcile 兜底）
    if (fromMain) {
      store.closeForMove(tabId);
    } else {
      try {
        await port.invoke(
          sourceWindowId,
          WindowControlProtocol.mCloseTab,
          WindowControlProtocol.encodeCloseTab(
              CloseTabCall(tabId: tabId)),
        );
      } catch (_) {}
    }

    // 6. registry 挪动（主窗标签不在 registry；新窗步骤 2 已登记）
    if (!fromMain) {
      if (destIsMain) {
        registry.removeChildTab(sourceWindowId, tabKey);
      } else {
        registry.moveChildTab(sourceWindowId, destWindowId, tabKey);
      }
    }

    // 7. 聚焦：新窗 bootstrap 自 show；已存在子窗发 focus_tab；
    //    主窗仅在源是子窗时置前
    if (destIsMain) {
      if (!fromMain) {
        try {
          await _showAndFocusMain();
        } catch (_) {}
      }
    } else if (!destIsNew) {
      try {
        await port.invoke(destWindowId, 'focus_tab', tabKey);
      } catch (_) {}
    }
    return null;
  }
```

注意：`port.invoke(sourceWindowId, ...)` 中 sourceWindowId 为可空局部，Dart 在 `else`（fromMain==false）分支内不做提升——此处可空形参在闭包/方法调用处同样不提升，写 `sourceWindowId!`（该分支语义上必非空；若分析器要求，逐字改为 `sourceWindowId!`）。

- [ ] **Step 7: 运行确认通过 + 替换旧调用点与旧用例**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_move_orchestration_test.dart test/multiwindow/unhandled_method_router_test.dart`
Expected: 全绿。

`window_open_service_test.dart` 删除整个旧用例（moveTabToNewWindow 已不存在）：

```dart
  test('移到新窗口：创建子窗后关闭本窗标签', () async {
    final tab = store.open(req('douyin', 'a', 'http://a'));
    await service.moveTabToNewWindow(tab.tabId);

    expect(port.created.length, 1);
    final args = RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.shareUrl, 'http://a');
    expect(store.tabs, isEmpty);
  });
```

`tab_strip.dart` 仅替换 case 调用点（菜单结构 T8 再改），并加 import
`import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';`：

```dart
      case 'move_window':
        unawaited(
          WindowOpenService.instance.moveTabToWindow(
            tabId: descriptor.tabId,
            target: WindowControlProtocol.targetNew,
          ),
        );
```

- [ ] **Step 8: app_pages 接线**

`routes/app_pages.dart` import 区加：

```dart
import 'package:simple_live_app/app/multiwindow/window/unhandled_method_router.dart';
```

把 Windows 壳装配段（现 L105-137）改为：WOS 接变量、MPS 后绑 presenceService、MDP 走前缀路由闭包：

```dart
          final windowOpenService = Get.put(
            WindowOpenService(
              port: subWindowPort,
              store: Get.find<TabStore>(),
              registry: windowRegistry,
            ),
            permanent: true,
          );
          // MainPresenceService 必须先于任何开窗：onInit 即订阅
          // onChildWindowsClosed（broadcast 不补发历史），故紧随
          // WindowOpenService 构造；pr_/mw_ 流量经数据面 default 分支
          // 前缀路由委托进入，presence 不另挂 setWindowMethodHandler
          final mainPresenceService = Get.put(
            MainPresenceService(
              gateway: Get.find<DouyinPresenceGateway>(),
              port: subWindowPort,
              windowOpenService: windowOpenService,
            ),
            permanent: true,
          );
          // WOS 构造早于 MPS：后绑 handoff 能力
          windowOpenService.presenceService = mainPresenceService;
          Get.put(
            MainDataPlaneService(
              port: subWindowPort,
              registry: windowRegistry,
              storage: LocalStorageService.instance,
              db: DBService.instance,
              onSettingsChanged: () =>
                  AppSettingsController.instance.reloadFromStorage(),
              mainController: DmwSubWindowPort.mainController,
              unhandledMethodHandler: (method, arguments) =>
                  routeUnhandledMethod(
                method,
                arguments,
                presenceHandler: mainPresenceService.handleCall,
                windowHandler: windowOpenService.handleWindowCall,
              ),
            ),
            permanent: true,
          );
```

- [ ] **Step 9: 全量门禁 + Windows 编译 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22，零新增）；
`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿；本任务删 1 旧用例、新增 router 2 例 + orchestration 约 19 例，总数在 280+T1..T6 净增值上继续净增）。
接线任务必须 `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`（预期仅编译验证）。

```bash
git add simple_live_app/lib/app/multiwindow/window/sub_window_port.dart simple_live_app/lib/app/multiwindow/window/dmw_sub_window_port.dart simple_live_app/lib/app/multiwindow/window/window_open_service.dart simple_live_app/lib/app/multiwindow/window/unhandled_method_router.dart simple_live_app/lib/app/multiwindow/presence/handoff_controller.dart simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart simple_live_app/lib/app/multiwindow/shell/tab_strip.dart simple_live_app/lib/routes/app_pages.dart simple_live_app/test/multiwindow/unhandled_method_router_test.dart simple_live_app/test/multiwindow/window_move_orchestration_test.dart simple_live_app/test/multiwindow/window_open_service_test.dart simple_live_app/test/multiwindow/main_presence_service_test.dart simple_live_app/test/multiwindow/main_data_plane_service_test.dart simple_live_app/test/multiwindow/main_presence_handoff_test.dart
git commit -m "feat(multiwindow): 标签跨窗迁移主端编排与 mw_ 协议路由

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

### Task 8: 右键移动菜单（新窗口 / 其他窗口级联）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/shell/tab_move_menu.dart`（菜单决策/构建/value 编解码纯函数，无 GetX/UI 状态）
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart`（imports；`_showMenu` 重写：移除账号置灰与 Tooltip、主/子窗移动区、二级菜单）
- Test: Create: `simple_live_app/test/tab_move_menu_test.dart`（纯函数）
- Test: Create: `simple_live_app/test/multiwindow/tab_strip_move_menu_test.dart`（widget：spec §9-9）
- Ruling：`tab_move_menu.dart` 不在 spec §12 文件清单的具名行内，但属该行 `shell/tab_strip.dart（菜单）` 的文件内拆分（File Structure 决策）；§12 是「任务划分依据」非穷举（已含「对应测试文件」兜底行），不视为 spec 偏差。

**Interfaces:**
- Consumes：T6 `SubWindowControlService.instance/windowId/requestWindowList/requestMove`；T7 `WindowOpenService.instance.listMoveTargets/moveTabToWindow`、`WindowListEntry`；T1 `WindowControlProtocol.targetNew`。
- Produces（命名锁定）：
  - `enum MoveMenuHost { none, main, sub }`
  - `abstract final class TabMoveMenu`（私有构造）：
    - `static const String moveNew = 'move_new';`
    - `static const String moveOthers = 'move_others';`
    - `static String moveTo(String target) => 'move_to:$target';`
    - `static String? decodeMoveTarget(String? value)`（moveNew→`'__new__'`；`move_to:<id>`→id；其余 null）
    - `static MoveMenuHost resolveMoveMenuHost({required bool isWindows, required bool isSubWindow, required bool windowServiceRegistered, required bool controlServiceRegistered})`
    - `static List<PopupMenuEntry<String>> buildMoveEntries({required bool hasTargets})`（恒含「移到新窗口」；hasTargets 时追加「移到其他窗口」）
    - `static List<PopupMenuEntry<String>> buildTargetEntries(List<WindowListEntry> targets)`（disabled 标题项 + 每窗一项）
  - 固定文案：一级 `'移到新窗口'`、`'移到其他窗口'`；二级标题 `'移到其他窗口'`；空候选 toast `'没有可移入的其他窗口'`。
- 交互（spec §7.6，逐字落实）：主窗一级「其他窗口」仅当 `listMoveTargets(excludeWindowId: null)` 非空才出现；子窗一级始终有该项，点击后 `await requestWindowList()`、排除自己 windowId，空则 toast、非空弹二级（主窗口+其他子窗）；选定后主窗 `moveTabToWindow(sourceWindowId:null)`、子窗 `requestMove`。账号态不再置灰。非 Windows/服务缺失：零移动条目（行为同 M4-1）。

- [ ] **Step 1: 写失败测试**

`test/tab_move_menu_test.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_move_menu.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

void main() {
  group('resolveMoveMenuHost', () {
    test('非 Windows 恒 none，即使服务齐备', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: false,
          isSubWindow: false,
          windowServiceRegistered: true,
          controlServiceRegistered: true,
        ),
        MoveMenuHost.none,
      );
    });

    test('主窗：注册 WOS 为 main，未注册为 none', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: false,
          windowServiceRegistered: true,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.main,
      );
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: false,
          windowServiceRegistered: false,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.none,
      );
    });

    test('子窗：注册控制服务为 sub，未注册为 none', () {
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: true,
          windowServiceRegistered: false,
          controlServiceRegistered: true,
        ),
        MoveMenuHost.sub,
      );
      expect(
        TabMoveMenu.resolveMoveMenuHost(
          isWindows: true,
          isSubWindow: true,
          windowServiceRegistered: false,
          controlServiceRegistered: false,
        ),
        MoveMenuHost.none,
      );
    });
  });

  group('buildMoveEntries', () {
    test('恒有「移到新窗口」；hasTargets 决定「其他窗口」', () {
      final withTargets = TabMoveMenu.buildMoveEntries(hasTargets: true);
      expect(withTargets, hasLength(2));
      expect((withTargets[0] as PopupMenuItem<String>).value,
          TabMoveMenu.moveNew);
      expect((withTargets[1] as PopupMenuItem<String>).value,
          TabMoveMenu.moveOthers);

      final noTargets = TabMoveMenu.buildMoveEntries(hasTargets: false);
      expect(noTargets, hasLength(1));
      final newItem = noTargets.single as PopupMenuItem<String>;
      expect(newItem.value, TabMoveMenu.moveNew);
      expect(newItem.enabled, isTrue,
          reason: '账号态置灰已删除：新窗口项对任何标签恒可点');
    });
  });

  group('buildTargetEntries', () {
    test('disabled 标题 + 每窗一项，value 经 moveTo 编码、文本为 label', () {
      final entries = TabMoveMenu.buildTargetEntries(const [
        WindowListEntry(id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
      expect(entries, hasLength(3));
      final header = entries[0] as PopupMenuItem<String>;
      expect(header.enabled, isFalse);
      expect((entries[1] as PopupMenuItem<String>).value,
          TabMoveMenu.moveTo(WindowControlProtocol.targetMain));
      expect((entries[2] as PopupMenuItem<String>).value,
          TabMoveMenu.moveTo('w2'));
    });
  });

  group('decodeMoveTarget', () {
    test('新窗口/具体窗解码；无关 value 返回 null', () {
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveNew),
          WindowControlProtocol.targetNew);
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveTo('w2')), 'w2');
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveTo('__main__')),
          WindowControlProtocol.targetMain);
      expect(TabMoveMenu.decodeMoveTarget(TabMoveMenu.moveOthers), isNull);
      expect(TabMoveMenu.decodeMoveTarget('close'), isNull);
      expect(TabMoveMenu.decodeMoveTarget(null), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行确认失败**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/tab_move_menu_test.dart`
Expected: 编译失败。

- [ ] **Step 3: 实现纯函数层**

`lib/app/multiwindow/shell/tab_move_menu.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

/// 右键移动菜单的宿主形态：主窗（WOS 编排）/ 子窗（控制服务转发）/ 无菜单。
enum MoveMenuHost { none, main, sub }

/// 跨窗移动菜单的纯决策/构建层：不碰 GetX 与遥控器，tab_strip 只做组装
/// 与服务调用；级联交互（点「其他窗口」后拉列表再弹二级）在 widget 侧。
abstract final class TabMoveMenu {
  static const String moveNew = 'move_new';
  static const String moveOthers = 'move_others';
  static const String _moveToPrefix = 'move_to:';

  static String moveTo(String target) => '$_moveToPrefix$target';

  /// 一级/二级 value → target 线值；非移动类菜单 value 一律 null。
  static String? decodeMoveTarget(String? value) {
    if (value == moveNew) return WindowControlProtocol.targetNew;
    if (value != null && value.startsWith(_moveToPrefix)) {
      return value.substring(_moveToPrefix.length);
    }
    return null;
  }

  static MoveMenuHost resolveMoveMenuHost({
    required bool isWindows,
    required bool isSubWindow,
    required bool windowServiceRegistered,
    required bool controlServiceRegistered,
  }) {
    if (!isWindows) return MoveMenuHost.none;
    if (isSubWindow) {
      return controlServiceRegistered
          ? MoveMenuHost.sub
          : MoveMenuHost.none;
    }
    return windowServiceRegistered ? MoveMenuHost.main : MoveMenuHost.none;
  }

  /// 一级菜单移动区：「移到新窗口」恒有；「移到其他窗口」仅在确有候选时。
  /// 子窗候选需异步拉取，调用方恒传 true（点击后空列表改 toast）。
  static List<PopupMenuEntry<String>> buildMoveEntries({
    required bool hasTargets,
  }) =>
      [
        const PopupMenuItem<String>(
          value: moveNew,
          child: Text('移到新窗口'),
        ),
        if (hasTargets)
          const PopupMenuItem<String>(
            value: moveOthers,
            child: Text('移到其他窗口'),
          ),
      ];

  /// 二级菜单：disabled 标题 + 目标窗口项。
  static List<PopupMenuEntry<String>> buildTargetEntries(
    List<WindowListEntry> targets,
  ) =>
      [
        const PopupMenuItem<String>(
          enabled: false,
          child: Text('移到其他窗口'),
        ),
        for (final entry in targets)
          PopupMenuItem<String>(
            value: moveTo(entry.id),
            child: Text(entry.label),
          ),
      ];
}
```

- [ ] **Step 4: 运行确认通过**

`C:/tools/flutter347/flutter/bin/flutter.bat test test/tab_move_menu_test.dart`
Expected: 全绿。

- [ ] **Step 5: 写 widget 失败测试（spec §9-9）**

`test/multiwindow/tab_strip_move_menu_test.dart`：覆盖 spec §9 第 9 条——主窗菜单（恒可点、有子窗出级联）、子窗走 controlService（拉列表/排除自己/发 mw_request_move）、服务缺失零移动项、空候选 toast。

环境约束（写入文件头注释）：用例依赖开发/门禁机 `Platform.isWindows == true`（dart:io Platform 在 flutter test 不可 override）；非 Windows 分支由 `tab_move_menu_test.dart` 的 `resolveMoveMenuHost(isWindows:false)` 纯函数用例覆盖。tab_strip 既有无测试文件（已 glob 核实，不存在 test/**/*tab_strip*），无既有 widget 断言需要回归。

```dart
// widget 覆盖：主窗/子窗移动菜单结构与服务路由。
// 环境：仅在 Windows 开发/门禁机运行（Platform.isWindows 不可 override）；
// 非 Windows 分支由 test/tab_move_menu_test.dart 纯函数用例覆盖。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_strip.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class _RoomRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

/// T7 之后的 SubWindowPort（invoke 返回 Object?）；菜单测试不触发真编排，
/// 所有方法给空闲实现。
class _IdlePort implements SubWindowPort {
  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async =>
      const SubWindowHandle('wX');
  @override
  Future<Object?> invoke(
      String windowId, String method, Object? arguments) async {
    return null;
  }
  @override
  Future<List<String>> listWindowIds() async => const ['w2'];
  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();
}

class _ControlPort implements SubWindowControlPort {
  final List<(String, Object?)> invokes = [];
  Object? result;
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    invokes.add((method, arguments));
    return result;
  }
}

const _home = Scaffold(
  body: Align(alignment: Alignment.topCenter, child: TabStrip()),
);

Widget _app({bool withSmartDialog = false}) {
  if (withSmartDialog) {
    return GetMaterialApp(
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: _home,
    );
  }
  return const GetMaterialApp(home: _home);
}

Future<void> _openContextMenu(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('r1')),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void putRoomAndTab() {
  final roomRegistry = _RoomRegistry();
  final store = TabStore(registry: roomRegistry);
  store.open(TabOpenRequest(siteId: 'douyin', roomId: 'r1'));
  Get.put<RoomControllerRegistry>(roomRegistry, permanent: true);
  Get.put<TabStore>(store, permanent: true);
}

void main() {
  tearDown(() {
    MultiWindowRole.isSubWindow = false;
    Get.reset();
  });

  testWidgets('主窗：有「移到新窗口」且恒 enabled；无子窗时无「其他窗口」',
      (tester) async {
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final windows = WindowRegistry(mainWindowId: 'main');
    Get.put<WindowOpenService>(
      WindowOpenService(
          port: _IdlePort(), store: store, registry: windows),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    expect(find.text('移到新窗口'), findsOneWidget);
    expect(find.text('移到其他窗口'), findsNothing);
    final item = tester.widget<PopupMenuItem<String>>(
      find
          .ancestor(
            of: find.text('移到新窗口'),
            matching: find.byType(PopupMenuItem<String>),
          )
          .first,
    );
    expect(item.enabled, isTrue, reason: '账号态置灰已删除：任何标签恒可点');
  });

  testWidgets('主窗有子窗：点「移到其他窗口」弹二级列表，编号 1 起',
      (tester) async {
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final windows = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w2', const {'douyin_other'});
    Get.put<WindowOpenService>(
      WindowOpenService(
          port: _IdlePort(), store: store, registry: windows),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);
    expect(find.text('移到其他窗口'), findsOneWidget);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pumpAndSettle();

    expect(find.text('直播间窗口 1'), findsOneWidget);
  });

  testWidgets('未注册任何窗口服务：零移动项，既有菜单不变', (tester) async {
    putRoomAndTab();
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    expect(find.text('移到新窗口'), findsNothing);
    expect(find.text('移到其他窗口'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('复制房间链接'), findsOneWidget);
  });

  testWidgets('子窗：点「其他窗口」经 controlService 拉列表，二级排除自己',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeWindowList(const [
        WindowListEntry(
            id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w1', label: '直播间窗口 1'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);
    expect(find.text('移到新窗口'), findsOneWidget);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pumpAndSettle();

    expect(control.invokes.first.$1,
        WindowControlProtocol.mListWindows);
    expect(find.text('主窗口'), findsOneWidget);
    expect(find.text('直播间窗口 2'), findsOneWidget);
    expect(find.text('直播间窗口 1'), findsNothing,
        reason: '自己 windowId 必须排除');
  });

  testWidgets('子窗点「移到新窗口」：发出 mw_request_move（源/标签/目标齐全）',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeMoveResult(true);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    await tester.tap(find.text('移到新窗口'));
    await tester.pumpAndSettle();

    expect(control.invokes.single.$1,
        WindowControlProtocol.mRequestMove);
    final call =
        WindowControlProtocol.decodeRequestMove(control.invokes.single.$2)!;
    expect(call.sourceWindowId, 'w1');
    expect(call.tabId, store.tabs.single.tabId);
    expect(call.target, WindowControlProtocol.targetNew);
  });

  testWidgets('子窗候选为空：toast 提示且不弹二级', (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeWindowList(const []);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app(withSmartDialog: true));
    await _openContextMenu(tester);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pump();
    expect(find.text('没有可移入的其他窗口'), findsOneWidget);

    // 排空 SmartDialog toast 残留 Timer（同
    // sub_window_presence_controller_test 的清理时序）
    final dismiss = SmartDialog.dismiss(status: SmartStatus.toast);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await dismiss;
  });
}
```

- [ ] **Step 6: 运行确认失败，然后重写 tab_strip `_showMenu`**

先跑：

`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/tab_strip_move_menu_test.dart`
Expected: 编译失败/找不到移动项（TabMoveMenu、SubWindowControlService 尚不存在或菜单未重写）。

import 区调整：新增（按现有 import 分组，package 区字母序）：

```dart
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
```

同目录相对 import 区加：

```dart
import 'tab_move_menu.dart';
```

`window_control_protocol.dart`：Task 7 已加入；本方法重写后仍直接引用 `WindowListEntry` 类型标注，**必须保留，不得删除**。`window_open_service.dart`/`window_role.dart` 既有保留。

把 `_showMenu` 方法整体替换为：

```dart
  Future<void> _showMenu(BuildContext context, Offset position) async {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rel = RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    );

    // M4-4：主窗经 WOS 本地编排，子窗经控制服务转发主端；账号态可直接迁移
    // （presence 无缝 handoff），不再置灰
    final host = TabMoveMenu.resolveMoveMenuHost(
      isWindows: Platform.isWindows,
      isSubWindow: MultiWindowRole.isSubWindow,
      windowServiceRegistered: Get.isRegistered<WindowOpenService>(),
      controlServiceRegistered:
          Get.isRegistered<SubWindowControlService>(),
    );
    final mainTargets = host == MoveMenuHost.main
        ? WindowOpenService.instance
            .listMoveTargets(excludeWindowId: null)
        : const <WindowListEntry>[];

    final items = <PopupMenuEntry<String>>[
      const PopupMenuItem(value: 'close', child: Text('关闭')),
      const PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
      const PopupMenuItem(value: 'right', child: Text('关闭右侧标签')),
      if (host != MoveMenuHost.none)
        ...TabMoveMenu.buildMoveEntries(
          hasTargets: host == MoveMenuHost.sub || mainTargets.isNotEmpty,
        ),
      const PopupMenuItem(value: 'copy', child: Text('复制房间链接')),
    ];

    final value = await showMenu<String>(
      context: context,
      position: rel,
      items: items,
    );
    if (value == null) return;

    // 「其他窗口」：主窗用同步候选；子窗点击后拉列表（排除自己），
    // 空列表 toast，非空在原位弹二级
    String? moveTarget = TabMoveMenu.decodeMoveTarget(value);
    if (value == TabMoveMenu.moveOthers) {
      final List<WindowListEntry> targets;
      if (host == MoveMenuHost.main) {
        targets = mainTargets;
      } else {
        final control = SubWindowControlService.instance;
        final all = await control.requestWindowList();
        targets =
            all.where((e) => e.id != control.windowId).toList(growable: false);
      }
      if (targets.isEmpty) {
        SmartDialog.showToast('没有可移入的其他窗口');
        return;
      }
      final second = await showMenu<String>(
        context: context,
        position: rel,
        items: TabMoveMenu.buildTargetEntries(targets),
      );
      if (second == null) return;
      moveTarget = TabMoveMenu.decodeMoveTarget(second);
    }

    if (moveTarget != null) {
      if (host == MoveMenuHost.sub) {
        unawaited(
          SubWindowControlService.instance.requestMove(
            tab: descriptor,
            target: moveTarget,
          ),
        );
      } else if (host == MoveMenuHost.main) {
        unawaited(
          WindowOpenService.instance.moveTabToWindow(
            tabId: descriptor.tabId,
            target: moveTarget,
          ),
        );
      }
      return;
    }

    switch (value) {
      case 'close':
        store.close(descriptor.tabId);
      case 'others':
        unawaited(store.closeOthers(descriptor.tabId));
      case 'right':
        unawaited(store.closeRight(descriptor.tabId));
      case 'copy':
        // 优先复制控制器已加载的真实房间链接，避免 shareUrl 为空时复制裸 roomId
        String? realUrl;
        if (registry.isRegistered(descriptor.tabId)) {
          realUrl = Get.find<LiveRoomController>(tag: descriptor.tabId)
              .detail
              .value
              ?.url;
        }
        final r = descriptor.request;
        Utils.copyToClipboard(
          (realUrl != null && realUrl.isNotEmpty)
              ? realUrl
              : (r.shareUrl.isNotEmpty ? r.shareUrl : r.roomId),
        );
    }
  }
```

注意：
- 删除原 `isAccount`/`moveChild`/Tooltip/未使用的 `controller` 局部（「账号跨窗在下一阶段支持」不再出现；LiveRoomController import 仍被 copy 分支与 `_TabItem.build` 使用，保留）。
- Task 7 在本文件临时加入的 `case 'move_window'` 与对 `moveTabToNewWindow` 的调用随本次整体替换消失；`move_window` value 不再存在。
- 跑两个测试文件确认全绿：`flutter.bat test test/tab_move_menu_test.dart test/multiwindow/tab_strip_move_menu_test.dart`。

- [ ] **Step 7: 全量门禁 + Windows 编译 + commit**

`C:/tools/flutter347/flutter/bin/flutter.bat analyze`（≤22，零新增）；
`C:/tools/flutter347/flutter/bin/flutter.bat test`（全绿，本任务新增纯函数 6 例 + widget 6 例，只增不减）；
接线任务必须 `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`。
菜单的真实点击手感/级联定位/多窗编号实机表现仍列入 spec §10 GUI 手工清单（第 1–5、8 项），执行者不得声称已过。

```bash
git add simple_live_app/lib/app/multiwindow/shell/tab_move_menu.dart simple_live_app/lib/app/multiwindow/shell/tab_strip.dart simple_live_app/test/tab_move_menu_test.dart simple_live_app/test/multiwindow/tab_strip_move_menu_test.dart
git commit -m "feat(shell): 跨窗移动右键菜单（新窗口与其他窗口级联）

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

## Self-Review（writing-plans 收尾自检）

- [ ] spec §1–§12 逐节覆盖核对：T1=§6 协议；T2=§4 网关 rehome/§4.3 端口；T3=§5 主端 handoff；T4=§7.3；T5=§7.2；T6=§7.4；T7=§7.1/§7.5/§8；T8=§7.6；测试=§9（第 9 条 TabStrip 由 T8 纯函数 6 例 + widget 6 例覆盖：账号态恒可点=enabled 断言、有子窗出级联、子窗走 controlService=mRequestMove 载荷断言、服务缺失零项；非 Windows 平台分支因 dart:io Platform 不可 override 仅由 resolveMoveMenuHost(isWindows:false) 纯函数覆盖，已在测试头注释说明）；GUI=§10（不纳入自动执行）；Ruling §11 在 T3/T7 计划与终审核对；§12 文件清单与各任务 Files 一致，T8 新增 `tab_move_menu.dart` 属 §12「tab_strip（菜单）」拆分（Ruling 已记 T8 Files）。
- [ ] placeholder 扫描：无 TBD/TODO/「类似 Task N」；每个代码步骤均逐字给码。
- [ ] 跨任务类型一致性：invoke 全线 Object?（T7 Step 0 四 fake 同步；T8 widget 的 _IdlePort 按 T7 后接口实现）；tabId 全线 String；MoveResult.message String?；mw_ 载荷无凭据字段（T6/T7 实现逐字检查 encode 内容仅协议字段）；toast 文案与 spec §8/§7.6 逐字一致（'移动失败，请重试'、'没有可移入的其他窗口'）。
- [ ] 既有行为零回归：非 Windows 不注册新服务（bootstrap 门控 + resolveMoveMenuHost none）；无 tabId 旧 JSON 兼容（T4 测试）；bili/huya 发送直连不经 mw_/presence；22 条 analyze 基线与 280 测试基线逐任务门禁；tab_strip 无既有测试文件（glob `test/**/*tab_strip*` 已核实为空），「既有断言不回归」对应该文件 M4-1 既有四条菜单 value（close/others/right/copy）在 T8 widget「服务缺失零移动项」用例中全部断言仍在。
- [ ] T3 测试两处夹具缺陷已在计划内修正（_FakeTab 真 detail + setUp fetcher/reader；主→子用例先本地 gateway.claim）。
- [ ] T8 事实核对（写计划时读码确认）：TabDescriptor.title 初值=roomId（widget 测试用 find.text('r1') 定位）；RoomControllerRegistry 接口 5 方法（register/unregister/isRegistered/controllerForRoomKey/controllerForTabId）；WindowRegistry.registerChild(id, Set<String>) 为 T5 前既有方法；WOS 现有 static instance getter 与 3 必选构造（T7 加 3 可选）；SubWindowControlService.instance/windowId/requestWindowList/requestMove 命名与 T6 一致；encode/decode 命名（encodeWindowList/decodeRequestMove/encodeMoveResult）与 T1 一致。




