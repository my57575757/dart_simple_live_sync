# M3：抖音登录心跳全局仲裁（DouyinPresenceGateway + 意图栈）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 单引擎（主窗）内把抖音账号态进房 / 心跳 / 退房收口到唯一网关：全应用只有一个心跳 Timer，多抖音标签按"最后打开"仲裁持有者，持有者关闭后更早的账号标签自动回退接管，被让位标签播放不中断并降级游客弹幕。

**Architecture:** 三层：①`PresenceArbiter` 纯 Dart 意图栈状态机（无 Flutter/GetX/HTTP，表驱动可测）；②`DouyinPresenceGateway` 组合 `GuardServerService`，持有唯一 20s 心跳 Timer、claimant 表，执行 ensureAccount/enterRoom/heartbeat/exitRoom/reregister，账号详情取数经 `DouyinPresenceTab` 端口；③控制器侧 `LocalPresenceClient`（薄代理）+ `_ControllerPresenceTab`（端口适配器）。Android / 无壳路径（`tabId == null`）完全保留控制器内现有实现，零行为变化。M4 子引擎时仅把 LocalPresenceClient 换成 IPC 实现，控制器无分支差异。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4（`C:/tools/flutter347/flutter/bin/flutter`，所有命令用绝对路径）、GetX 4.7.3、dio、`package:fake_async`（已在 dev_dependencies ^1.3.1）、flutter_smart_dialog。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-15-multi-window-tabs-design.md` 第 7 节（心跳全局仲裁）、7.5（让位体验）、12（测试策略）、13（M3 里程碑）。计划与 spec 冲突以 spec 为准。

## Global Constraints

- 仅 Windows 标签壳启用网关路径；判定条件唯一：`tabId != null && Get.isRegistered<DouyinPresenceGateway>()`。Android（tabId==null 的 GetX 路由单例）与所有直接构造控制器的现有测试走旧路径，行为零变化。
- M3 只收口**抖音**（`Constant.kDouyin`）账号态。bili/huya 的 `_enterGuardRoom` 自动进房、各自心跳与退出逻辑一行不动（同账号多标签服务端页面抢占问题留后续里程碑，非本计划目标）。
- 心跳周期固定 20s（`Duration(seconds: 20)`），与现状一致；构造函数注入间隔仅用于测试。
- 心跳全应用唯一：任何时刻 `DouyinPresenceGateway` 内至多一个 `Timer.periodic`，只续租 `arbiter.holder`。
- 批量关闭（定时全关 / 右键「关闭其他标签」「关闭右侧标签」）必须先经网关一次性摘栈：整批最多一次 `exitRoom`（原 holder 在批内时），至多一次 fallback enter（幸存者在意图栈中时）；摘栈后各控制器 onClose 的 release 对未知 tab 必须是零 HTTP no-op，禁止对正在销毁的标签发起 enterRoom。
- 不引入 IPC、不碰子窗 / 子引擎 / bootstrap（M4 范围）；`detach` 只在状态机与网关层实现并单测，生产无调用点，M4 跨窗移动接线。
- 中文文案必须逐字使用本计划给出的字符串（系统提示 / toast）。
- 门禁：改动文件 `flutter analyze` 零新增 issue（全项目基线 22 条存量不得增加）；`flutter test` 全绿（当前 117，新增只增不减）；`flutter build windows --debug` 成功。构建必须 stdin 接 `/dev/null`、输出重定向日志文件，禁止 `2>&1 |` 管道（已知会挂死）；若挂死用 PowerShell `Get-CimInstance Win32_Process` 找根 flutter build PID，`taskkill //F //T //PID` 清树后重试一次。
- 提交：一个任务一个 commit，只 `git add` 任务相关文件的明确路径，**严禁 `git add -A` / `git add .`**（工作区有大量无关存量改动）；commit message 结尾必须有空行加：
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`
- 不 push、不 merge、不删除分支，等用户指令。
- 所有新代码放 `simple_live_app/lib/app/multiwindow/presence/`，与 spec 第 13 节目录树一致。

## File Structure

| 文件 | 责任 | 任务 |
|---|---|---|
| `lib/app/multiwindow/presence/presence_arbiter.dart` | 纯意图栈状态机：claimants 有序栈、holder、suspended 集合，输出 `PresenceTransition`；含批量摘栈 `releaseMany` | T1 新建 |
| `test/presence_arbiter_test.dart` | 状态机表驱动单测 | T1 新建 |
| `lib/app/multiwindow/presence/presence_claimant.dart` | `DouyinPresenceTab` 端口（网关↔标签）+ `PresenceClaimResult` | T2 新建 |
| `lib/app/multiwindow/presence/douyin_presence_gateway.dart` | 唯一心跳 Timer + 账号态 HTTP 收口 + claim/release/detach/batchRelease/suspended 调度 | T2 新建 |
| `lib/app/multiwindow/presence/local_presence_client.dart` | 控制器侧薄代理（直接函数调用；M4 换 IPC） | T2 新建 |
| `test/douyin_presence_gateway_test.dart` | 网关系列测试（FakeGuard/FakeTab + fakeAsync） | T2 新建 |
| `lib/modules/live_room/live_room_controller.dart` | 抽出账号进场/让位原语；Windows+网关路径分流到 client；onClose/refresh/reset 走 release；bili/huya 与 Android 不动 | T3 修改 |
| `lib/app/multiwindow/shell/tab_store.dart` | 构造注入可选网关；closeAll/closeOthers/closeRight 在销毁控制器前先 `batchRelease` 摘栈 | T3 修改 |
| `lib/app/multiwindow/shell/tab_strip.dart` | closeOthers/closeRight 变异步后调用点加 `unawaited` | T3 修改 |
| `lib/routes/app_pages.dart` | kShell binding 注册 `DouyinPresenceGateway`（先于 TabStore）并注入 | T3 修改 |
| `test/presence_gateway_controller_test.dart` | 两个真实控制器 + 真网关 + FakeGuard 的端到端仲裁接线测试 | T3 新建 |
| `test/tab_store_test.dart` | 既有 3 个用例适配 closeOthers/closeRight 异步签名（`async/await`、`expectLater`），断言语义不变 | T3 修改 |

**关键时序（claim，spec 7.3 + 防 flip-flop）：**
1. 记 `previousHolder`，**先 cancel 心跳 Timer**（防止 enter 成功前旧 holder 的下一拍心跳在服务端把页面抢回旧房间）；
2. HTTP：`fetchAccountDetail(asAccount:true)` → `ensureAccount` → `enterRoom`（404 → `reregister` 重试一次），任一步失败：旧 holder 心跳恢复，仲裁状态不变，返回失败原因；
3. 成功后才 `arbiter.claim(tabId)`（栈迁移不可回滚的时机在 HTTP 成功之后）；
4. 新 holder `applyAccountEnter`（弹幕切账号）→ 启动唯一 Timer；
5. 旧 holder `applyYieldToGuest`（best-effort，不 await、不阻塞 claim 返回）。

**关键时序（release/close，spec 7.3、5.4）：** holder 才发 `exitRoom`，先 exit 再让 fallback 重新 enter（同一服务端浏览器页面会话，enter 会把页面带进新房，顺序反了会 exit 错房间）；非 holder 仅出栈无任何 HTTP。fallback 重新 enter 失败时 holder 已迁移、心跳暂停，用户在该标签的下一次写动作经 claim 重试。

**关键时序（批量关闭，右键「关闭其他/右侧」与 R14 定时全关）：** TabStore 在循环 `unregister` 之前先调网关 `batchRelease(victimIds)`：状态机一次性摘除全部受害者（只产出一次 exit、至多一个幸存者 fallback），HTTP 完成后再销毁控制器。销毁触发的各 onClose→release 全部命中"未知 tab"no-op。

---

### Task 1: PresenceArbiter 纯意图栈状态机

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/presence_arbiter.dart`
- Test: `simple_live_app/test/presence_arbiter_test.dart`

