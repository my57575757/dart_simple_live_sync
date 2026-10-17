# M4-4 标签跨窗迁移（菜单先行 + presence 无缝 handoff）设计

日期：2026-10-17
前置：M4-3（账号面 presence IPC，已本地合入 my_dev，HEAD 0f0365c）
分支：就地特性分支（不用 worktree），SDK 固定 `C:/tools/flutter347/flutter/bin/flutter.bat`

## 1. 目标与范围

simplelive Windows 多窗口下，把一个直播间标签在窗口之间迁移，交互类似浏览器标签移动：

- 主窗口标签 → 新窗口 / 已存在的子窗口；
- 子窗口标签 → 新窗口 / 主窗口 / 另一个子窗口；
- 标签身份（tabId）保持不变；
- 抖音账号态标签迁移全程**不发 exitRoom、不重发 enterRoom、唯一心跳 Timer 不产生额外心跳拍**（服务端浏览器页面会话不断、不重复进场）；
- 账号态在目标窗落地后自动复刻（账号详情 + 账号弹幕重连），源窗关闭。

交互形态（用户裁决）：**菜单先行**。本期不做跨引擎真拖拽（desktop_multi_window 每窗独立 Flutter renderer，Draggable/DragTarget 不跨窗），右键菜单承载全部迁移入口。

presence 语义（用户裁决）：**宽限无缝**。不使用「detach 后次新标签接管、目标窗再抢回」的重进语义。

### 范围内

- `mw_` 窗口管理协议（子↔主）：请求迁移、列举窗口、打开/关闭标签。
- 网关 handoff（rehome）：同 tabId 换引擎端口，栈/holder/心跳会话不动。
- 预定 tabId 开窗/落标签全链路。
- 源标签「迁移关闭」：抑制控制器 onClose 的 presence leave。
- WindowRegistry 支持子窗多标签与 tab key 挪动。
- TabStrip 右键菜单（主窗 + 子窗）。

### 范围外

- 跨窗真拖拽（含「松手按光标判窗」的伪拖拽）：留后续 spike。
- M5 内容：子窗弹幕输入 UI/IME、bili/huya/douyu/twitch 子窗写动作、非抖音→抖音切房 client 动态重绑。
- Android / TV / 首页路径：行为零变化（无 tabId 路径一行不动；非 Windows 不注册任何 M4-4 服务与菜单项）。

## 2. 现状关键事实（设计依据）

- dmw 每引擎每 channel 单 method handler 槽位：主窗唯一 handler 在 `MainDataPlaneService.onInit` 挂接，default 分支经 `unhandledMethodHandler` 单点委托，当前绑 `MainPresenceService.handleCall`（仅解析 `pr_`）。
- `MainPresenceService._register`：无条件 `_tabWindow[tabId] = windowId`（天然支持改挂）；非抖音返回 false。
- `MainPresenceService._release/_batchRelease/_guardSend` 均有索引归属门：windowId 不匹配时 release 幂等 true、guard 返回 not_holder。旧窗迟到消息因此天然无害。
- `MainPresenceService._claim`：先校验索引归属；`_remoteTabs` 中同 tabId 旧 windowId 的 RemotePresenceTab 会被 markClosed 摘除重建；claim 前无条件 `tab.updateGuardArgs(...)`；随后 `gateway.claim(tab)`。
- 网关 `claim` 短路：`arbiter.holder == tabId && _ready.contains(tabId)` 直接 granted，不重走进场。
- 网关 `bindTab`：同 tabId 覆盖 `_tabs[id]`（主窗控制器 onInit 已据此绑定本地适配器）。
- 心跳 `_startHeartbeat` 的 beat 闭包持端口对象，读取 `tab.guardRoomId/guardWebRid/guardExtraArgs()`；每拍校验 `arbiter.holder == tab.tabId`；HTTP 全经 GuardServerService，不经过 tab 端口。重挂 Timer = cancel + Timer.periodic，零 HTTP。
- 控制器所有退场（onClose / refresh / reset）经 presence client 的 release；`pr_detach` 协议已通且有单测，但**无生产调用点**。
- 子窗 `args.mainWindowId` 可用；bootstrap 已自行挂子端总 handler（dp_changed、三 apply、focus_tab、close_window）。
- 子窗移空标签：`RoomShellPage._emptyWorker` 监听 store.tabs 为空即 `_forceClose`，已具备「最后一个标签移走自动关窗」语义。
- 新窗 `hiddenAtLaunch: true`，bootstrap `waitUntilReadyToShow` 后自行 show；已存在窗由 `focus_tab` show/focus/activateByKey。
- 子端 register 在控制器 onInit 发出（best-effort unawaited）；同引擎 method channel FIFO。
- `moveTabToNewWindow`（M4-1）当前仅游客态可用：先 createRoomWindow（快照）再 store.close，账号态菜单置灰。M4-4 由新编排取代。

