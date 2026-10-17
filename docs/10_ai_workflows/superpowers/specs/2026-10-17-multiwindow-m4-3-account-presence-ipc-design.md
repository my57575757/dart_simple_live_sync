# M4-3 账号面 Presence IPC 设计（多窗口）

> 状态：设计待审（brainstorming architectural 路径产物）
> 日期：2026-10-17
> 前置：M2（多窗口多标签）、M3（抖音 presence 网关）、M4-1（子引擎游客态）、M4-2（数据面 IPC 写穿）均已发布（1.12.60）。
> 配套：M4-2 终审遗留的数据面 Minor 5 条拆为独立小 spec，先于本计划执行，见
> `2026-10-17-multiwindow-m4-2-dataplane-minors-design.md`。

## 1. 目标

子窗口（子引擎）内的抖音直播间标签，以**借用主窗口抖音登录身份**的方式参与
M3 的账号在场仲裁：

1. 全进程仍只有一个 presence 仲裁器与一个心跳 Timer，位于主引擎；子引擎
   抖音标签以"远端标签"身份与主引擎本地标签同栈仲裁（claim/yield/fallback/
   suspended 语义与 M3 完全一致）。
2. 子窗内可显式"进入直播间"（账号进场）、可点赞/粉丝团灯牌/入团/点亮
   （guard 写动作）；账号态 HTTP（详情、ensureAccount、enterRoom、心跳、
   exitRoom、reregister、sendDanmaku、sendAction）全部在主引擎执行。
3. 子窗**不提供登录入口、不持久化任何凭据**；登录 cookie 仅在账号在场期间
   以内存方式下行一次，子引擎自取账号详情、自连账号弹幕，退出/让位/挂起即清。
4. 收口 M3 计划"开工前记账"第 2–8 条网关健壮性问题（第 1 条接口抽出是
   本计划的前置改造，一并完成）。
5. 子窗账号登录/设置/WebDAV 等深路由做防御性收口（M4-2 FW-2）。

## 2. 非目标（明确边界）

- **不恢复子窗弹幕发送 UI**：底部栏保持 M4-1 的置灰态，子窗全屏回车不弹
  输入框。弹幕发送通道（协议 + 串行域 + 单测）本计划铺好，UI 与
  NativeEditHost 多窗宿主留 M5。
- **不做 bili/huya/douyu/twitch 的子窗写动作**：子窗 guard 未配置，
  这些平台维持现状（B 站点赞等入口在子窗隐藏/失败提示），M5 处理。
- 不做主窗换号/重新登录的主动广播：主窗登出后靠子标签下一拍心跳失败转
  suspended 自然收敛（§6.3）；主窗在线换号属稀有场景，靠后续写动作
  重新 claim 收敛，不发广播。
- 不接 detach 生产调用点（跨窗拖拽 M4-4）；协议保留 `pr_detach` 并单测，
  对齐 M3"detach 就绪但无生产调用"的立场。
- 不改 Android / TV / 首页路由模式任何行为；无 tabId 路径（Android、
  Get.toNamed 独立房间页）一行不动。
- 不做真实 dmw 双引擎自动化测试（与 M3/M4-2 同策略），交 GUI 清单。
- 不含 M4-2 数据面 Minor（独立小计划）。

## 3. 现状接缝（M3/M4-1/M4-2 产物）

- M3：`PresenceArbiter`（纯状态机）、`DouyinPresenceGateway`（唯一心跳
  Timer、`_serialized` 串行链、claim/release/detach/batchRelease、404
  重注册、suspended）、`DouyinPresenceTab` 端口（控制器内
  `_ControllerPresenceTab` 适配器实现）、`LocalPresenceClient` 薄代理。
  网关仅主引擎 kShell binding 实例化（app_pages.dart），子引擎不注册。
- M4-1：子引擎 bootstrap（`sub_engine_bootstrap.dart`）装配精简服务集，
  `DouyinAccountService` 空 cookie、`GuardServerService` configured=false，
  子窗固定游客态；`MultiWindowRole.isSubWindow` 全局标记。