**Interfaces:**
- Produces（后续任务直接依赖，签名不可漂移）：
  - `class PresenceTransition { final String? enters; final String? exits; final String? yields; const PresenceTransition({this.enters, this.exits, this.yields}); }`
    - `enters`=需执行 enterRoom 并接管心跳的 tabId；`exits`=需发 exitRoom 的 tabId（仅 close）；`yields`=需降级游客的原 holder（claim 抢占）。
  - `class PresenceArbiter`：
    - `List<String> get claimants`（不可变视图，栈尾最新）
    - `String? get holder`
    - `bool isSuspended(String tabId)`、`bool isClaimed(String tabId)`
    - `PresenceTransition claim(String tabId)`
    - `PresenceTransition? release(String tabId)`（close 语义）
    - `PresenceTransition? detach(String tabId)`（跨窗移动语义，M4 接线）
    - `PresenceTransition? releaseMany(Set<String> tabIds)`（批量关闭：一次摘除、至多一次 exit、至多一个 fallback）
    - `PresenceTransition markSuspended(String tabId)`（外部端抢占）
  - 语义：
    - `claim`：已在栈则先移除再追加到栈尾（幂等"提到最新"）；清除该 tabId 的 suspended；holder 置为该 tabId；`enters` 恒为入参；旧 holder 不同时 `yields`=旧 holder。
    - `release`/`detach`：未知 tabId 返回 `null`（无动作）；非持有者移除并返回**空 transition**（`const PresenceTransition()`，区分"仅出栈"与"未知"）；持有者：摘除、holder 置空，栈非空则栈尾成为新 holder（清除其 suspended 标记，`enters`=该 tabId）；`exits` 仅 `release` 时为原 holder，`detach` 恒无 exits。
    - `releaseMany`：入参中无一是 claimant 时返回 `null`；原 holder 不在批内时摘除其余标签并返回空 transition（holder/心跳不变）；原 holder 在批内时：摘除全部命中标签、`exits`=原 holder、栈尾幸存者成为新 holder（清 suspended、`enters`=幸存者），栈空则无 enters。调用方保证在销毁这批控制器**之前**调用。
    - `markSuspended`：仅当入参==holder 时 holder 置空并加入 suspended 集合，返回空 transition；否则无动作。tabId 仍留在 claimants 栈中。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_app/test/presence_arbiter_test.dart`，完整内容：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_arbiter.dart';

void main() {
  group('claim', () {
    test('首个意图成为 holder', () {
      final a = PresenceArbiter();
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(t.enters, 'A');
      expect(t.yields, isNull);
      expect(t.exits, isNull);
    });

    test('新意图抢占：旧 holder 进入 yields，栈尾为最新', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.claim('B');
      expect(a.holder, 'B');
      expect(a.claimants, ['A', 'B']);
      expect(t.enters, 'B');
      expect(t.yields, 'A');
    });

    test('已在栈中的标签 claim：提到栈尾并抢回 holder（发弹幕场景）', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B'); // B holder，A 被让位
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['B', 'A']);
      expect(t.enters, 'A');
      expect(t.yields, 'B');
    });

    test('holder 重复 claim：无 yields', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.claim('A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(t.yields, isNull);
    });

    test('claim 清除自身 suspended', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.markSuspended('A');
      expect(a.isSuspended('A'), isTrue);
      a.claim('A');
      expect(a.isSuspended('A'), isFalse);
      expect(a.holder, 'A');
    });
  });

  group('release（close 语义）', () {
    test('释放 holder：发 exit 并回退栈尾次新接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.release('B')!;
      expect(t.exits, 'B');
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(a.isSuspended('A'), isFalse);
    });

    test('逆序关闭三个标签：回退顺序严格按打开时间', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.claim('C');
      var t = a.release('C')!;
      expect(t.enters, 'B');
      t = a.release('B')!;
      expect(t.enters, 'A');
      t = a.release('A')!;
      expect(t.enters, isNull);
      expect(t.exits, 'A');
      expect(a.holder, isNull);
      expect(a.claimants, isEmpty);
    });

    test('释放非持有者：空 transition、不发 exit、holder 不变', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.release('A');
      expect(t, isNotNull);
      expect(t!.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
      expect(a.claimants, ['B']);
    });

    test('释放唯一 holder：exit 且无接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      final t = a.release('A')!;
      expect(t.exits, 'A');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
    });

    test('释放未知 tab：返回 null 无动作', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.release('X'), isNull);
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('回退目标是 suspended 标签：清除 suspended 并重新 enter', () {
      final a = PresenceArbiter();
      a.claim('A'); // A holder
      a.markSuspended('A'); // 手机端抢占 A
      a.claim('B'); // 用户改在 B 显式进入，A 仍在栈中且 suspended
      expect(a.isSuspended('A'), isTrue);
      final t = a.release('B')!; // 更新的标签关闭
      expect(t.enters, 'A');
      expect(t.exits, 'B');
      expect(a.holder, 'A');
      expect(a.isSuspended('A'), isFalse);
    });
  });

  group('detach（跨窗移动语义，M4 接线）', () {
    test('detach holder：摘除、不发 exit、次新接管', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.detach('B')!;
      expect(t.exits, isNull);
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('detach 非持有者：仅摘除', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.detach('A')!;
      expect(t.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
    });

    test('detach 未知 tab 返回 null', () {
      final a = PresenceArbiter();
      expect(a.detach('X'), isNull);
    });
  });

  group('markSuspended（外部端抢占）', () {
    test('抢占 holder：停 holder、不自动回退、标签留在栈中', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      final t = a.markSuspended('B');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
      expect(a.isSuspended('B'), isTrue);
      expect(a.claimants, ['A', 'B']);
    });

    test('对非 holder 调 markSuspended 无动作', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.markSuspended('A');
      expect(a.holder, 'B');
      expect(a.isSuspended('A'), isFalse);
    });
  });

  group('releaseMany（批量关闭）', () {
    test('全关：只 exit 原 holder 一次，无 fallback、栈清空', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B');
      a.claim('C');
      final t = a.releaseMany({'A', 'B', 'C'})!;
      expect(t.exits, 'C');
      expect(t.enters, isNull);
      expect(a.holder, isNull);
      expect(a.claimants, isEmpty);
    });

    test('关闭其他：受害者含 holder，幸存者在栈中则接管（清 suspended）', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.markSuspended('A'); // 手机抢占 A
      a.claim('B');
      a.claim('C'); // C holder，A 仍 suspended 在栈
      final t = a.releaseMany({'B', 'C'})!;
      expect(t.exits, 'C');
      expect(t.enters, 'A');
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
      expect(a.isSuspended('A'), isFalse);
    });

    test('批内不含 holder：空 transition，holder 与心跳归属不变', () {
      final a = PresenceArbiter();
      a.claim('A');
      a.claim('B'); // B holder
      final t = a.releaseMany({'A'})!;
      expect(t.exits, isNull);
      expect(t.enters, isNull);
      expect(a.holder, 'B');
      expect(a.claimants, ['B']);
    });

    test('全部未知：返回 null', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.releaseMany({'X', 'Y'}), isNull);
      expect(a.holder, 'A');
      expect(a.claimants, ['A']);
    });

    test('空集合：返回 null', () {
      final a = PresenceArbiter();
      a.claim('A');
      expect(a.releaseMany(<String>{}), isNull);
    });
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/presence_arbiter_test.dart
```
Expected: 编译失败 / 全部 FAIL（`presence_arbiter.dart` 不存在）。

- [ ] **Step 3: 实现 PresenceArbiter**

创建 `simple_live_app/lib/app/multiwindow/presence/presence_arbiter.dart`，完整内容：

```dart
/// 抖音账号在场意图栈的纯状态机（无 Flutter / GetX / HTTP 依赖）。
///
/// 规则（设计文档 7.3）：
/// - 意图有序，新意图在栈尾，栈尾即最新打开、即心跳持有者；
/// - claim 幂等：已在栈中则移到栈尾（"提到最新"）并清除其 suspended；
/// - release（关标签）：持有者发 exit 并回退栈尾次新接管；非持有者仅出栈；
/// - detach（跨窗移动）：同 release 但持有者不发 exit（M4 接线，目标窗
///   attach 后以同一 tabId 重新 claim）；
/// - 外部端抢占 markSuspended：仅暂停持有者，不自动抢回 / 不回退；
///   回退落到 suspended 标签时清除 suspended 并重新 enter。
class PresenceTransition {
  const PresenceTransition({this.enters, this.exits, this.yields});

  /// 需执行 enterRoom 并接管心跳的 tabId
  final String? enters;

  /// 需发 exitRoom 的 tabId（仅 close 路径的原持有者）
  final String? exits;

  /// 需降级为游客的原持有者（claim 抢占时）
  final String? yields;
}

class PresenceArbiter {
  final List<String> _claimants = [];
  final Set<String> _suspended = <String>{};
  String? _holder;

  List<String> get claimants => List.unmodifiable(_claimants);
  String? get holder => _holder;
  bool isSuspended(String tabId) => _suspended.contains(tabId);
  bool isClaimed(String tabId) => _claimants.contains(tabId);

  PresenceTransition claim(String tabId) {
    final previousHolder = _holder;
    _claimants.remove(tabId);
    _claimants.add(tabId);
    _suspended.remove(tabId);
    _holder = tabId;
    return PresenceTransition(
      enters: tabId,
      yields: (previousHolder != null && previousHolder != tabId)
          ? previousHolder
          : null,
    );
  }

  PresenceTransition? release(String tabId) =>
      _remove(tabId, emitExit: true);

  PresenceTransition? detach(String tabId) =>
      _remove(tabId, emitExit: false);

  PresenceTransition? _remove(String tabId, {required bool emitExit}) {
    if (!_claimants.contains(tabId)) {
      return null;
    }
    final wasHolder = _holder == tabId;
    _claimants.remove(tabId);
    _suspended.remove(tabId);
    if (!wasHolder) {
      return const PresenceTransition();
    }
    _holder = null;
    final fallback = _claimants.isEmpty ? null : _claimants.last;
    if (fallback != null) {
      _holder = fallback;
      // 用户回到 PC 操作：回退即重新 enter，suspended 同样清除
      _suspended.remove(fallback);
    }
    return PresenceTransition(
      exits: emitExit ? tabId : null,
      enters: fallback,
    );
  }

  /// 同账号在外部端（手机等）进入房间：暂停持有者心跳，不自动回退，
  /// 避免与外部端互踢；用户在本端主动写动作时经 claim 重新进入。
  PresenceTransition markSuspended(String tabId) {
    if (_holder != tabId) {
      return const PresenceTransition();
    }
    _holder = null;
    _suspended.add(tabId);
    return const PresenceTransition();
  }

  /// 批量摘除（关闭其他/右侧/全部）：整批一次计算，至多一次 exit、
  /// 一个 fallback；调用方必须在销毁这批标签的控制器之前调用。
  PresenceTransition? releaseMany(Set<String> tabIds) {
    if (tabIds.isEmpty || !_claimants.any(tabIds.contains)) {
      return null;
    }
    final oldHolder = _holder;
    final holderRemoved = oldHolder != null && tabIds.contains(oldHolder);
    _claimants.removeWhere(tabIds.contains);
    _suspended.removeAll(tabIds);
    if (!holderRemoved) {
      return const PresenceTransition();
    }
    _holder = null;
    final fallback = _claimants.isEmpty ? null : _claimants.last;
    if (fallback != null) {
      _holder = fallback;
      _suspended.remove(fallback);
    }
    return PresenceTransition(exits: oldHolder, enters: fallback);
  }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/presence_arbiter_test.dart
```
Expected: 全绿（21 个 test 用例）。