## 3. 架构总览

唯一编排者是主引擎的 `WindowOpenService`（WOS）。presence 权威状态全部留在主引擎 `DouyinPresenceGateway`，迁移期间栈、holder、accountId、_ready、服务端会话、心跳 Timer 均不变化，只更换 tabId 对应的「端口」（本地控制器适配器 ↔ RemotePresenceTab），并在新窗复刻一次账号态 UI。

三目标 × 两源共六个方向，时序统一：

```
① WOS.moveTabToWindow({tabId, sourceWindowId(null=主窗), target(new/main/<id>)})
② MainPresenceService.prepareHandoff(tabId, destWindowId)
     · 网关查无此 tab（非抖音/纯游客）→ 返回 null：纯壳迁移，不等待
     · 否则建 _handoffs 条目（10s 超时 Timer + Completer）
③ 目标落标签（携带/指定同一 tabId）：
     new   → createRoomWindow(RoomTabArg(tabId: 同一 id))
     child → port.invoke(dest, 'mw_open_tab', {tabId,...})
     main  → 主窗 store.open(request, tabId: 同一 id)
④ presence rehome：
     new/child → 新控制器 onInit 的 pr_register 到达 MPS，命中 handoff：
                 索引改挂 → 换 RemotePresenceTab（复制 guard 参数）→
                 gateway.rehome(id, newPort:) → complete
     main     → store.open 后 WOS 显式调 MPS.rehomeLocal(id)：
                 摘远端索引/RemoteTab → gateway.rehome(id)（用 onInit bindTab 后的本地端口）
⑤ 成功后关源：
     源主窗 → store.closeForMove(tabId)
     源子窗 → port.invoke(source, 'mw_close_tab', {tabId})
⑥ WindowRegistry 挪动 tab key；focus 目标窗/标签
```

关键顺序：②—④ 期间源标签照常播放与续租；⑤ 只在 ④ 成功后发生；任何失败标签从未离开源窗。

## 4. 网关 handoff（DouyinPresenceGateway）

### 4.1 入场 status 缓存

新增 `final Map<String, Map<String, Object?>> _lastEnterStatus = {};`

- `_claim` 进场成功（entered != null）：`_lastEnterStatus[tab.tabId] = entered.status`（apply 失败也缓存：服务端已进场，status 有效）。
- `_applyFallback` 进场成功：同样缓存。
- `_remove`（release/detach）、`_batchRelease`：随 tab 清除缓存条目。
- rehome 不清除（tabId 延续）。

### 4.2 rehome

```dart
Future<void> rehome(String tabId, {DouyinPresenceTab? newPort}) =>
    _serialized(() => _rehome(tabId, newPort));

Future<void> _rehome(String tabId, DouyinPresenceTab? newPort) async {
  if (newPort != null) {
    _tabs[tabId] = newPort;          // child 目标：MPS 新建的 RemotePresenceTab
  }
  final tab = _tabs[tabId];
  if (tab == null) return;           // 纯壳/非抖音：网关无事可做
  final holderReady = arbiter.holder == tabId && _ready.contains(tabId);
  if (!holderReady) return;          // guest / suspended：新窗本就是游客态，不 apply
  final accountId = _accountIds[tabId];
  if (accountId != null) {
    _startHeartbeat(tab, accountId); // 旧 Timer cancel、新 Timer 起；零 HTTP
  }
  if (tab.isClosed) return;
  final status = _lastEnterStatus[tabId];
  if status == null) return;
  try {
    await tab.applyReentered(Map<String, dynamic>.from(status));
  } catch (e) {
    Log.logPrint('presence: 迁移复刻账号态失败: $e'); // best-effort，不回滚
  }
}
```