- M4-2：dmw 单通道自定义方法名模式（`dp_` 前缀、JSON 兼容载荷、
  纯 Dart 假端口测试）；主窗 method handler 由 `MainDataPlaneService`
  `onInit` 经 `mainController.setWindowMethodHandler` 注册；
  `WindowRegistry` + `windowsChanged` 对账；`RoomControllerRegistry`
  tabId→控制器；`TabStore` 批量关闭先 `presenceGateway.batchRelease`
  再销毁控制器。
- 已核实的 dmw 0.3.1（补丁版）事实：
  - `windowId` 为 **String**；
  - 每个引擎每个 channel 只有**单 handler 槽位**，重复 set 是覆盖语义
    （`window_channel.dart` `_registeredHandlers` 更新而非多播），因此
    presence **不得**再 set 主窗 handler，必须经既有 handler 委托；
  - 主端 handler 收到的 `MethodCall` **不含来源 windowId**，子端每个
    载荷必须自带 `windowId` 字段；
  - 同引擎 handler 调用在同一 task runner FIFO（M4-2 已依赖此序）。

## 4. 架构（方案 A：唯一仲裁器在主引擎，远端标签混栈）

```
子引擎 H1/H2                                 主引擎
─────────────                                ───────────────────────────────
LiveRoomController(douyin, tabId uuid)
  └─ PresenceClient(per-tab proxy)
       IpcPresenceCoordinator(每窗一个)      MainPresenceService(GetxService)
         pr_register ───────────────────────►   tabId→windowId 索引
         pr_claim(含 guard 参数) ───────────►   RemotePresenceTab(impl
         pr_release/pr_batch_release           DouyinPresenceTab)
         pr_detach                            DouyinPresenceGateway(唯一)
         pr_guard_send ─────────────────────►   混栈仲裁 + 唯一心跳 Timer
                                               全部账号 HTTP
         pr_apply_enter{cookie,status}  ◄──X    RemotePresenceTab.apply*
         pr_apply_yield                 ◄──X     经 SubWindowPort.invoke
         pr_apply_suspended             ◄──X
```

- uuid tabId 全局唯一（TabStore v4），远端标签直接以原 tabId 入栈，
  无需复合 id。
- 进房序列在主端完整执行（M3 `_performEnter` 不变）：
  `RemotePresenceTab.fetchAccountDetail` 在**主端**用主窗 DouyinSite +
  载荷里的 roomId/shareUrl 取账号详情（兼作 detail_failed 判定），随后
  ensureAccount→enterRoom。成功后 apply 阶段**不下发详情对象**
  （`LiveRoomDetail.danmakuData` 是 dynamic，跨引擎 JSON 往返不对称），
  只下发 `{cookie, guardStatus, reentered}`；子端收到后把 cookie 写入
  内存单点，**自己重取一次账号详情**再连账号弹幕——与 M3
  `applyYieldToGuest` 自己重取游客详情对称。代价是每次 claim 多一次
  子端 HTTP；claim 低频（用户显式动作），接受。
- 主窗本地标签链路保持 M3 直调；`LocalPresenceClient` 与子端 per-tab
  proxy 实现同一 `PresenceClient` 接口，控制器只持有接口类型。

## 5. IPC 协议

新文件 `lib/app/multiwindow/presence/ipc/presence_protocol.dart`，
形态对齐 `DataPlaneProtocol`（私有构造、常量方法名、显式 encode/decode、
非法载荷返回 null/false）。方法名一律 `pr_` 前缀，与 `dp_` 物理隔离：
dp_ 流量经 `MainDataPlaneService`，pr_ 流量经其默认分支委托给
`MainPresenceService.handleCall`（§9 接线），两个服务互不解析对方方法。

载荷全部 JSON 兼容（Map/List/num/String/bool/null）；`guardExtra`
抖音固定为 `{}`，字段保留。

### 5.1 子 → 主