- [ ] **Step 5: analyze 本任务文件**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat analyze lib/app/multiwindow/presence/presence_arbiter.dart test/presence_arbiter_test.dart
```
Expected: `No issues found!`

- [ ] **Step 6: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_arbiter.dart simple_live_app/test/presence_arbiter_test.dart
git commit -m "feat(windows): 抖音在场意图栈纯状态机 PresenceArbiter" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: DouyinPresenceTab 端口 + DouyinPresenceGateway + LocalPresenceClient

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart`
- Create: `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`
- Create: `simple_live_app/lib/app/multiwindow/presence/local_presence_client.dart`
- Test: `simple_live_app/test/douyin_presence_gateway_test.dart`

**Interfaces:**
- Consumes: T1 的 `PresenceArbiter / PresenceTransition`；现有 `GuardServerService`（`simple_live_app/lib/services/guard_server_service.dart`）实例方法：
  - `bool get configured`
  - `Future<String?> ensureAccount(String platform)`
  - `Future<String?> reregister(String platform)`
  - `Future<Map<String, dynamic>> enterRoom({required String accountId, required String roomId, String webRid = "", Map<String, dynamic>? extra})`
  - `Future<Map<String, dynamic>> heartbeat({required String accountId, required String roomId, String webRid = "", Map<String, dynamic>? extra})`
  - `Future<void> exitRoom({required String accountId, required String roomId, String webRid = "", Map<String, dynamic>? extra})`
  - `String? savedAccountId(String platform)`（同步，读 LocalStorage）
  - `Constant.kDouyin` 为平台字符串 `"douyin"`。
- Produces（T3 依赖，签名不可漂移）：
  - `abstract class DouyinPresenceTab`：见 Step 1 代码，含 `tabId / fetchAccountDetail() / guardRoomId / guardWebRid / guardExtraArgs() / applyAccountEnter(...) / applyYieldToGuest() / applySuspended()`。
  - `class PresenceClaimResult`：`bool get granted`、`bool get detailFailed`；具名构造 `const PresenceClaimResult.granted()`、`const PresenceClaimResult.failure({required bool detailFailed})`。
  - `class DouyinPresenceGateway`：
    - 构造 `DouyinPresenceGateway(GuardServerService guard, {Duration heartbeatInterval = const Duration(seconds: 20)})`
    - `Future<PresenceClaimResult> claim(DouyinPresenceTab tab)`
    - `Future<void> release(String tabId)`
    - `Future<void> detach(String tabId)`
    - `Future<void> batchRelease(Set<String> tabIds)`（批量关闭：一次 exit、至多一次幸存者接管；必须在控制器销毁前调用）
    - `void bindTab(DouyinPresenceTab tab)`
    - `bool hasClaim(String tabId)`（refreshRoom/resetRoom 判定用）
    - `String? get holderTabId`
    - `@visibleForTesting void stopHeartbeatForTesting()`
  - `class LocalPresenceClient`：构造 `(DouyinPresenceGateway, DouyinPresenceTab)`；`Future<PresenceClaimResult> claim()`、`Future<void> release()`、`Future<void> detach()`。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_app/test/douyin_presence_gateway_test.dart`，完整内容：

```dart
import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];
  final beats = <String>[];
  final reregisters = <String>[];
  final ensureAccounts = <String>[];

  bool enterThrowsOnce = false;
  bool detailGuardUnconfigured = false;
  Object? heartbeatThrowOnce;
  Map<String, dynamic> heartbeatResult = {'inRoom': true};
  int inRoomFalseBeats = 0;

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => !detailGuardUnconfigured;

  @override
  Future<String?> ensureAccount(String platform) async {
    ensureAccounts.add(platform);
    return 'acct1';
  }

  @override
  Future<String?> reregister(String platform) async {
    reregisters.add(platform);
    return 'acct2';
  }

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    if (enterThrowsOnce) {
      enterThrowsOnce = false;
      throw DioException(
        requestOptions: RequestOptions(path: '/api/room/enter'),
        response: Response<dynamic>(
          requestOptions: RequestOptions(path: '/api/room/enter'),
          statusCode: 404,
        ),
      );
    }
    enters.add('$accountId@$roomId');
    return {'joined': false, 'starGuard': false, 'badgeActive': true};
  }

  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    final thrown = heartbeatThrowOnce;
    if (thrown != null) {
      heartbeatThrowOnce = null;
      throw thrown;
    }
    beats.add('$accountId@$roomId');
    if (inRoomFalseBeats > 0) {
      inRoomFalseBeats--;
      return {'inRoom': false};
    }
    return heartbeatResult;
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add('$accountId@$roomId');
  }
}

LiveRoomDetail _detail(String webRid, String cookie) => LiveRoomDetail(
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
        userId: 'uid_$webRid',
        cookie: cookie,
      ),
    );

class FakeTab implements DouyinPresenceTab {
  FakeTab(this.id, this.webRid, {this.cookie = 'sessionid=abc'});

  @override
  final String id;
  final String webRid;
  final String cookie;

  int detailFetches = 0;
  bool detailThrows = false;
  bool applyThrows = false;
  int yields = 0;
  int suspended = 0;
  final reenteredCalls = <bool>[];
  Map<String, dynamic>? lastStatus;
  String? lastDetailCookie;

  @override
  String get tabId => id;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async {
    if (detailThrows) throw CoreError('blocked by host');
    detailFetches++;
    return _detail(webRid, cookie);
  }

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
  }) async {
    reenteredCalls.add(reentered);
    lastStatus = guardStatus;
    final args = accountDetail.danmakuData as DouyinDanmakuArgs;
    lastDetailCookie = args.cookie;
    if (applyThrows) throw StateError('danmaku restart failed');
  }

  @override
  Future<void> applyYieldToGuest() async {
    yields++;
  }

  @override
  void applySuspended() {
    suspended++;
  }
}