性质：

- 不调用 arbiter 任何方法、不发 exitRoom/enterRoom、不改 _ready/_accountIds。
- 与 claim/release/guard 写动作同在 `_serialized` 串行域：新窗 register 之后经同通道到达的 pr_claim/pr_guard 天然 happens-after rehome。
- applyReentered 失败不回滚：服务端会话与心跳仍健康，新窗保持游客弹幕，用户在新窗首次写动作时 claim 命中「holder+ready 短路 granted」，MPS._claim 的 updateGuardArgs 正常执行；但此时不会自动补 apply（短路不 apply）——因此 applyReentered 失败后新窗账号 UI 恢复依赖用户写动作路径的 claim。
  - 补偿规则：**claim 短路分支若该 tab 端口对象是「rehome 后从未成功 apply」的新端口**，补一次 best-effort applyReentered（用缓存 status）。实现为 rehome 置位 `_pendingApplyReplay` 集合，applyReentered 成功后移除；`_claim` 短路返回前检查该集合并补放（不阻塞 granted 返回）。
- suspended 标签（holder==null）迁移后：新窗游客态与 suspended 语义一致；arbiter._suspended 按 tabId 保留；用户写动作 → claim 正常清 suspended 重进场（既有逻辑）。

### 4.3 端口接口扩展

`DouyinPresenceTab` 新增：

```dart
/// 跨窗迁移落地：以最近一次进场 status 在新引擎复刻账号态（reentered:true）。
/// 远端实现：下发 pr_apply_enter（cookie 当刻读取，accountDetail 不下发）。
/// 本地实现：自取账号详情后复用 applyAccountEnter 流程。
Future<void> applyReentered(Map<String, dynamic> guardStatus);
```

- `RemotePresenceTab.applyReentered(status)`：等同现有 applyAccountEnter 下发体（invoke mApplyEnter，cookie 经 _readCookie 当刻读，reentered:true，status 透传），不使用 accountDetail。
- 控制器内 `_ControllerPresenceTab.applyReentered(status)`：`final detail = await fetchAccountDetail();` 后调用与 applyAccountEnter 相同的内部实现（detail, status, reentered:true）。为避免重复，applyAccountEntry 实现体抽成一个私有方法供两者调用。
- 测试假端口（gateway/控制器测试中的 fake）同步补实现。

## 5. 主端 presence 服务（MainPresenceService）

### 5.1 handoff 表

```dart
class _Handoff {
  _Handoff(this.destWindowId) {
    completer = Completer<void>();
  }
  final String destWindowId;
  late final Completer<void> completer;
  Timer? timer;
  bool settled = false;
}
final Map<String, _Handoff> _handoffs = {};
static const Duration handoffTimeout = Duration(seconds: 10);
```

- `Future<void>? prepareHandoff(String tabId, String destWindowId)`：
  - 网关 `_tabs` 不可见（私有）——经网关新增 bool 查询 `bool isTrackedTab(String tabId) => _tabs.containsKey(tabId);`（纯读，测试可见）。
  - 非跟踪 tab：返回 null（纯壳迁移）。
  - 已有在途 handoff（同一 tab 重复发起）：先以失败结算旧条目（迁移被新请求取代的场景实际被 UI 屏蔽，此处仅防御）。
  - 建条目 + 10s Timer：到期 settled=false 路径——清表，completer.completeError(HandoffTimeout)。编排层捕获。
- `pr_register` 改造（_register 内，decode 与非抖音门不变），最终算法：
  1. `_tabWindow[call.tabId] = call.windowId;`（既有改挂语义保留，先于一切）。
  2. `final handoff = _handoffs[call.tabId];`
  3. 当 `handoff != null && call.windowId != registry.mainWindowId`：无条件构造新 RemotePresenceTab（目标必为子窗）。guard 参数来源：
     - 旧 `_remoteTabs[tabId]` 存在（子→子）：从旧 tab 复制 guardRoomId/guardWebRid/guardExtra，并 `old.markClosed()`；
     - 旧 tab 不存在（主→子，源端口是主窗本地适配器）：从 `gateway.currentGuardArgsFor(tabId)` 读取（新增只读访问，返回 `({String roomId, String webRid, Map<String,Object?> extra})?`）复制；读不到（纯壳）则留空，首次 pr_claim 既有 updateGuardArgs 会补齐。
     - `_remoteTabs[tabId] = 新 tab`。
  4. 无 handoff 时保留既有重建门（existing.windowId != call.windowId 才 markClosed 重建），行为与 M4-3 完全一致。
  5. handoff 存在时：`unawaited(gateway.rehome(call.tabId, newPort: newRemote).then((_) => _settleHandoff(tabId), onError: (e) => _failHandoff(tabId, e)))`——不阻塞 register 回执；同引擎后续 pr_claim/pr_guard 经网关 `_serialized` 链天然排在 rehome 之后。
  6. return true。