| 方法 | 载荷 | 响应 |
|---|---|---|
| `pr_register` | `{windowId, tabId, siteId, roomId, shareUrl}` | `true`/`false`（非抖音/坏载荷） |
| `pr_claim` | `{windowId, tabId, roomId, shareUrl, guardRoomId, guardWebRid, guardExtra}` | `{ok:true}` 或 `{ok:false, reason}` |
| `pr_release` | `{windowId, tabId}` | `true`（未知 tab 幂等） |
| `pr_detach` | 同 pr_release | `true`（M4-4 接线，本计划无生产调用） |
| `pr_batch_release` | `{windowId, tabIds:[...]}` | `true` |
| `pr_guard_send` | `{windowId, tabId, kind, content?}`，kind=`danmaku`\|`action`；danmaku 带 `content`，action 带 `action` | `{success, code?, message?}`；非 holder 返回 `{success:false, code:'not_holder'}` |

- `pr_register` 在子端控制器 onInit 绑定时发出（bootstrap handler
  先就位、store.open 在后，时序已具备）。它**只建死亡对账索引**，
  不建 RemotePresenceTab、不碰仲裁栈。
- guard 参数随**每次 pr_claim 上报**（register 时子端还没有游客详情、
  算不出 guard 参数）；主端在首次 claim 时 `bindTab` 并缓存参数。
  因此：进过栈的远端 tab 必有 guard 参数，fallback 选到它即可直接
  重新 enter，闭环。
- reason 取值与子端文案映射：

| reason | 含义 | 子端 toast 文案（逐字） |
|---|---|---|
| `not_logged_in` | 主窗抖音未登录（无 sessionid） | 主窗口未登录抖音，请先在主窗口登录 |
| `not_configured` | 主窗 guard 未配置 | 主窗口未配置弹幕签名服务，请在主窗口完成配置 |
| `detail_failed` | 账号详情读取失败（被主播限制等） | 无法以账号身份读取该房间（可能被主播限制） |
| `enter_failed` | ensureAccount/enterRoom/重注册失败 | 进入直播间失败，已保持游客观看 |

| 子端本地结果 | 文案（逐字） |
|---|---|
| `ipc_failed`（invoke 抛错/主窗无响应） | 主窗口服务无响应，请重试 |

主窗本地链路保留现有两条文案（"无法以账号身份读取该房间（可能被主播限制）"、
"进入直播间失败，已保持游客观看"）；not_logged_in/not_configured 在主窗
被 onInit 后的登录态门拦截，正常不可达。

### 5.2 主 → 子（主端向该 tabId 所属 windowId 单向 invoke）

| 方法 | 载荷 |
|---|---|
| `pr_apply_enter` | `{tabId, cookie, status, reentered}` |
| `pr_apply_yield` | `{tabId}` |
| `pr_apply_suspended` | `{tabId}` |

- `cookie` 是主窗 `DouyinAccountService.loginCookie` 在**发送当刻**读取
  （claim 在途期间主窗可能换号，以 apply 当刻为准）。
- `status` 为 guard enterRoom 返回的 Map（JSON 兼容）。
- 子端 bootstrap 总 handler 增三个 case，全部转交
  `IpcPresenceCoordinator.handleCall`；查不到 tabId 对应控制器时
  静默返回（控制器已销毁，窗口死亡对账随后收口）。

## 6. 关键语义

### 6.1 混栈仲裁与子端三 apply

- 主端 `RemotePresenceTab`（新文件，主侧）implements `DouyinPresenceTab`：
  - `tabId`=子端 uuid；`isClosed`=本地 closed 标志（release/batch/
    窗口死亡对账时置位；apply invoke 失败**不**置位——硬死亡由
    windowsChanged 对账兜底，单次通道失败不代表窗口死亡）；
  - `fetchAccountDetail()`：主端 DouyinSite
    `getRoomDetail(roomId: "$roomId;$shareUrl", asAccount:true)`；
  - `guardRoomId/guardWebRid/guardExtraArgs`：claim 载荷缓存值；
  - `applyAccountEnter(...)`：`port.invoke(windowId, pr_apply_enter,
    {tabId, cookie: 主端当刻读取, status, reentered})`；
  - `applyYieldToGuest/applySuspended`：对应 invoke（best-effort，
    异常只记日志，与 M3 同）。