void main() {
  group('claim 进场', () {
    test('首个 claim：enter 一次、applyAccountEnter、holder 为该 tab',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');

      final r = await gw.claim(a);

      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'A');
      expect(guard.enters, ['acct1@room_111']);
      expect(a.reenteredCalls, [false]);
      expect(a.lastStatus?['badgeActive'], isTrue);
      gw.stopHeartbeatForTesting();
    });

    test('已是 holder 重复 claim：不重复 HTTP', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(guard.enters.length, 1);
      gw.stopHeartbeatForTesting();
    });

    test('抢占：B 进场成功后 A 被 yield，未发任何 exit', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      final r = await gw.claim(b);
      await Future<void>.value();

      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'B');
      expect(guard.enters, ['acct1@room_111', 'acct1@room_222']);
      expect(guard.exits, isEmpty);
      expect(b.reenteredCalls, [false]);
      expect(a.yields, 1);
      gw.stopHeartbeatForTesting();
    });

    test('账号详情失败：detailFailed=true，仲裁不变、旧 holder 未 yield',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222')..detailThrows = true;
      await gw.claim(a);
      final r = await gw.claim(b);

      expect(r.granted, isFalse);
      expect(r.detailFailed, isTrue);
      expect(gw.holderTabId, 'A');
      expect(guard.enters, ['acct1@room_111']);
      expect(a.yields, 0);
      expect(b.reenteredCalls, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('guard 未配置：enter 失败但非 detailFailed，仲裁不变', () async {
      final guard = FakeGuard()..detailGuardUnconfigured = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final r = await gw.claim(a);
      expect(r.granted, isFalse);
      expect(r.detailFailed, isFalse);
      expect(gw.holderTabId, isNull);
      gw.stopHeartbeatForTesting();
    });

    test('enterRoom 404：reregister 后重试成功', () async {
      final guard = FakeGuard()..enterThrowsOnce = true;
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(guard.reregisters, [Constant.kDouyin]);
      expect(guard.enters, ['acct2@room_111']);
      gw.stopHeartbeatForTesting();
    });

    test('applyAccountEnter 抛错仍 granted：服务端已进场，仲裁/心跳为准',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111')..applyThrows = true;
      final r = await gw.claim(a);
      expect(r.granted, isTrue);
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });
  });

  group('唯一心跳（fakeAsync）', () {
    test('抢占后只有新 holder 的房间被续租，旧 holder 不再有心跳', () {
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
        async.elapse(const Duration(milliseconds: 250));
        expect(guard.beats, ['acct1@room_111', 'acct1@room_111']);

        gw.claim(b);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));

        expect(
          guard.beats,
          [
            'acct1@room_111',
            'acct1@room_111',
            'acct1@room_222',
            'acct1@room_222',
          ],
        );
        gw.stopHeartbeatForTesting();
      });
    });

    test('claim 失败后旧 holder 心跳恢复', () {
      FakeAsync().run((async) {
        final guard = FakeGuard();
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        final b = FakeTab('B', '222')..detailThrows = true;

        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        final before = guard.beats.length;
        expect(before, 1);

        gw.claim(b);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));

        expect(gw.holderTabId, 'A');
        expect(guard.beats.length, before + 1, reason: 'A 的心跳应恢复');
        expect(guard.beats.last, 'acct1@room_111');
        gw.stopHeartbeatForTesting();
      });
    });

    test('心跳 404：reregister 后以新 accountId 续租', () {
      FakeAsync().run((async) {
        final guard = FakeGuard()
          ..heartbeatThrowOnce = DioException(
            requestOptions: RequestOptions(path: '/api/room/heartbeat'),
            response: Response<dynamic>(
              requestOptions: RequestOptions(path: '/api/room/heartbeat'),
              statusCode: 404,
            ),
          );
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 250));
        expect(guard.reregisters, [Constant.kDouyin]);
        expect(guard.beats.last, 'acct2@room_111');
        gw.stopHeartbeatForTesting();
      });
    });

    test('心跳 inRoom!=true：标记 suspended、停心跳、通知标签', () {
      FakeAsync().run((async) {
        final guard = FakeGuard()..inRoomFalseBeats = 1;
        final gw = DouyinPresenceGateway(
          guard,
          heartbeatInterval: const Duration(milliseconds: 100),
        );
        final a = FakeTab('A', '111');
        gw.claim(a);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 150));
        final beatsAfterSuspend = guard.beats.length;
        async.elapse(const Duration(milliseconds: 300));
        expect(guard.beats.length, beatsAfterSuspend, reason: '心跳必须停止');
        expect(gw.holderTabId, isNull);
        expect(a.suspended, 1);
        gw.stopHeartbeatForTesting();
      });
    });
  });

  group('release / detach', () {
    test('release holder：先 exit 再让次新重新 enter 接管，reentered=true',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.release('B');

      expect(guard.exits, ['acct1@room_222']);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      expect(a.reenteredCalls.last, isTrue);
      expect(a.lastDetailCookie, 'sessionid=abc');
      gw.stopHeartbeatForTesting();
    });

    test('release 非持有者：零 HTTP，holder 不变', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.release('A');

      expect(guard.exits, isEmpty);
      expect(guard.enters, isEmpty);
      expect(gw.holderTabId, 'B');
      gw.stopHeartbeatForTesting();
    });

    test('release 未知 tab：无动作', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      await gw.release('X');
      expect(guard.exits, isEmpty);
      expect(gw.holderTabId, isNull);
    });

    test('回退接管 enter 失败：holder 已迁移、心跳暂停（等写动作重试）',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a); // A 首次进场成功
      await gw.claim(b); // B 成为 holder，A 让位
      await Future<void>.value();
      a.detailThrows = true; // 此后回退 A 的重新进场失败

      await gw.release('B');

      expect(gw.holderTabId, 'A', reason: '仲裁已迁移到 A');
      expect(a.reenteredCalls, [false], reason: '回退失败不再 apply');
      gw.stopHeartbeatForTesting();
    });

    test('detach holder：不发 exit，次新接管', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.detach('B');

      expect(guard.exits, isEmpty);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });

    test('LocalPresenceClient 直连网关', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final client = LocalPresenceClient(gw, a);
      final r = await client.claim();
      expect(r.granted, isTrue);
      await client.release();
      expect(gw.holderTabId, isNull);
      gw.stopHeartbeatForTesting();
    });
  });

  group('batchRelease（批量关闭）', () {
    test('全关：只 exit 原 holder 一次、无 fallback；迟到的 release 全 no-op',
        () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'A', 'B'});

      expect(guard.exits, ['acct1@room_222'], reason: '只退 holder B');
      expect(guard.enters, isEmpty, reason: '无幸存者，不回退');
      expect(gw.holderTabId, isNull);

      // 模拟各控制器 onClose 迟到的 release：未知 tab 零 HTTP
      await gw.release('A');
      await gw.release('B');
      expect(guard.exits.length, 1);
      expect(guard.enters, isEmpty);
      gw.stopHeartbeatForTesting();
    });

    test('关闭其他：受害者含 holder，幸存者 A 只重新 enter 一次并接管', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      final c = FakeTab('C', '333');
      await gw.claim(a);
      await gw.claim(b);
      await gw.claim(c);
      await Future<void>.value();
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'B', 'C'});

      expect(guard.exits, ['acct1@room_333']);
      expect(guard.enters, ['acct1@room_111']);
      expect(gw.holderTabId, 'A');
      expect(a.reenteredCalls.last, isTrue);

      // 被销毁标签 onClose 的 release 不产生额外 HTTP
      await gw.release('B');
      await gw.release('C');
      expect(guard.exits.length, 1);
      expect(guard.enters.length, 1);
      gw.stopHeartbeatForTesting();
    });

    test('批内不含 holder：零 HTTP，holder 与心跳归属不变', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      final b = FakeTab('B', '222');
      await gw.claim(a);
      await gw.claim(b);
      guard.exits.clear();
      guard.enters.clear();

      await gw.batchRelease({'A'});

      expect(guard.exits, isEmpty);
      expect(guard.enters, isEmpty);
      expect(gw.holderTabId, 'B');
      gw.stopHeartbeatForTesting();
    });

    test('空集合 / 全未知：no-op', () async {
      final guard = FakeGuard();
      final gw = DouyinPresenceGateway(guard);
      final a = FakeTab('A', '111');
      await gw.claim(a);
      await gw.batchRelease(<String>{});
      await gw.batchRelease({'X'});
      expect(gw.holderTabId, 'A');
      gw.stopHeartbeatForTesting();
    });
  });
}
```

注意：测试文件不需要 import `package:flutter/foundation.dart`（`@visibleForTesting` 只用在 lib 侧）；`CoreError` 来自 `package:simple_live_core/simple_live_core.dart`。

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/douyin_presence_gateway_test.dart
```
Expected: 编译失败（三个 lib 文件不存在）。

- [ ] **Step 3: 实现端口与结果类**

创建 `simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart`，完整内容：

```dart
import 'package:simple_live_core/simple_live_core.dart';

/// 网关对单个抖音标签执行账号态动作所需的端口。
///
/// M3 主引擎内由 LiveRoomController 的适配器直接实现（进程内函数调用）；
/// M4 子引擎场景由主引擎侧的 IPC 远端代理实现，控制器侧代码无分支差异。
abstract class DouyinPresenceTab {
  String get tabId;

  /// 以账号身份读取房间详情（DouyinSite.getRoomDetail(asAccount:true)）。
  /// 被主播限制等失败由实现方抛出异常，网关据此判定为详情失败。
  Future<LiveRoomDetail> fetchAccountDetail();

  /// guard /api/room/* 所需房间标识，由当前（游客）详情的弹幕参数派生。
  /// 账号详情与游客详情的 roomId/webRid 相同，仅 cookie 不同，
  /// 因此 enterRoom 发生在 applyAccountEnter 之前也能取到正确值。
  String get guardRoomId;
  String get guardWebRid;
  Map<String, dynamic> guardExtraArgs();

  /// 账号进场成功（[reentered]=true 表示关闭新标签后回退接管）：
  /// 停游客弹幕、切换账号详情并重连账号弹幕、应用房间状态位、
  /// 置 presence=account、发系统提示。
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  });

  /// 被更新打开的标签让位：播放不中断，降级游客详情与弹幕（best-effort，
  /// 实现方内部吞异常）并发系统提示。
  Future<void> applyYieldToGuest();

  /// 同账号在外部端进入房间、心跳 inRoom!=true：停止本标签账号态语义，
  /// 不自动抢回；用户后续写动作经 claim 重新进入。
  void applySuspended();
}

/// claim 结果。[detailFailed]=true 表示账号详情读取失败（被限制等），
/// false 表示 guard 未配置 / 进场网络失败；控制器据此选 toast 文案。
class PresenceClaimResult {
  const PresenceClaimResult._(this.granted, this.detailFailed);

  const PresenceClaimResult.granted() : this._(true, false);

  const PresenceClaimResult.failure({required bool detailFailed})
      : this._(false, detailFailed);

  final bool granted;
  final bool detailFailed;
}
```

- [ ] **Step 4: 实现网关**

创建 `simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart`，完整内容：