- `rehomeLocal(String tabId)`（dest=main，WOS 在主窗 store.open 后调用）：
  ```dart
  final old = _remoteTabs.remove(tabId);
  old?.markClosed();
  _tabWindow.remove(tabId);              // 迁入主窗：不再是远端标签
  await gateway.rehome(tabId);           // 端口已被主窗控制器 onInit bindTab 覆盖
  _settleHandoff(tabId);
  ```
  - 主窗控制器 onInit 只 bindTab（不发 register），故 main 路径不经 _register。
- 死亡对账 `_onChildWindowsClosed`：移除窗口名下索引后，对其中仍在 `_handoffs` 的 tabId 一律失败结算（源窗死亡：completeError；目标窗死亡：同样失败，由编排层回滚——见 §8）。
- settle/timeout 时取消 Timer、清条目；重复 settle 幂等（settled 标志）。

### 5.2 不改的部分

- claim/release/batch/guardSend 逻辑不变（索引门、重建门、updateGuardArgs 全部既有行为）。
- pr_detach case 保留，M4-4 不新增生产调用点（见 §11 Ruling）。

## 6. 窗口管理协议（mw_）

新文件 `lib/app/multiwindow/window/window_control_protocol.dart`，形态对齐 PresenceProtocol：私有构造、常量方法名、显式 encode/decode、非法载荷返回 null、全部 JSON 兼容。**不含任何凭据字段。**

方法名：

| 方向 | 方法 | 载荷 |
|---|---|---|
| 子→主 | `mw_request_move` | `{sourceWindowId, tabId, siteId, roomId, shareUrl, target}` |
| 子→主 | `mw_list_windows` | 无参（回执不含来源信息，子端自行排除自己的 windowId） |
| 主→子 | `mw_open_tab` | `{tabId, siteId, roomId, shareUrl, activate}` |
| 主→子 | `mw_close_tab` | `{tabId}` |

主端 method handler 收不到来源 windowId（dmw 事实，与 pr_ 载荷自带 windowId 同理），故 `mw_request_move` 必带 `sourceWindowId`（子端自己的 windowId）。

target / window id 线值：

- `'__new__'`：新建窗口；
- `'__main__'`：主窗口；
- 其余为 dmw windowId 字符串。

`mw_list_windows` 回执：`List<Map>`，每项 `{id, label}`；主窗固定 `{id:'__main__', label:'主窗口'}`；子窗 `{id: windowId, label:'直播间窗口 $N'}`，N 按 WindowRegistry 开窗序（1 起）。

`mw_request_move` 回执：`{ok: true}` / `{ok:false, message:'...'}`（固定中文文案，无异常回显）。

编码类：`WindowControlProtocol.encodeRequestMove/ decodeRequestMove / encodeOpenTab/decodeOpenTab / encodeCloseTab/decodeCloseTab / encodeWindowList/decodeWindowList`。call 类 `MoveRequestCall`、`OpenTabCall`、`CloseTabCall`、`WindowListEntry`。

## 7. 窗口层改动

### 7.1 WindowOpenService

构造增加可空后绑引用（MPS 构造晚于 WOS，app_pages 装配后 setter 注入）：

```dart
MainPresenceService? presenceService; // app_pages 构造 MPS 后赋值
```

新方法：

```dart
Future<Map<String, Object?>> handleWindowCall(String method, Object? arguments);
// mw_request_move → _move(...) 回执；mw_list_windows → listWindowEntries()

List<WindowListEntry> listMoveTargets({required String? excludeWindowId});

Future<void> moveTabToWindow({
  required String tabId,
  String? sourceWindowId, // null=主窗
  required String target, // __new__ | __main__ | windowId
  String? siteId, String? roomId, String? shareUrl, // 子源时由载荷提供
});
```