- 子端三 apply（`IpcPresenceCoordinator` → 经 registry 找到控制器）：
  - enter：`DouyinAccountService.setBorrowedLoginCookie(cookie)`（内存
    单点，§6.2）→ `controller.fetchAccountDetail()` 自取账号详情 →
    `controller.applyAccountEnter(accountDetail: 自取, guardStatus:
    下发, reentered: 下发)`。自取失败：不向主端抛错（invoke 正常
    返回；主端 M3 语义本就吞 apply 异常），子端保留游客弹幕、
    presence 由 claim 应答的 granted 分支乐观置 account（与主窗
    L485-489 同策略），下次写动作/重进时自愈。
  - yield：先清借用 cookie，再调 `controller.applyYieldToGuest()`
    （内部自换游客详情/弹幕，M3 既有逻辑）。
  - suspended：先清借用 cookie，再调 `controller.applySuspended()`。

### 6.2 借用 cookie 安全细则

1. cookie 只出现在 `pr_apply_enter` 载荷；其余 pr_ 方法一律不带。
2. 子端唯一内存写入点：`DouyinAccountService.setBorrowedLoginCookie(String?)`
   （新方法）——只写 `loginCookie` 字段与 `site.loginCookie`；**不写 KV、
   不翻转 logined/loginName/hasCookie、不触发 guard 注册**。
3. 三个失效点立即置 null：收到 pr_apply_yield、收到 pr_apply_suspended、
   coordinator onClose（子窗关闭）。重开子窗从零开始（游客）。
4. 日志：主/子服务任何日志不得直接打印 apply 载荷；协议提供
   `PresenceProtocol.sanitizeForLog(method, args)`（cookie 替换为
   `<cookie:${n}chars>`），单测钉死脱敏输出不含 `sessionid` 字样。
5. cookie 绝不进 dp_ 通道、不进开窗快照、不进 RemoteKvBox
   （`DouyinLoginCookie` 已在 DataPlaneProtocol.sensitiveKeys）；
   子端核心弹幕 args 会在进程内存中携带它（douyin_danmaku 既有机制），
   随弹幕 stop / 进程退出消失，与第 3 条同生命周期。

### 6.3 时序边界

- **claim 在途时 release**：沿用 M3 串行链；子端 release IPC 到主端后
  在 `_serialized` 排队到进场完成后执行，isClosed 分支跳过 apply/心跳，
  release 发 exit 并触发幸存者接管。
- **子窗进程被杀（无临终消息）**：windowsChanged 对账（§6.4）→
  `batchRelease(该窗全部 tabId)`，整批至多一次 exit、一次幸存者接管。
- **主窗关闭**：既有 `requestCloseAllChildren` 尽力联动；同归于尽时
  服务端租约超时自然清场，与 M3 主窗被杀行为一致（不新增保证）。
- **主窗登出/guard 删号**：下一拍心跳 404 → reregister 失败。M3 现状
  是只记日志且 Timer 空转；本计划改为：**reregister 失败按 suspended
  处理**（cancel Timer、移出 _ready、arbiter.markSuspended、
  tab.applySuspended）。远端 tab 因此收到 pr_apply_suspended 并清 cookie；
  主窗本地标签同样受益于此修复。
- **同房双标签混栈**：主窗本地标签与子窗标签可互为 holder/fallback，
  规则与 M3 两本地标签完全相同（后进栈者持有，关闭按栈尾回退）。
- **not_holder 写动作**：见 §6.5。

### 6.4 窗口死亡对账

- `WindowRegistry.reconcile` 签名改为返回 `Set<String> removedWindowIds`
  （摘除集，而不是静默 removeWhere）；`WindowOpenService` 在
  windowsChanged 监听里取返回集，推入新增的广播流
  `Stream<Set<String>> get onChildWindowsClosed`（broadcast）。