```dart
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'presence_arbiter.dart';
import 'presence_claimant.dart';

/// 抖音登录心跳全局仲裁者（每引擎一个；M3 仅主引擎在 kShell binding 实例化）。
///
/// 全应用唯一心跳 Timer：只有 arbiter.holder 的房间被续租。
/// 账号态 HTTP（ensureAccount/enterRoom/heartbeat/exitRoom/reregister）
/// 与 404 重注册全部收口于此；账号详情取数经 DouyinPresenceTab 端口。
class DouyinPresenceGateway {
  DouyinPresenceGateway(
    this._guard, {
    this.heartbeatInterval = const Duration(seconds: 20),
  });

  final GuardServerService _guard;
  final Duration heartbeatInterval;
  final PresenceArbiter arbiter = PresenceArbiter();

  final Map<String, DouyinPresenceTab> _tabs = {};
  final Map<String, String> _accountIds = {};
  Timer? _heartbeatTimer;

  String? get holderTabId => arbiter.holder;

  /// 控制器 onInit 绑定标签端口（同 tabId 重复绑定幂等）
  void bindTab(DouyinPresenceTab tab) {
    _tabs[tab.tabId] = tab;
  }

  bool hasClaim(String tabId) => arbiter.isClaimed(tabId);

  /// 显式进入 / 抢占（点「进入直播间」、发弹幕、点赞等）
  Future<PresenceClaimResult> claim(DouyinPresenceTab tab) async {
    bindTab(tab);
    if (arbiter.holder == tab.tabId) {
      return const PresenceClaimResult.granted();
    }
    final previousHolder = _currentHolderTab();
    // enter 成功前先停心跳：否则旧 holder 的下一拍会在服务端把浏览器页面
    // 抢回旧房间，造成两个标签 flip-flop。
    _heartbeatTimer?.cancel();

    final entered = await _performEnter(tab);
    if (entered == null) {
      // 仲裁尚未迁移，旧 holder 没有被让位：恢复其心跳
      if (previousHolder != null) {
        final id = _accountIds[previousHolder.tabId];
        if (id != null) {
          _startHeartbeat(previousHolder, id);
        }
      }
      return PresenceClaimResult.failure(detailFailed: _lastDetailFailed);
    }

    // HTTP 成功后才迁移仲裁状态
    arbiter.claim(tab.tabId);
    _accountIds[tab.tabId] = entered.accountId;
    try {
      await tab.applyAccountEnter(
        accountDetail: entered.detail,
        guardStatus: entered.status,
        reentered: false,
      );
    } catch (e) {
      // 服务端已进场，以仲裁/心跳为准；弹幕侧重连失败只记日志
      Log.logPrint('presence: applyAccountEnter 失败: $e');
    }
    _startHeartbeat(tab, entered.accountId);

    if (previousHolder != null) {
      // best-effort：不阻塞 claim 返回；播放不中断，游客详情/弹幕重连失败
      // 只记日志（spec 7.5）
      unawaited(
        previousHolder
            .applyYieldToGuest()
            .catchError((Object e, StackTrace s) {
          Log.logPrint('presence: 让位降级失败: $e');
        }),
      );
    }
    return const PresenceClaimResult.granted();
  }

  /// 关闭标签（close 语义）：持有者发 exitRoom，次新标签自动接管
  Future<void> release(String tabId) => _remove(tabId, emitExit: true);

  /// 跨窗移出（detach 语义，M4 接线）：持有者停心跳、不发 exitRoom
  Future<void> detach(String tabId) => _remove(tabId, emitExit: false);

  Future<void> _remove(String tabId, {required bool emitExit}) async {
    final tab = _tabs[tabId];
    final accountId = _accountIds[tabId];
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _accountIds.remove(tabId);
    if (transition == null) {
      return; // 未知 tab
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 非持有者：仅出栈，零 HTTP
    }
    _heartbeatTimer?.cancel();

    // 同一服务端浏览器页面会话：先 exit（页面回首页）再让 fallback enter，
    // 顺序反了 exit 可能作用于 fallback 刚进入的房间。
    if (emitExit && transition.exits != null && tab != null) {
      await _exitRoom(tab, accountId);
    }
    if (transition.enters != null) {
      await _applyFallback(transition.enters!);
    }
  }

  /// 批量关闭（关闭其他/右侧/全部）：一次性摘栈，整批至多一次 exit、
  /// 至多一次幸存者接管。必须在这批标签的控制器被销毁**之前**调用：
  /// 摘栈后控制器 onClose 的 release 全部命中未知 tab no-op。
  Future<void> batchRelease(Set<String> tabIds) async {
    if (tabIds.isEmpty) return;
    final holderId = arbiter.holder;
    final holderInBatch = holderId != null && tabIds.contains(holderId);
    final exitTab = holderInBatch ? _tabs[holderId] : null;
    final exitAccount =
        exitTab == null ? null : _accountIds[holderId];

    final transition = arbiter.releaseMany(tabIds);
    if (transition == null) {
      return; // 批内没有任何 claimant
    }
    for (final id in tabIds) {
      _tabs.remove(id);
      _accountIds.remove(id);
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 原 holder 不在批内：心跳归属不变
    }
    _heartbeatTimer?.cancel();
    if (exitTab != null) {
      await _exitRoom(exitTab, exitAccount);
    }
    if (transition.enters != null) {
      await _applyFallback(transition.enters!);
    }
  }

  /// 幸存者重新进场并接管唯一心跳；进场失败时 holder 已迁移、心跳暂停，
  /// 用户在该标签的下一次写动作会经 claim 重试。
  Future<void> _applyFallback(String fallbackId) async {
    final fallback = _tabs[fallbackId];
    if (fallback == null) {
      return;
    }
    final entered = await _performEnter(fallback);
    if (entered == null) {
      Log.logPrint('presence: 回退接管进场失败，等待用户主动操作');
      return;
    }
    _accountIds[fallbackId] = entered.accountId;
    try {
      await fallback.applyAccountEnter(
        accountDetail: entered.detail,
        guardStatus: entered.status,
        reentered: true,
      );
    } catch (e) {
      Log.logPrint('presence: 回退接管 apply 失败: $e');
    }
    _startHeartbeat(fallback, entered.accountId);
  }

  DouyinPresenceTab? _currentHolderTab() {
    final id = arbiter.holder;
    return id == null ? null : _tabs[id];
  }

  Future<void> _exitRoom(DouyinPresenceTab tab, String? accountId) async {
    try {
      final id = accountId ?? _guard.savedAccountId(Constant.kDouyin);
      if (id == null) {
        return;
      }
      await _guard.exitRoom(
        accountId: id,
        roomId: tab.guardRoomId,
        webRid: tab.guardWebRid,
        extra: tab.guardExtraArgs(),
      );
    } catch (e) {
      Log.logPrint('弹幕服务退出直播间失败: $e');
    }
  }

  bool _lastDetailFailed = false;

  /// 账号进场 HTTP 序列：账号详情 → ensureAccount → enterRoom（404 重注册
  /// 重试一次）。任一步失败返回 null，[_lastDetailFailed] 区分失败类型。
  Future<_EnterOutcome?> _performEnter(DouyinPresenceTab tab) async {
    _lastDetailFailed = false;
    final LiveRoomDetail detail;
    try {
      detail = await tab.fetchAccountDetail();
    } catch (e) {
      _lastDetailFailed = true;
      return null;
    }
    if (!_guard.configured) {
      return null;
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return null;
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
          return null;
        }
        accountId = newId;
        status = await _guard.enterRoom(
          accountId: newId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      }
      return _EnterOutcome(
        accountId: accountId,
        status: status,
        detail: detail,
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return null;
    }
  }

  void _startHeartbeat(DouyinPresenceTab tab, String accountId) {
    _heartbeatTimer?.cancel();

    Future<void> beat({bool retried = false}) async {
      // 回调延迟期间 holder 可能已切换：非 holder 不再续租
      if (arbiter.holder != tab.tabId) {
        return;
      }
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
          // 同账号在外部端进入别的房间：停止心跳、标 suspended，不抢回
          _heartbeatTimer?.cancel();
          arbiter.markSuspended(tab.tabId);
          tab.applySuspended();
          return;
        }
      } on DioException catch (e) {
        if (!retried && e.response?.statusCode == 404) {
          final newId = await _guard.reregister(Constant.kDouyin);
          if (newId != null && arbiter.holder == tab.tabId) {
            // 同步 accountId 缓存，否则该 holder 关闭时 exit 会打到过期账号
            _accountIds[tab.tabId] = newId;
            _startHeartbeat(tab, newId);
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
      }
    }

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => beat());
  }

  @visibleForTesting
  void stopHeartbeatForTesting() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }
}

class _EnterOutcome {
  _EnterOutcome({
    required this.accountId,
    required this.status,
    required this.detail,
  });

  final String accountId;
  final Map<String, dynamic> status;
  final LiveRoomDetail detail;
}
```

- [ ] **Step 5: 实现 LocalPresenceClient**

创建 `simple_live_app/lib/app/multiwindow/presence/local_presence_client.dart`，完整内容：

```dart
import 'douyin_presence_gateway.dart';
import 'presence_claimant.dart';

/// 主引擎内的控制器侧薄代理：直接函数调用。
/// M4 子引擎场景替换为 IPC 实现，控制器侧调用点不变。
class LocalPresenceClient {
  LocalPresenceClient(this._gateway, this._tab);

  final DouyinPresenceGateway _gateway;
  final DouyinPresenceTab _tab;

  Future<PresenceClaimResult> claim() => _gateway.claim(_tab);

  Future<void> release() => _gateway.release(_tab.tabId);

  Future<void> detach() => _gateway.detach(_tab.tabId);
}
```

- [ ] **Step 6: 运行测试确认通过**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/douyin_presence_gateway_test.dart
```
Expected: 全绿（21 个用例）。若 `回退接管 enter 失败` 用例中首次 claim(a) 受 `detailThrows` 初始值影响——按用例内注释的时机切换（初始 false，claim(a) 后再置位），实现无需特殊处理。

- [ ] **Step 7: analyze + 全量测试回归**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat analyze lib/app/multiwindow/presence test/douyin_presence_gateway_test.dart test/presence_arbiter_test.dart
```
Expected: `No issues found!`

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test < /dev/null 2>&1 | tail -3
```
Expected: `All tests passed!`（117 + T1 21 + T2 21 = 159 个用例）。

- [ ] **Step 8: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/presence/presence_claimant.dart simple_live_app/lib/app/multiwindow/presence/douyin_presence_gateway.dart simple_live_app/lib/app/multiwindow/presence/local_presence_client.dart simple_live_app/test/douyin_presence_gateway_test.dart
git commit -m "feat(windows): DouyinPresenceGateway 心跳全局仲裁——唯一 Timer、抢占让位、回退接管、外部抢占 suspended" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: LiveRoomController 接线网关 + shell binding 注册 + 端到端测试

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_store.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart`
- Modify: `simple_live_app/lib/routes/app_pages.dart`
- Test: `simple_live_app/test/presence_gateway_controller_test.dart`（新建）
- Modify: `simple_live_app/test/tab_store_test.dart`（既有 3 个用例适配异步签名，见 Step 8；断言内容不变）