`moveTabToWindow` 编排（§3 六向统一）：

1. 取 descriptor：源主窗从 `store.tabs`；源子窗用载荷四元组（tabId 权威）。主源查不到则返回失败。
2. destWindowId 解析：`__main__` → registry.mainWindowId；`__new__` → createRoomWindow 返回的 windowId；其余直接使用（校验仍在 registry，否则失败）。
3. `final handoff = mps?.prepareHandoff(tabId, destWindowId) ?? null;`（MPS 不存在/非跟踪均得 null）。
4. 落标签：
   - new：`createRoomWindow(RoomWindowArgs(tabs:[RoomTabArg(siteId, roomId, shareUrl, tabId: tabId)], snapshot: WindowSnapshotBuilder.buildDataSnapshot(), mainWindowId: ...).encode())`；成功后 `registry.addChildTab(handle.windowId, tabKey)`（新窗 set）。
   - child：`port.invoke(dest, mw_open_tab, encode(activate:true))`；成功后 `registry.addChildTab(dest, tabKey)`。
   - main：`store.open(TabOpenRequest(...), tabId: tabId)`；随后 `await mps.rehomeLocal(tabId)`（无 handoff 时 mps 仍可能需摘远端索引——rehomeLocal 对无 handoff/无索引幂等；统一调用）。
5. new/child：`await handoff`（null 则跳过）；成功后继续；超时/失败走 §8 回滚。
6. 关源：源主窗 `store.closeForMove(tabId)`；源子窗 `port.invoke(source, mw_close_tab, {tabId})`（best-effort，失败仅日志：源窗若已死，reconcile 兜底）。
7. registry 挪动：源主窗→子窗（步骤 4 已登记，无需摘主窗——主窗标签不在 registry）；子窗→主窗 `registry.removeChildTab(source, tabKey)`；子窗→子窗 `registry.moveChildTab(source, dest, tabKey)`。
8. 聚焦：new 窗 bootstrap 自 show；child 目标落标签后 invoke 既有 `focus_tab`（tabKey）；main 目标标签经 store.open(activate:true) 已激活，主窗 `windowManager.show()/focus()`（仅源是子窗时）。
9. 全局去重校验：迁移在途不经过 openInNewWindow 的去重路径；同一 tabKey 的既存位置就是源自己，registry 改动在最后，期间不响应新开窗（菜单操作串行于主引擎 Isolate，无并发）。

`moveTabToNewWindow`（旧 M4-1 方法）：删除，调用点（TabStrip）改走 moveTabToWindow(target:__new__)。

### 7.2 WindowRegistry

- `registerChild` 保留（createRoomWindow 路径用）；新增：
  - `void addChildTab(String windowId, String tabKey)`：既有 set 合并（不存在窗则抛 StateError——窗必须先 register）。
  - `void removeChildTab(String windowId, String tabKey)`：摘除；空 set 保留（窗存活与否由 reconcile 对账）。
  - `void moveChildTab(String fromWindowId, String toWindowId, String tabKey)`：remove + add。
  - `List<({String id, int ordinal})> childWindowOrder()`：供窗口列表编号（ordinal = _order 下标 + 1）。

### 7.3 TabStore / 控制器（源端关闭）

- `TabStore.open(request, {bool activate = true, String? tabId})`：`final id = tabId ?? _uuid.v4();`，其余逻辑不变。
- `TabDescriptor closeForMove(String tabId)`：
  ```dart
  final c = registry.controllerForTabId(tabId);
  c?.debugMarkMovedAway();
  return close(tabId);
  ```
- `LiveRoomController`：
  - `bool _movedAway = false;`
  - `@visibleForTesting void debugMarkMovedAway() { _movedAway = true; }`
  - onClose 中：`if (!_movedAway) { unawaited(_leaveDouyinPresence(unconditional: true)); }`（其余 onClose 清理一律不变）。
  - 子端 IPC presence client 随控制器丢弃，不发 pr_release/pr_detach。