- `MainPresenceService.onInit` 订阅：汇总已死 windowId 下登记的全部
  tabId → `gateway.batchRelease(集合)` → 清自身索引。正常关窗时各
  控制器的 pr_release 先到，对账时集合为空/均未知 tab，幂等无 HTTP。

### 6.5 guard 写动作进入同一串行域（M3 记账 #2）

- 网关新增 `sendDanmakuAsHolder({required tabId, content})` 与
  `sendActionAsHolder({required tabId, action})`，均经 `_serialized`：
  1. tab 不存在 / `arbiter.holder != tabId` / 不在 `_ready` →
     返回 code `not_holder`，不发 HTTP；
  2. accountId 取 `_accountIds[tabId]`，空则 code `not_login`；
  3. 调 `guard.sendDanmaku/sendAction`（roomId/webRid/extra 取该 tab
     缓存参数）；404 → reregister 重试一次（沿用控制器现策略）；
  4. 返回 `PresenceSendResult{success, code, message}`，映射
     guard 的 success/platformCode/message。
- 控制器抖音发送路径（sendDanmaku 的 guard 分支、_sendGuardAction）
  在 `_presenceClient != null` 时改走 `client.sendDanmaku/sendAction`，
  不再直连 GuardServerService、不再本地起心跳。这样主窗本地标签与
  子窗标签共用同一串行域，消除"发送瞬间 holder 切换打到后一房间"。
- 子端 per-tab proxy 对应发 `pr_guard_send`。
- 控制器收到 `not_holder`：自动重新 `ensureAccountPresence()`（claim
  重进）并重发**一次**；再失败 toast「登录状态已切换，请重试」。
  其余 code 沿用 `danmakuErrorText` / action 既有 message 提示。
- bili/huya 的控制器发送路径不改。

### 6.6 子窗登录入口收口

控制器/UI 层（子窗抖音）：

1. `showDanmakuInputDialog` 与全屏键盘 `handleKeyboardKey` 回车分支
   首行：`Platform.isWindows && MultiWindowRole.isSubWindow` →
   toast「请在主窗口发送弹幕」并返回（M5 随 UI 恢复一起移除）。
2. `showDanmakuLoginDialog` 子窗分支：只弹提示框（文案
   「子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务」，
   单确认键），**不导航** kSettingsAccount。
3. `enterAsAccount`：子窗抖音跳过本地 `danmakuLogined` 门（本地恒
   未登录），直接 claim，失败原因由 §5.1 reason 文案承接。
4. `guardActionEnabled`：子窗抖音恒可见（点赞/灯牌/入团/点亮行），
   即 getter 末尾析取
   `|| (Platform.isWindows && MultiWindowRole.isSubWindow &&
   site.id == Constant.kDouyin)`；失败文案经 claim/guard_send 回执。
5. 路由防御（M4-2 FW-2，纵深防御，不依赖入口 1-4）：新增
   `SubWindowBlockedPage` 包装 widget，子窗模式渲染
   Scaffold（AppBar 返回 + 居中「该功能仅可在主窗口使用」），主窗
   模式透传子页。app_pages.dart 包装 4 条路由的 page builder：
   `kSettingsAccount`、`kWebLogin`、`kSettingsOther`、
   `kRemoteSyncWebDav`。

## 7. M3 网关健壮性收口（记账 #1–#8）

出处：M3 计划末尾"M4 开工前记账"。#1 为结构改造，#2 见 §6.5，
#3–#8 如下：

1. **抽 PresenceClient 接口**（本计划 Task 1）：新文件
   `presence_client.dart`：`PresenceClient{claim, release, detach,
   isClaimed, sendDanmaku, sendAction}`、`PresenceClaimResult`
   （granted + failure reason 枚举；从 presence_claimant.dart 迁出，
   更新 M3 既有 import 与构造点）、`PresenceSendResult`。
   `LocalPresenceClient implements PresenceClient`；控制器
   `_presenceClient` 字段与 `_leaveDouyinPresence` 只依赖接口
   （消除 `_resolveGateway`/`hasClaim` 具体类耦合，isClaimed 承接
   inStack 判定）。