**Interfaces:**
- Consumes: T2 的 `DouyinPresenceGateway / LocalPresenceClient / DouyinPresenceTab / PresenceClaimResult`；T1 语义。
- Produces: 无新接口；Windows 标签壳内抖音账号态全部经网关。

**现状锚点（修改前逐一核对行号，允许漂移）：**
- `live_room_controller.dart:150-160`：`_guardHeartbeatTimer` 字段、`presence`、`_enteringFuture`、`stopGuardHeartbeatForTesting()`——**旧路径全部保留**。
- `:180-207` `onInit`：在其中 `BackgroundAudioService.instance.setStopRequestedHandler(...)` 之后加网关接线。
- `:284-297` `refreshRoom()`：开头抖音 account 态 `unawaited(_exitGuardRoom())` 分流。
- `:394-420` `_requestGuardEnter()`：旧路径保留不动。
- `:423-438` `enterAsAccount()`：加网关分流。
- `:447-492` `_doEnterAsAccount()`：抽出 `_fetchAccountDetail()` 与 `_applyAccountEnter(...)` 复用，旧路径行为不变。
- `:626-629` `sendDanmaku` 成功后 `_startGuardHeartbeat(accountId)`：网关路径跳过（claim 后该标签必为 holder，心跳归网关）。
- `:746-747` `_sendGuardAction` 成功后 `_startGuardHeartbeat(accountId)`：同上。
- `:2189-2199` `resetRoom()`：抖音 account 态退出分流。
- `:2284-2303` `onClose()`：`unawaited(_exitGuardRoom())` 分流。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_app/test/presence_gateway_controller_test.dart`，完整内容：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FakeDanmaku extends LiveDanmaku {
  int starts = 0;
  int stops = 0;
  final cookies = <String?>[];

  @override
  Future<void> start(dynamic args) async {
    starts++;
    if (args is DouyinDanmakuArgs) {
      cookies.add(args.cookie);
    }
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    return DanmakuSendResult(success: true);
  }
}

class FakeDouyinSite extends DouyinSite {
  FakeDouyinSite(this._webRid, this._roomId, this.danmaku);
  final String _webRid;
  final String _roomId;
  final FakeDanmaku danmaku;

  String get webRidPlaceholder => _webRid;

  LiveRoomDetail buildDetail({required bool asAccount}) {
    return LiveRoomDetail(
      roomId: _webRid,
      title: 't',
      cover: '',
      userName: 'u',
      userAvatar: '',
      online: 1,
      status: true,
      url: 'https://live.douyin.com/$_webRid',
      danmakuData: DouyinDanmakuArgs(
        webRid: _webRid,
        roomId: _roomId,
        userId: 'uid',
        cookie: asAccount ? 'sessionid=abc' : 'ttwid=guest',
      ),
    );
  }

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async {
    return buildDetail(asAccount: asAccount);
  }
}

class FakeGuard extends GuardServerService {
  final enters = <String>[];
  final exits = <String>[];

  @override
  // ignore: must_call_super
  void onInit() {}

  @override
  bool get configured => true;

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<String?> reregister(String platform) async => 'acct1';

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    enters.add(roomId);
    return {'joined': false, 'starGuard': false};
  }

  @override
  Future<Map<String, dynamic>> heartbeat({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    return {'inRoom': true};
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String webRid = '',
    Map<String, dynamic>? extra,
  }) async {
    exits.add(roomId);
  }
}

class FakeDouyinAccount extends DouyinAccountService {
  final _logined = true.obs;

  @override
  RxBool get logined => _logined;

  @override
  // ignore: must_call_super
  void onInit() {}
}

LiveRoomController makeController({
  required String tabId,
  required FakeDouyinSite site,
  required DouyinPresenceGateway gateway,
}) {
  final c = LiveRoomController(
    pSite: Site(id: 'douyin', name: '抖音', logo: '', liveSite: site),
    pRoomId: site.webRidPlaceholder,
    pShareUrl: 'https://live.douyin.com/${site.webRidPlaceholder}',
    tabId: tabId,
  );
  c.detail.value = site.buildDetail(asAccount: false);
  c.bindPresenceGateway(gateway);
  return c;
}

void main() {
  late FakeDouyinSite siteA;
  late FakeDouyinSite siteB;
  late FakeGuard guard;
  late DouyinPresenceGateway gateway;

  setUp(() {
    siteA = FakeDouyinSite('111', 'room_111', FakeDanmaku());
    siteB = FakeDouyinSite('222', 'room_222', FakeDanmaku());
    guard = FakeGuard();
    gateway = DouyinPresenceGateway(guard);
  });

  tearDown(() async {
    gateway.dispose();
    Get.reset();
  });

  testWidgets('A 进入后 B 进入：A 被让位为游客弹幕，B 账号持有；关闭 B 后 A 自动接管',
      (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<DouyinAccountService>(FakeDouyinAccount());

    final a = makeController(tabId: 'tabA', site: siteA, gateway: gateway);
    final b = makeController(tabId: 'tabB', site: siteB, gateway: gateway);

    // A 显式进入
    var ok = await a.enterAsAccount();
    await tester.pump();
    expect(ok, isTrue);
    expect(a.presence.value, RoomPresence.account);
    expect(guard.enters, ['room_111']);
    expect(siteA.danmaku.cookies.last, 'sessionid=abc');

    // B 显式进入 → A 让位
    ok = await b.enterAsAccount();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(ok, isTrue);
    expect(b.presence.value, RoomPresence.account);
    expect(a.presence.value, RoomPresence.guest);
    expect(guard.enters, ['room_111', 'room_222']);
    expect(guard.exits, isEmpty, reason: '让位不发 exit');
    expect(siteA.danmaku.cookies.last, 'ttwid=guest',
        reason: 'A 重连游客弹幕');

    // 关闭 holder B → A 自动回退接管
    await gateway.release('tabB');
    expect(guard.exits, ['room_222']);
    expect(gateway.holderTabId, 'tabA');
    expect(a.presence.value, RoomPresence.account);
    expect(siteA.danmaku.cookies.last, 'sessionid=abc');
  });

  testWidgets('guard 未配置：claim 失败，控制器回 guest 并 toast', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        navigatorObservers: [FlutterSmartDialog.observer],
        builder: FlutterSmartDialog.init(),
        home: const Scaffold(body: SizedBox()),
      ),
    );
    Get.put<DouyinAccountService>(FakeDouyinAccount());
    final unconfigured = _UnconfiguredGuard();
    final gw2 = DouyinPresenceGateway(unconfigured);
    addTearDown(gw2.dispose);
    final c = makeController(tabId: 'tabC', site: siteA, gateway: gw2);

    final ok = await c.enterAsAccount();
    await tester.pump();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(ok, isFalse);
    expect(c.presence.value, RoomPresence.guest);
    expect(unconfigured.enters, isEmpty);
  });
}

class _UnconfiguredGuard extends FakeGuard {
  @override
  bool get configured => false;
}
```

- [ ] **Step 2: 运行测试确认失败**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/presence_gateway_controller_test.dart
```
Expected: 编译失败（`bindPresenceGateway` 不存在、控制器未接线）。

- [ ] **Step 3: 控制器加 import、字段与接线方法**

`live_room_controller.dart` import 区（按现有 package 字母序，`:19` tab_store import 之后）加：

```dart
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/local_presence_client.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
```

在 `_enteringFuture` 字段（约 :157）之后加：

```dart
  /// Windows 标签壳下抖音账号态走全局网关；Android / 路由模式为 null
  LocalPresenceClient? _presenceClient;
  DouyinPresenceTab? _presenceTab;

  DouyinPresenceGateway? _resolveGateway() {
    if (tabId == null) {
      return null;
    }
    if (!Get.isRegistered<DouyinPresenceGateway>()) {
      return null;
    }
    return Get.find<DouyinPresenceGateway>();
  }

  /// 接线入口（onInit 与测试共用）：仅抖音标签绑定到网关
  void bindPresenceGateway(DouyinPresenceGateway gateway) {
    if (site.id != Constant.kDouyin || tabId == null) {
      return;
    }
    _presenceTab = _ControllerPresenceTab(this);
    gateway.bindTab(_presenceTab!);
    _presenceClient = LocalPresenceClient(gateway, _presenceTab!);
  }
```

`onInit()` 中 `BackgroundAudioService.instance.setStopRequestedHandler(...)` 调用（约 :199-204）之后、`super.onInit();` 之前加：

```dart
    final gateway = _resolveGateway();
    if (gateway != null) {
      bindPresenceGateway(gateway);
    }
```

（`bindPresenceGateway` 是正式接线方法，测试也调用它，不加 `@visibleForTesting`。）

文件末尾（类外，`LiveRoomController` 所在文件顶层）加适配器。Dart 私有成员按库（文件）隔离，适配器与控制器同文件，可直接访问 `_guardRoomId` 等私有成员，无需在控制器上新增公开别名：

```dart
/// DouyinPresenceTab 的控制器适配器：网关只经此端口碰控制器状态，
/// M4 主引擎侧的远端代理实现同一接口。
class _ControllerPresenceTab implements DouyinPresenceTab {
  _ControllerPresenceTab(this._c);