- `RoomTabArg` 增加 `final String? tabId`，toJson/fromJson 透传（缺失=null，兼容旧参数）。
- bootstrap 开窗循环：`store.open(TabOpenRequest(...), tabId: tab.tabId)`。

### 7.4 子端

- 新文件 `lib/app/multiwindow/window/sub_window_control_port.dart`：
  - `abstract class SubWindowControlPort { Future<Object?> invokeMain(String method, [Object? args]); }`
  - `DmwSubWindowControlPort(this.mainWindowId)` 生产实现（WindowController.fromWindowId(mainWindowId).invokeMethod）。
- 新文件 `lib/app/multiwindow/window/sub_window_control_service.dart`（GetxService，仅子窗 Windows 装配）：
  - 构造注入 SubWindowControlPort、TabStore；
  - `Future<List<WindowListEntry>> requestWindowList()`；
  - `Future<bool> requestMove({required TabDescriptor tab, required String target})`（编码 mw_request_move，失败→false + toast 固定文案）；
  - `Future<Object?> handleCall(method, arguments)`：mw_open_tab（try/catch 包 store.open：成功返回 true、未知 site 等异常返回 false，主端按 §8 失败处理；带 tabId、activate）、mw_close_tab（store.closeForMove，返回 true）。
- bootstrap：
  - 仅 `presencePort != null` 的同款门控下构造 controlPort（mainWindowId 非空）并 put service；
  - 子端总 handler 增加两 case 委托 `controlService?.handleCall(...)`；dmw 单 handler 槽位仍只在 bootstrap 挂这一次（委托，不重挂）。
- bootstrap 构造 RoomWindowArgs 解码处无需改（tabId 已在 RoomTabArg）。

### 7.5 主端 handler 路由

app_pages：`MainDataPlaneService(unhandledMethodHandler: ...)` 由直接绑 MPS 改为前缀路由闭包：

```dart
Future<Object?> routeUnhandled(String method, Object? arguments) async {
  if (method.startsWith('pr_')) {
    return mainPresenceService.handleCall(method, arguments);
  }
  if (method.startsWith('mw_')) {
    return Get.find<WindowOpenService>().handleWindowCall(method, arguments);
  }
  return null;
}
```

dp_ 方法不经此闭包（MainDataPlaneService 自身 switch 先行）。

### 7.6 TabStrip 菜单

- 门控：`Platform.isWindows` 且（主窗 `Get.isRegistered<WindowOpenService>()` 或子窗 `Get.isRegistered<SubWindowControlService>()`）。
- 「移到新窗口」：账号态不再置灰（移除 isAccount 禁用与「下一阶段支持」Tooltip）。
- 「移到其他窗口」：级联菜单。
  - 主窗：同步取 `WindowOpenService.instance.listMoveTargets(excludeWindowId: null)`（主窗不在候选内？候选=已存在子窗；主窗标签不能移到主窗。故主窗发起时列子窗，无子窗隐藏该项；「新窗口」始终有）。
  - 子窗：点击项后 `await controlService.requestWindowList()` 再 showMenu 二级（排除自己 windowId；列表含主窗口与其他子窗；仅自己一个窗口时该项隐藏——一级菜单渲染前无法同步知道列表，采用：始终显示该项，点击后若候选为空则 toast「没有可移入的其他窗口」）。
  - 选定后：主窗 `moveTabToWindow(tabId:..., sourceWindowId:null, target:id)`；子窗 `controlService.requestMove(tab: descriptor, target: id)`。
- 非 Windows：整个移动菜单区零改动。

## 8. 失败与竞态矩阵