2. 写动作串行域 —— §6.5。
3. **dispose 生命周期**：`DouyinPresenceGateway` 改为 extends
   `GetxService`，onClose 取消心跳 Timer（替换手工 dispose；
   `stopHeartbeatForTesting` 保留）。
4. **detach 唯一持有者早退 Timer 残留**：`_remove` 中 wasHolder 快照后
   立即 cancel Timer（早于 exits/enters 空转移的 early return），
   修掉"detach 唯一持有者无 fallback 时 periodic Timer 永久残留"。
5. **beat 非重入**：加 `_beatInFlight` 标志，heartbeat RTT 超 20s 时
   重叠拍直接跳过；顺带删除 `retried` 形参（404 重注册路径不再需要
   它，重注册失败的 suspended 收口在重入函数内自洽）。
6. **_exitRoom 守卫**：`_exitRoom` 起手补
   `canStartDanmaku` 等价条件（抖音 args.roomId 为空的 SSR 骨架房
   不发 exit）——以 `tab.guardRoomId.isEmpty` 判定（远端/本地端口
   同构）。
7. **在途进房的新 holder 被单关时不再 yield 旧 holder**：claim 让位
   分支条件由 `!previousHolder.isClosed` 加强为
   `!tab.isClosed && !previousHolder.isClosed`；新 holder 已关时让位
   由紧随排队的 release → fallback 重新 enter 一次性完成，省掉一次
   游客 getRoomDetail 与短暂 guest 弹幕/双 sysMsg。
8. **批量菜单防抖**：TabStore 加 `_batchClosing` 标志，
   closeOthers/closeRight/closeAll 在已有批量流程在途时直接 return
   （终态幂等），杜绝快速两次批量操作的"刚 enter 即 exit"抖动。

另：心跳 reregister 失败转 suspended（§6.3）不在原记账列表，是本
计划新明确的行为，主/远端子端同源受益。

## 8. 安全

- 凭据流单向：主窗 KV → 内存 → 单次 pr_apply_enter → 子端内存；
  子端无 KV 写入路径（RemoteKvBox 敏感键守卫 M4-2 已在），进程退出
  即清零。敏感键 17 具名 + GuardAccountId_ 前缀清单不变。
- pr_ 与 dp_ 双通道前缀隔离；数据面服务不解析 pr_、账号面服务不解析
  dp_；唯一交点是主窗 handler 默认分支的一行委托。
- 主端对所有子端入参做类型/枚举校验（协议 decode 层），非法载荷
  false/异常结果，不入仲裁栈、不发 HTTP。
- 子端 guard configured 恒 false 的既有事实不变：任何绕过 coordinator
  直连 GuardServerService 的路径在子端都无配置可用。
- 不新增任何网络出口；guard/抖音请求均由主端既有服务发出。

## 9. 文件结构

新增（均在 simple_live_app/lib/）：

| 文件 | 职责 |
|---|---|
| `app/multiwindow/presence/presence_client.dart` | PresenceClient 接口、PresenceClaimResult/Failure 枚举、PresenceSendResult |
| `app/multiwindow/presence/presence_batch_releaser.dart` | 单方法接口 `batchRelease(Set<String>)`，TabStore 依赖它而非具体网关 |
| `app/multiwindow/presence/ipc/presence_protocol.dart` | pr_ 常量、encode/decode、reason 码、sanitizeForLog |
| `app/multiwindow/presence/ipc/sub_presence_port.dart` | 抽象端口 + DmwSubPresencePort（invokeMain，对齐 SubDataPlanePort） |
| `app/multiwindow/presence/ipc/remote_presence_tab.dart` | 主侧 DouyinPresenceTab 远端实现（§6.1） |
| `app/multiwindow/presence/ipc/main_presence_service.dart` | 主侧 GetxService：6 个入站 handler（register/claim/release/detach/batch/send；detach 本期无生产调用）、tabId→windowId 索引、死亡订阅、pr_guard_send 执行 |
| `app/multiwindow/presence/ipc/ipc_presence_coordinator.dart` | 子侧每窗协调者：出站 IPC、per-tab PresenceClient 工厂、三 apply 回调、batchRelease |
| `app/multiwindow/shell/sub_window_blocked_page.dart` | 子窗深路由防御包装 |