  final LiveRoomController _c;

  @override
  String get tabId => _c.tabId!;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() => _c.fetchAccountDetail();

  @override
  String get guardRoomId => _c._guardRoomId;

  @override
  String get guardWebRid => _c._guardWebRid;

  @override
  Map<String, dynamic> guardExtraArgs() => _c._guardExtraArgs();

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) {
    return _c.applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: guardStatus,
      reentered: reentered,
    );
  }

  @override
  Future<void> applyYieldToGuest() => _c.applyYieldToGuest();

  @override
  void applySuspended() => _c.applySuspended();
}
```

- [ ] **Step 4: 控制器抽出账号进场/让位原语**

把 `_doEnterAsAccount()`（约 :447-492）重构为下列三个方法（旧路径 `_doEnterAsAccount` 保留并改为复用它们，行为与 toast/状态流转完全不变）：

在 `_doEnterAsAccount` 原位替换整段为：

```dart
  Future<bool> _doEnterAsAccount() async {
    final liveSite = site.liveSite;
    if (liveSite is! DouyinSite) return false;
    presence.value = RoomPresence.entering;
    final LiveRoomDetail accountDetail;
    try {
      accountDetail = await fetchAccountDetail();
    } catch (e) {
      SmartDialog.showToast("无法以账号身份读取该房间（可能被主播限制）");
      presence.value = RoomPresence.guest;
      return false;
    }

    final ({String accountId, Map<String, dynamic> status})? entered;
    try {
      entered = await _requestGuardEnter();
    } catch (e) {
      SmartDialog.showToast("进入直播间失败，已保持游客观看");
      presence.value = RoomPresence.guest;
      return false;
    }
    if (entered == null) {
      SmartDialog.showToast("进入直播间失败，已保持游客观看");
      presence.value = RoomPresence.guest;
      return false;
    }

    await applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: entered.status,
      reentered: false,
    );
    _startGuardHeartbeat(entered.accountId);
    return true;
  }

  /// 账号详情（网关端口与旧路径共用）
  Future<LiveRoomDetail> fetchAccountDetail() {
    return (site.liveSite as DouyinSite).getRoomDetail(
      roomId: "$roomId;$shareUrl",
      asAccount: true,
    );
  }

  /// 账号进场成功后的弹幕/详情/状态切换（旧路径与网关 applyAccountEnter 共用）
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    await liveDanmaku.stop();
    detail.value = accountDetail;
    online.value = accountDetail.online;
    liveStatus.value = accountDetail.status || accountDetail.isRecord;
    initDanmau();
    await liveDanmaku.start(accountDetail.danmakuData);
    _applyGuardStatus(guardStatus);
    presence.value = RoomPresence.account;
    addSysMsg(reentered ? "已自动在本标签恢复登录进入" : "已进入直播间");
  }

  /// 被更新打开的标签让位：播放不中断，游客详情重连弹幕（best-effort）
  Future<void> applyYieldToGuest() async {
    guardJoined.value = false;
    guardStarRoom.value = false;
    guardBadgeActive.value = false;
    presence.value = RoomPresence.guest;
    addSysMsg("已在更新打开的直播间标签中登录进入，本标签保持游客观看；该标签关闭后将自动切回。");
    try {
      final guestDetail = await (site.liveSite as DouyinSite).getRoomDetail(
        roomId: "$roomId;$shareUrl",
        asAccount: false,
      );
      await liveDanmaku.stop();
      detail.value = guestDetail;
      online.value = guestDetail.online;
      liveStatus.value = guestDetail.status || guestDetail.isRecord;
      initDanmau();
      await liveDanmaku.start(guestDetail.danmakuData);
    } catch (e) {
      // best-effort：游客取页/弹幕重连失败不影响播放，账号弹幕随服务端断开自然终止。
      // 不弹全局验证页（可能为后台标签），避免打断当前激活标签。
      Log.logPrint("presence: 让位后游客重连失败: $e");
    }
  }

  /// 外部端抢占：不切弹幕、不抢回；置 guest 使后续写动作走 claim 重进
  void applySuspended() {
    presence.value = RoomPresence.guest;
  }
```

现有 `_guardRoomId` / `_guardWebRid` / `_guardExtraArgs()`（约 :324-349）保持私有不动——同文件的 `_ControllerPresenceTab` 可直接访问。

- [ ] **Step 5: enterAsAccount 网关分流**

替换 `enterAsAccount()`（约 :423-438）为：

```dart
  Future<bool> enterAsAccount() async {
    if (presence.value == RoomPresence.account) return true;
    final inFlight = _enteringFuture;
    if (inFlight != null) return inFlight;
    if (!danmakuLogined) {
      await showDanmakuLoginDialog();
      return false;
    }
    final client = _presenceClient;
    final future = client == null
        ? _doEnterAsAccount()
        : _doEnterViaGateway(client);
    _enteringFuture = future;
    try {
      return await future;
    } finally {
      _enteringFuture = null;
    }
  }

  Future<bool> _doEnterViaGateway(LocalPresenceClient client) async {
    presence.value = RoomPresence.entering;
    final result = await client.claim();
    if (result.granted) {
      return true;
    }
    presence.value = RoomPresence.guest;
    SmartDialog.showToast(
      result.detailFailed
          ? "无法以账号身份读取该房间（可能被主播限制）"
          : "进入直播间失败，已保持游客观看",
    );
    return false;
  }
```

- [ ] **Step 6: 写动作后心跳恢复点改为网关路径 no-op**

`sendDanmaku` 中（约 :626-629）：

```dart
        result = await sendOnce(accountId);
        if (result.success) {
          // 主动发送已在服务端抢占房间，恢复本端心跳保活
          _startGuardHeartbeat(accountId);
        }
```

改为：

```dart
        result = await sendOnce(accountId);
        if (result.success && _presenceClient == null) {
          // 网关模式下：发送前 ensureAccountPresence 已使本标签成为 holder，
          // 唯一心跳由网关维护，控制器不再起 Timer
          _startGuardHeartbeat(accountId);
        }
```

`_sendGuardAction` 中（约 :745-748）：

```dart
        if (action == "light_up") guardBadgeActive.value = true;
        // 主动操作已在服务端抢占房间，恢复本端心跳保活
        _startGuardHeartbeat(accountId);
```

改为把该 `_startGuardHeartbeat(accountId);` 包进 `if (_presenceClient == null) { ... }`（light_up 赋值留在条件外）。

- [ ] **Step 7: refreshRoom / resetRoom / onClose 退房分流**

`refreshRoom()` 开头（约 :284-288）：

```dart
    // 账号态刷新即退房回游客：best-effort 退出（在 loadData 换详情前发起）
    if (site.id == Constant.kDouyin && presence.value == RoomPresence.account) {
      unawaited(_exitGuardRoom());
    }
```

替换为一个新私有方法的调用：

```dart
    if (site.id == Constant.kDouyin) {
      unawaited(_leaveDouyinPresence(unconditional: false));
    }
```

`resetRoom()` 中（约 :2194-2198）：

```dart
    if (this.site.id == Constant.kDouyin &&
        presence.value == RoomPresence.account) {
      await _exitGuardRoom();
    }
```

替换为：

```dart
    if (this.site.id == Constant.kDouyin) {
      await _leaveDouyinPresence(unconditional: false);
    }
```

`onClose()` 中（约 :2291，原代码对**全平台**无条件 `unawaited(_exitGuardRoom())`，含 bili/huya 自动进房退房）：

```dart
    unawaited(_exitGuardRoom());
```

替换为：

```dart
    unawaited(_leaveDouyinPresence(unconditional: true));
```

在 `_exitGuardRoom()` 方法旁新增统一分流方法：

```dart
  /// 抖音账号态离开：网关标签走 release（持有者发 exit + 次新回退接管；
  /// 已被让位 / suspended 的标签仅出栈）；Android 与无网关时维持各调用点
  /// 原有退房语义（onClose 全平台退房；refresh/reset 仅抖音账号态退房）。
  /// [unconditional]=true 仅用于 onClose。
  Future<void> _leaveDouyinPresence({required bool unconditional}) async {
    final client = _presenceClient;
    if (client != null) {
      final gateway = _resolveGateway();
      final inStack = gateway?.hasClaim(tabId!) ?? false;
      if (unconditional ||
          presence.value == RoomPresence.account ||
          inStack) {
        await client.release();
      }
      return;
    }
    if (unconditional) {
      await _exitGuardRoom();
    } else if (site.id == Constant.kDouyin &&
        presence.value == RoomPresence.account) {
      await _exitGuardRoom();
    }
  }