| 情形 | 行为 |
|---|---|
| createRoomWindow 抛错 | 清 handoff；toast「新建窗口失败」；源标签不动 |
| mw_open_tab invoke 失败（目标窗已死） | 不登记 registry；toast「目标窗口无响应」；等 handoff 超时自动清表；源不动 |
| handoff 10s 超时（new/child register 未到） | new：best-effort invoke 目标窗 close_window；child：保守不回滚目标标签（无法确认其状态），toast「移动超时，标签可能已在目标窗口」；清表；源栈/心跳从未改变，继续播放 |
| rehome applyReentered 失败 | 不回滚（见 §4.2 补偿：下次 claim 短路时补放；再失败则用户写动作驱动 claim 完整链路） |
| handoff 中源子窗进程死亡 | reconcile→死亡对账摘栈释放，handoff 失败结算；已落目标的标签以游客态存活（new/child）；main 目标 store.open 已发生则保留为普通主窗标签 |
| rehome 完成后、关源前目标窗死亡（毫秒窗） | 死亡对账按新 windowId 释放栈；源标签随后关闭。极端下用户若在源标签写动作（竞态窗口内）claim 重走进场自愈。记为已知竞态，不额外防护 |
| 迁移在途源窗发 pr_guard_send | 索引改挂前：正常执行（holder 始终是该 tab）；改挂后：索引门拒 not_holder，用户在新窗操作即正常 |
| 非抖音标签迁移 | prepareHandoff 返回 null；壳流程一致；无 pr_ 流量、无超时等待 |
| 目标窗已含同 tabKey 标签 | UI 层不出现该目标（全局去重：tab 当前所在窗即源，候选已排除源）；防御性：openTab 时 store.open 命中既有 key 仅激活，不重复建 |
| 子窗最后一个标签移走 | _emptyWorker 既有逻辑自动关窗；主端 reconcile 随后清 registry；closeAll 的 batchRelease 经索引门过滤为空 no-op |

## 9. 测试策略

全部为单测/widget 测（fake 端口、fake_async），与 M2–M4-3 同体系。

1. **WindowControlProtocol**：四组 encode/decode、非法载荷 null、线值常量。
2. **网关 rehome**（fake tab + fake guard，复用现有 gateway 测试夹具）：
   - holder+ready 迁移：无 enterRoom/exitRoom 调用计数；心跳 Timer 重挂（fakeAsync 推进后心跳拍经新端口 guard 参数）；新端口收到 applyReentered，内容等于进场 status；arbiter/holder/accountId 不变。
   - guest（栈中非 holder）：仅换端口，不 apply、不动 Timer。
   - suspended：换端口、不 apply、suspended 标记仍在。
   - 不在栈：no-op。
   - rehome 后 claim 短路 + `_pendingApplyReplay` 补放一次；补放成功后不再补。
   - applyReentered 抛错：rehome 不抛、Timer 已重挂。
   - release/batch 后 _lastEnterStatus 清除。
3. **MainPresenceService**：
   - prepare 超时（fakeAsync 10s）completeError 且条目清理。
   - register 命中 handoff（主→子）：索引改挂、新 RemoteTab guard 三元组来自旧端口（currentGuardArgsFor）、rehome 被调用、completer 完成。
   - register 命中 handoff（子→子）：旧 RemoteTab markClosed、新 tab guard 复制自旧 tab。
   - rehomeLocal（子→主）：索引与 _remoteTabs 摘除、gateway.rehome 调用。
   - 旧窗迟到 release/batch/guard：幂等/no-op/not_holder（既有测试补迁移后场景）。
   - handoff 中源窗/目标窗死亡：失败结算。
4. **WindowRegistry**：addChildTab 合并不覆盖、remove、move、空 set 保留、reconcile 联动、ordinal。
5. **WindowOpenService**（fake port/fake store/fake mps）：六向成功时序断言（prepare 先于落标签、关源晚于 handoff 完成、registry 挪动正确、new 窗 args 含 tabId）；create 失败、invoke 失败、handoff 超时三回滚；非抖音 handoff=null 路径；listMoveTargets 排除与编号。
6. **TabStore/控制器**：open 带外部 tabId；closeForMove 后 onClose 不调 client.release（fake client 计数）但其余 onClose 清理执行；普通 close 行为不变。
7. **RoomTabArg/WindowArgs**：tabId 序列化往返与旧 JSON 兼容（缺字段 null）。
8. **子端**：SubWindowControlService 的 requestMove 编解码/失败回执；handleCall 两方法（open 带 tabId+activate、close 走 closeForMove）；requestWindowList 解析。
9. **TabStrip widget**：Windows 主窗菜单项（账号态可点「移到新窗口」、有子窗时出现级联）；子窗服务存在时菜单走 controlService；非 Windows/服务缺失零菜单项（既有断言不回归）。
10. **app_pages 路由闭包**：pr_/mw_/其他三向委托（可把闭包提为可单测的顶层函数）。