修改：

| 文件 | 改动概要 |
|---|---|
| `presence/local_presence_client.dart` | implements PresenceClient；isClaimed；sendDanmaku/sendAction 委托网关新方法 |
| `presence/presence_claimant.dart` | PresenceClaimResult 迁出（文件保留 DouyinPresenceTab 端口） |
| `presence/douyin_presence_gateway.dart` | GetxService；登录态判定端口注入；_performEnter 细分 reason；send*AsHolder；#4–#8；reregister 失败 suspended；implements PresenceBatchReleaser |
| `window/window_registry.dart` | reconcile 返回移除集合（+测试更新） |
| `window/window_open_service.dart` | onChildWindowsClosed 广播流 |
| `data/main_data_plane_service.dart` | 构造参数 `unhandledMethodHandler`；handleCall 默认分支委托（dp_ 行为零变化） |
| `services/douyin_account_service.dart` | setBorrowedLoginCookie（内存单点） |
| `modules/live_room/live_room_controller.dart` | 接口换型；子窗装配 coordinator proxy；抖音发送/action 改道；not_holder 一次重试；输入/登录弹框首行守卫与文案；enterAsAccount 子窗跳过登录门；guardActionEnabled 析取 |
| `multiwindow/shell/room_controller_registry.dart` + getx 实现 | 增 `controllerForTabId(tabId)` |
| `multiwindow/shell/tab_store.dart` | presenceGateway 字段换型 PresenceBatchReleaser；#8 _batchClosing |
| `multiwindow/bootstrap/sub_engine_bootstrap.dart` | 装配 coordinator（mainWindowId 非空时）、pr_register 时序、handler 三 case、TabStore 注入 releaser |
| `routes/app_pages.dart` | kShell 守卫块注册 MainPresenceService 并向 MainDataPlaneService 传委托；4 路由包 SubWindowBlockedPage |

Android/TV：零改动文件。

## 10. 测试策略（全部假端口纯 Dart/Flutter test，无真实 dmw）

沿用 M3/M4-2 fake 模式，预计新增 30–36 例：

1. **协议（约 6）**：每方法 encode/decode 往返；坏载荷（缺字段/错类型/
   坏 kind/坏 box 无关）拒绝；reason 五值；sanitizeForLog 不含
   sessionid/cookie 原文。
2. **网关混栈（约 8）**：本地假 tab + RemotePresenceTab 假实现混栈：
   远端 claim 成功触发 apply invoke 且载荷 cookie 为当刻值；远端让位
   给本地/本地让位给远端；关闭远端持有者本地幸存者 reentered 接管；
   claim 在途 release 排队；窗口死亡 batchRelease 至多一次 exit；
   首次 claim 才 bindTab（仅 register 不进栈）。
3. **写动作串行域（约 3）**：holder 成功 + 404 重试；非 holder/not_ready
   返回 not_holder 零 HTTP；accountId 缺失 not_login。
4. **健壮性修复（约 5）**：#4 detach 后无 Timer（fakeAsync 无残留拍）；
   #5 beat 重叠跳过；#6 空 roomId 不发 exit；#7 新 holder 在途关闭不
   yield 旧 holder；#8 _batchClosing 二调 no-op；reregister 失败转
   suspended 且 applySuspended 被调。
5. **MainPresenceService handler（约 4）**：register/claim/release/
   batch/send 的索引与转发；死亡流 → batchRelease；非法载荷 false；
   未知 release 幂等。
6. **子端 coordinator（约 5）**：apply_enter 写 cookie→自取→apply 顺序，
   且 logined 不翻转；yield/suspended 清 cookie；控制器查不到时静默；
   自取失败不抛回主端；claim IPC 异常映射 ipc_failed；per-tab proxy
   载荷字段正确。