```

说明：
- `onClose`（unconditional=true）：holder（presence=account）释放；被 yield 的标签 presence=guest 但 inStack=true，仍需出栈（否则成为永远不会被回调的悬空 claimant），故条件含 `inStack`；suspended 标签同理。正常批量关闭时摘栈已由 TabStore 的 `batchRelease` 完成，这里的 release 命中未知 tab no-op。
- `refreshRoom` / `resetRoom`（unconditional=false）：holder 释放（次新标签接管），被让位标签只要还在栈中也释放（刷新/重置=放弃本标签的账号意图）；既不在栈也非账号态时零操作，随后游客重载。
- 非抖音标签 `_presenceClient==null`（绑定时已过滤），bili/huya 行为与现状逐字节一致。

- [ ] **Step 8: TabStore 批量关闭先摘栈 + tab_strip 调用点**

`lib/app/multiwindow/shell/tab_store.dart` 顶部加相对 import（与现有 `room_controller_registry.dart` import 同区）：

```dart
import '../presence/douyin_presence_gateway.dart';
```

构造函数与字段（现有 `TabStore({required this.registry, this.hasHome = true});` 原位替换）：

```dart
  TabStore({
    required this.registry,
    this.hasHome = true,
    this.presenceGateway,
  });

  final RoomControllerRegistry registry;
  final bool hasHome;

  /// Windows 标签壳注入；null（单元测试 / 未来其他宿主）时行为与 M2 完全一致
  final DouyinPresenceGateway? presenceGateway;
```

`closeOthers` 整体替换（变 `Future<void>`，unregister 前先批量摘栈）：

```dart
  Future<void> closeOthers(String tabId) async {
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

`closeRight` 同样改为 `Future<void>`，在 `final victims = tabs.sublist(index + 1);` 之后、for 循环之前插入：

```dart
    await presenceGateway?.batchRelease(
      victims.map((t) => t.tabId).toSet(),
    );
```

`closeAll` 在 `final all = tabs.toList();` 之后、for 循环之前插入：

```dart
    await presenceGateway?.batchRelease(
      all.map((t) => t.tabId).toSet(),
    );
```

既有 `test/tab_store_test.dart` 不传网关（构造可选参数），但 `closeOthers/closeRight` 签名由同步 `void` 变为 `Future<void>`，在 Dart 中即使网关为 null，async 函数体内的 `await null` 也会让出一个微任务、且所有抛错都汇入返回的 Future，故必须适配以下 3 个既有用例（只改异步写法，断言语义逐条不变）：

1. `test('closeOthers / closeRight', () {`（约 :102）改为 `() async {`，两处调用前加 `await`：

```dart
    await store.closeOthers(t1.tabId);
```

```dart
    await store.closeRight(t1.tabId);
```

2. 未知 tabId 两个用例（约 :134、:141）改为 `() async {`，同步抛错匹配改为对返回 Future 的 `expectLater`（async 函数即便在首个 await 前抛 ArgumentError 也不会同步抛出）：

```dart
  test('closeOthers 未知 tabId 抛 ArgumentError 且不改动标签', () async {
    store.open(req('a', '1'));
    await expectLater(store.closeOthers('nope'), throwsArgumentError);
    expect(store.tabs.length, 1);
    expect(registry.registered.length, 1);
  });

  test('closeRight 未知 tabId 抛 ArgumentError 且不改动标签', () async {
    store.open(req('a', '1'));
    await expectLater(store.closeRight('nope'), throwsArgumentError);
    expect(store.tabs.length, 1);
    expect(registry.registered.length, 1);
  });
```

`closeAll` 用例（约 :125）本就是 `() async` + `await`，不动；其余用例不触碰这三个方法，无需改。

`lib/app/multiwindow/shell/tab_strip.dart`：顶部加 `import 'dart:async';`，右键菜单两个 case（约 :170-173）改为：

```dart
      case 'others':
        unawaited(store.closeOthers(descriptor.tabId));
      case 'right':
        unawaited(store.closeRight(descriptor.tabId));
```

（菜单回调不 await：与 M2 的即点即关体感一致；摘栈/HTTP 在后台完成，且先于同函数内的 unregister。）

- [ ] **Step 9: kShell binding 注册网关并注入 TabStore**

`app_pages.dart` 顶部 import 区加（字母序）：

```dart
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
```

（`guard_server_service.dart` 若已有 import 则不重复。`GuardServerService` 已在 `main.dart:141` 启动期 `Get.put`，此处 `GuardServerService.instance` 必然可解析。）

kShell 的 `BindingsBuilder`（约 :65-69）改为——网关必须在 TabStore **之前**实例化（TabStore 构造注入它）；二者都在任何标签 register 之前就绪：

```dart
      binding: BindingsBuilder(() {
        Get.put<RoomControllerRegistry>(GetxRoomControllerRegistry());
        Get.put(IndexedController());
        Get.put(DouyinPresenceGateway(GuardServerService.instance));
        Get.put(
          TabStore(
            registry: Get.find<RoomControllerRegistry>(),
            presenceGateway: Get.find<DouyinPresenceGateway>(),
          ),
        );
      }),
```

- [ ] **Step 10: 跑新测试确认通过**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/presence_gateway_controller_test.dart
```
Expected: 2 个用例全绿。失败时先核对：适配器端口读取的 `guardRoomId` 是否来自预置游客详情（makeController 中 `c.detail.value = guestDetail`）；yield 是 `unawaited` 的，测试中需要一次 `tester.pump(Duration(milliseconds:50))` 等微任务（已含）。

- [ ] **Step 11: 全量门禁**

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat analyze lib/modules/live_room/live_room_controller.dart lib/app/multiwindow lib/routes/app_pages.dart test/presence_gateway_controller_test.dart test/presence_arbiter_test.dart test/douyin_presence_gateway_test.dart test/tab_store_test.dart < /dev/null
```
Expected: 无新增 issue（基线 22 条存量逐条比对，不得增加）。

Run:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test < /dev/null 2>&1 | tail -3
```
Expected: `All tests passed!`（117 + T1 21 + T2 21 + T3 2 = 161 个用例；现有 `live_room_presence_test.dart` 9 用例零改动通过——tabId==null 走旧路径；`tab_store_test.dart` 仅 Step 8 所述 3 处异步适配，断言语义不变）。

Run（stdin /dev/null + 日志重定向，禁止管道 tail；可后台执行后轮询日志末尾）:
```bash
cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug < /dev/null > /tmp/m3-build.log 2>&1; tail -3 /tmp/m3-build.log
```
Expected: `√ Built build\windows\x64\runner\Debug\simple_live_app.exe`。挂死按 Global Constraints 的已知方法清树重试一次。

- [ ] **Step 12: 提交**

```bash
git add simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/lib/app/multiwindow/shell/tab_store.dart simple_live_app/lib/app/multiwindow/shell/tab_strip.dart simple_live_app/lib/routes/app_pages.dart simple_live_app/test/presence_gateway_controller_test.dart simple_live_app/test/tab_store_test.dart
git commit -m "feat(windows): 抖音标签接入心跳网关——claim 抢占/让位游客弹幕/关闭回退接管/批量关闭摘栈，Android 路径不变" -m "既有 tab_store 用例适配 closeOthers/closeRight 异步签名" -m "Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

## 手工 GUI 验收（Task 3 合并后由用户在 Windows 执行，subagent 无法观察原生窗口）

前置：guard 弹幕签名服务已配置并登录抖音；`flutter run -d windows`。

1. 开 3 个抖音直播间标签 A→B→C，依次点「进入直播间」：每个新标签进入后，旧标签聊天栏出现逐字提示「已在更新打开的直播间标签中登录进入，本标签保持游客观看；该标签关闭后将自动切回。」，旧标签画面/声音不中断、弹幕以游客继续；C 为账号态。
2. 抓 guard 服务端日志或 app 日志：任意时刻只有一路 20s 心跳，房间随最新进入的标签切换；A/B 被让位时**没有** exitRoom 请求。
3. 关闭 C：服务端先 exit C 房间，随后 B 自动 enter 接管，B 聊天栏出现「已自动在本标签恢复登录进入」，B 弹幕恢复账号身份，心跳只打 B；再关 B，A 接管；关 A 后无心跳、无残留 Timer。
4. 批量关闭：A→B→C 依次 claim（C 为 holder，A/B 在栈中已让位）后，右键 A 选「关闭其他标签」（受害者 B、C 含 holder，幸存者 A）——guard 日志只见一次 exit（C 房间）和一次 enter（A），无 enter/exit 风暴，之后心跳只打 A；再做一次对照：重新 A→B→C 后右键 C 选「关闭其他标签」（受害者 A、B 不含 holder）——零 exit、零 enter，C 心跳不中断。定时关闭触发 `closeAll`（或首页导致全关）时只见一次 exit（C 房间）、无 fallback enter，之后心跳彻底停止。
5. 在已让位的 A（游客态）直接发弹幕：A 抢回 holder（B 让位为游客），弹幕发送成功。
6. 用手机同账号进入另一直播间：PC holder 心跳下一拍返回 inRoom!=true，心跳停止、不自动抢回；回到 PC 在该标签发弹幕，重新 claim 成功。
7. 房间内点刷新：账号标签释放（次新标签接管），本标签回游客重载；再次「进入直播间」可重新 claim。
8. bili / huya 标签：自动进房、发弹幕、退房行为与 M2 完全一致（不经网关）。
9. Android 回归本轮仍延后（用户裁决），合并/发布前必须补测；代码守卫：tabId==null 路径分支由 `live_room_presence_test.dart` 9 用例与评审保证。

## 非目标（本计划不做）

- IPC / 子引擎 / 子窗 / 跨窗拖拽（M4）；`detach` 仅状态机与网关层就绪，无生产调用点。
- bili/huya 多标签服务端页面抢占仲裁。
- 子窗登录代办、设置写穿等 M4 数据面。
- 后台标签的其他全局 UI 收口（DouyinGuestVerifyGate、斗鱼 relogin 等，M2 已记账 follow-up，M3/M6 处理）；yield 游客重连刻意不弹验证页。
- suspended 态的专属 UI 文案/按钮（复用 guest 态入口）。