终态：全量 `flutter test` 绿（280 起，只增不减）；`flutter analyze` 恒 22 条（2 warning+20 info）零新增；接线任务 `flutter build windows --debug` 通过。

## 10. GUI 手工验收清单（用户本机执行，执行者不得声称已过）

1. 主窗游客标签「移到新窗口」：新窗播放、主窗标签消失、新窗标签 id 不变（标题/状态连续）。
2. 主窗**账号态**抖音标签「移到新窗口」：迁移瞬间弹幕不中断重连、无重复进场（看主端日志无 enterRoom/exitRoom，心跳拍连续）、新窗为账号态（可点赞成功）。
3. 子窗账号态标签右键「移到其他窗口 → 主窗口」：主窗标签账号态、弹幕在主窗重连一次（apply 复刻）、源子窗标签消失；子窗若为最后标签则窗口自动关闭。
4. 子窗标签移到另一个已存在子窗：目标窗新增标签并置前，源窗摘除。
5. 主窗两个标签、两个子窗各一个：级联菜单窗口编号与排除自身正确。
6. 迁移后在新窗发弹幕/点赞成功（guard_send 经新 windowId）。
7. 迁移后心跳持续：放置 >40s，日志中心跳拍不断、无 suspended。
8. 故意制造失败（如关窗时机）：toast 文案、源标签仍在且仍播放。
9. 非抖音（bili 等）标签三个方向迁移正常播放。
10. 主窗关闭联动、批量关标签等既有 presence 行为无回归。

## 11. Ruling 与结转

- **Ruling（pr_detach 处置）**：M4-3 铺好的 pr_detach/gateway.detach/arbiter.detach 在方案 A 下没有生产调用点；协议、实现、既有单测全部保留不删。无缝 handoff 语义取代了「detach + 同 tabId 重新 claim」的原定接线；detach 作为「允许服务端会话终止的跨窗移动」备选能力留存。
- 子端 IPC presence client 的 windowId 缓存：迁移后是全新控制器/全新 client（onInit 按本窗 windowId 构造），不存在旧缓存问题；M4-3 ledger 结转的「重评 RemotePresenceTab 缓存 windowId」结论为：旧 tab markClosed 后不再被任何路径引用，guard 复制到新 tab，无需可变 windowId。
- 「先 detach 再 register/claim」的前置断言（M4-3 spec §12）被本设计取代：断言改为「handoff 期间栈不动、关源晚于 rehome、源 closeForMove 抑制 leave」，由 §9 测试固化。
- M5/M6 结转不变（子窗弹幕 UI/IME、bili/huya/douyu/twitch 写动作、非抖音→抖音切房 client 动态重绑；e2e、两 flake、N3 迟到 apply 另案）。

## 12. 文件清单（计划任务划分依据）

新增：

- `lib/app/multiwindow/window/window_control_protocol.dart`
- `lib/app/multiwindow/window/sub_window_control_port.dart`
- `lib/app/multiwindow/window/sub_window_control_service.dart`
- 对应测试文件（test/multiwindow/...）

修改：

- `presence/douyin_presence_gateway.dart`（_lastEnterStatus、rehome、isTrackedTab、currentGuardArgsFor、_pendingApplyReplay、claim 短路补放）
- `presence/presence_claimant.dart`（applyReentered 接口）
- `presence/ipc/remote_presence_tab.dart`（applyReentered）
- `presence/ipc/main_presence_service.dart`（handoff 表、register 改造、rehomeLocal、死亡清理）
- `window/window_open_service.dart`（编排、handleWindowCall、listMoveTargets、presenceService 后绑、删旧 moveTabToNewWindow）
- `window/window_registry.dart`（add/remove/move/order）
- `window/window_args.dart`（RoomTabArg.tabId）
- `shell/tab_store.dart`（open 外部 tabId、closeForMove）
- `shell/room_controller_registry.dart`（controllerForTabId 已存在，无需改签名；getx 实现已支持）
- `modules/live_room/live_room_controller.dart`（_movedAway、applyReentered 适配器）
- `shell/tab_strip.dart`（菜单）
- `bootstrap/sub_engine_bootstrap.dart`（control service、mw_ case、tabId 透传）
- `routes/app_pages.dart`（路由闭包、MPS 后绑 WOS）