7. **控制器（约 3）**：子窗首行守卫（toast 文案、不导航）；抖音发送
   经 fake PresenceClient 且不直连 guard；not_holder 重试一次。
8. **路由包装（1 widget test）**：isSubWindow 置位时
   SubWindowBlockedPage 显示拦截文案，复位时透传（teardown 复位全局
   标记）。
9. **WindowRegistry（1）**：reconcile 返回值恰为被摘除窗口集。

门禁（每任务/合并前）：`flutter analyze` 零新增告警、全量
`flutter test` 绿（当前基线 227）、`flutter build windows --debug`
成功；Android 路径零变化靠静态核验（注册点/getPages 守卫条件 grep
闭包）。Flutter 固定 `C:/tools/flutter347/flutter/bin/flutter.bat`。

## 11. GUI 手工验收（Windows，合并到 my_dev 后用户本机执行）

执行者不得声称 GUI 已过。清单：

1. M2–M4-2 回归抽验：多窗多标签开关、设置/屏蔽词/关注/历史/音量同步。
2. 子窗开抖音直播间（游客）→点"进入直播间"：账号弹幕连上、提示
   "已进入直播间"；主窗同账号心跳只此一份（日志/guard 侧观察）。
3. 子窗点赞：guard 生效（主播侧/返回 success），灯牌/入团/点亮同理
   各一次。主窗本地标签抖音弹幕发送/点赞走同一串行域，需无回归。
4. 两子窗同房先后进入：后者持有、前者收到让位 sysMsg 并回游客弹幕；
   关后者，前者自动恢复（reentered 文案）。
5. claim 后直接关子窗标签：主窗幸存者接管，无多余 exit/enter 抖动。
6. 任务管理器杀子窗进程：主窗幸存者一次接管恢复。
7. 未登录 / 未配置 guard 两种主窗状态下子窗进入：文案分别为
   §5.1 对应文案；子窗全屏回车只 toast 不弹输入框。
8. 子窗深路由收口：任何可达路径到账号设置/Web 登录/其他设置/WebDAV
   均见拦截页（或无入口）。
9. 子窗账号态关闭后重开：游客起步（cookie 未持久化）；主窗登出后
   下一拍子窗转 suspended、弹幕回游客、sysMsg。
10. 主窗本地标签与子窗标签互相让位双向各一次；批量关闭（其他/右侧/
    全部）至多一次 exit、一次接管。
11. Android 安装包零行为变化留真机回归（发版门禁统一提醒）。

## 12. 风险与记账

- **主端详情二次取数**：每次远端 claim 主端取一次（detail_failed 门）
  子端 apply 再取一次（弹幕 args），两次 HTTP。claim 低频可接受；
  若日后 claim 高频化，优化点是协议化 args 而非提前做。
- **dmw 单 handler 槽位**：已核实为覆盖语义，接线必须委托不许重挂；
  计划评审对此行做专门核验。
- **cookie 在子端内存暴露**：与主窗同进程（desktop_multi_window
  单进程多引擎），不新增跨进程面；不落盘、日志脱敏、三失效点清零。
- **IP 风控**：账号弹幕连接从子引擎发起（IP 不变，同机）；心跳/进场
  仍由主端 guard 浏览器页承载，服务端只感知一个浏览器页会话。
- **M4-4 接缝**：pr_detach 本计划只通协议与单测；跨窗拖拽时目标窗
  attach 后以同 tabId 重新 claim 的完整时序在 M4-3 测试中以双
  coordinator 假通道预留。
- 遗留 M5：恢复子窗弹幕输入与发送（NativeEditHost 多窗宿主/IME）、
  bili/huya/douyu/twitch 子窗写动作、其他平台子窗登录态策略。
- 遗留 M6：真实 GetX 注销序 e2e、suspended 触发日志；发版前
  Android 真机 6 项 + Windows GUI 累计清单（M3 9 + M4-1 11 +
  M4-2 9 + 本里程碑 11）。
