# SimpleLive 多窗口 / 多标签页设计

日期：2026-10-15
涉及仓库：`dart_simple_live`（simple_live_app）
平台范围：仅 Windows 桌面端增加多标签 / 多窗口；Android 维持现有整页路由跳转，行为零变化；iOS / macOS / Linux / TV 端不启用。

## 1. 背景与目标

当前 Windows 端一次只能观看一个直播间：点击房间卡片由 GetX 路由 `Get.toNamed(RoutePath.kLiveRoomDetail)` push 一个 `LiveRoomPage`，返回即退房。用户希望像浏览器一样同时打开多个直播间：

- 一个窗口内以标签页承载多个直播间，可切换、排序、关闭；
- 标签页可以拖出成为独立 OS 窗口，独立窗口自带标签栏、可以继续接收拖入或新开标签，也可以把标签拖回任意窗口合并；
- 所有标签（含后台标签）同时播放且都有声，各标签可独立静音；
- 抖音以登录态进入的直播间在多标签 / 多窗口下全应用只保留**最后打开**的一个登录心跳；持有心跳的标签关闭后，更早打开且仍有登录意图的标签自动回退接管。

本设计已在需求沟通中逐项确认，关键用户决策见第 3 节。

## 2. 总体方案

引入 [`desktop_multi_window`](https://pub.dev/packages/desktop_multi_window) 0.3.1（MixinNetwork，2026-08-26 发布，单进程多 Flutter 引擎，Dart SDK ≥3.5.0）：

- **单进程多引擎**：1 个主引擎（主窗口）+ 每个独立房间窗 1 个子引擎，引擎间用插件的 `WindowMethodChannel` IPC；
- **主引擎是唯一协调者**：Hive 唯一写者、抖音登录心跳全局仲裁者、窗口 / 标签注册表；
- **标签是引擎内概念**：每个窗口引擎内一个 `TabStore`，内容区用 `IndexedStack` 挂载多个 `LiveRoomPage`，后台标签保持 mounted 从而持续播放；
- **跨窗口移动标签 = 快照重建**（libmpv 播放句柄不能跨引擎迁移）：目标窗按快照新建房间控制器重新拉流，直播无进度概念，重载成本仅一次缓冲；
- **抖音账号态收口**：所有引擎的进房 / 心跳 / 退房 / 账号写动作经 IPC 收口到主引擎的 `DouyinPresenceGateway`，全应用只有一个心跳 Timer。

## 3. 已确认的需求决策

以下决策在设计评审中由用户逐项确认，实现与验收以此为准：

1. 功能仅 Windows；Android 保持现状。
2. 拖拽做到完整浏览器式：标签可拖出成独立窗口，也可拖回 / 拖到其他窗口合并。
3. 所有标签都播放、都有声；静音由用户在各标签控制条手动操作，不做"仅当前标签有声"的自动策略。
4. 最后打开的抖音账号标签关闭后，更早打开的账号标签**自动回退接管**心跳，无需用户重新点「进入直播间」。
5. 主窗口关闭 = 退出整个应用（联动关闭所有子窗）；V1 不做"关闭主窗后房间窗独立存活 / 子窗提升为主窗"。
6. 同一 `siteId + roomId` 在任意窗口已打开时，再点入口激活已有标签并前置，不重复开。
7. 拖出 / 拖回时目标窗重新拉流；聊天弹幕记录不迁移，新窗从最新弹幕开始。
8. 标签栏放在原生标题栏下方，V1 不做 Chrome 式无边框融合标题栏。
9. 拖出过程中不显示 OS 级拖拽虚影（不引入 OLE DoDragDrop），落点反馈靠目标窗标签栏插入竖线 / 内容区高亮。
10. 右键菜单提供「移到新窗口」作为手势之外的显式入口。
11. V1 默认所有后台标签全量渲染；探针实测 4 路压力不达标时，在计划中加入「后台标签仅音频」开关作为预案。
12. 被让位（yield）的抖音标签：播放不中断，自动降级为游客弹幕并发系统提示；不发 exitRoom。
13. 账号态 HTTP（含 guard 进房 / 心跳 / 退房、抖音账号视角取页）全部收口主引擎。
14. 设置 / 关注 / 历史等存储通过"后端可替换"方式支撑子引擎，业务调用点不改写。
15. 子窗内登录由主窗代办（主窗弹现有登录页，完成广播回子窗），登录流程只保留一处实现。
16. 设置页在子窗可用（写入经 IPC 写穿主窗落盘并广播）。

## 4. 窗口 / 引擎模型

### 4.1 窗口种类

两种窗口运行同一个根 Widget `RoomShellApp`（标签栏 + 内容区），仅启动参数不同：

| | 主窗口 | 房间子窗口 |
|---|---|---|
| 启动参数 | 无 | JSON：`{type:"room_shell", tabs:[...], snapshot:{...}}` |
| 初始化 | 完整 `initServices`（Hive + 全部服务，现状） | 精简引导：不初始化 Hive，设置用快照，不实例化写盘 / guard 服务 |
| 标签数为 0 时 | 内容区显示现有首页 `IndexedPage`（首页是"底页"，不是标签） | 显示空态页；最后一个标签关闭则窗口关闭（同 Chrome） |
| 标签栏 | 左侧固定「首页」入口 + 房间标签 | 只有房间标签，可继续接收拖入 / 新开 |
| 窗口标题 | 保持 "Simple Live" | 随当前激活标签的房间名更新 |

### 4.2 入口分发（main.dart）

```
WidgetsFlutterBinding → windowManager.ensureInitialized()
→ WindowController.fromCurrentEngine() → 解析 arguments
  ├─ 主窗：migrateData() + Hive.initFlutter() + initServices()（现有逻辑）
  │        → runApp(RoomShellApp(home: IndexedPage))
  └─ type=room_shell：runSubEngine(snapshot)（无 Hive 的精简引导）
                   → runApp(RoomShellApp(initialTabs: ...))
```

### 4.3 打开直播间的唯一收口点

`AppNavigator.toLiveRoomDetail`（现有 7 个调用点：首页卡片、关注、搜索 ×3、历史、工具箱解析，签名不变）：

- Android：维持 `Get.toNamed(RoutePath.kLiveRoomDetail)` 整页跳转；
- Windows：不再 push 路由，改为向**当前窗口**的 `TabStore.open(site, roomId, shareUrl)` 新增标签；新建前向主引擎注册表查询同 `siteId+roomId` 是否已存在于任意窗口，存在则把其所在窗口置前并激活该标签（不改变标签顺序，同浏览器行为），不新建。

### 4.4 标识

- `tabId`：uuid（项目已有 uuid 依赖），标签在窗口间移动时沿用同一个 id；
- 窗口标识：插件的 `windowId`（String）；
- "最后打开"顺序：以标签在窗口内的 attach 落地时间为准；跨窗移动会刷新该时间（移动后的标签成为最新）。

### 4.5 窗口关闭语义

- 子窗 `onWindowClose`（window_manager `setPreventClose(true)` 拦截）：对每个标签执行 close 收尾（退房 / 停心跳 / 释放播放器，见 6.4），全部 dispose 后再关闭窗口；
- 主窗关闭：拦截后若有任意播放中的标签，弹一次确认「关闭将同时退出 N 个直播间窗口」；确认后 IPC 通知所有子窗执行同样收尾，子窗全部销毁后主窗退出；
- 定时关闭到时（现有 autoExit）：多标签下改为关闭当前标签 / 当前窗口；最后一个窗口关闭才退出进程，不再直接 `exit(0)`。

## 5. TabShell 与标签 / 播放器生命周期

### 5.1 TabStore（每引擎一个 GetxController）

```dart
class TabDescriptor {
  final String tabId;
  final String siteId, roomId, shareUrl;
  final RxString title;      // 房间详情加载后更新，未加载显示 roomId
  final RxBool hasError;     // loadError 时标签红点
  // 拖入快照字段：quality, line, volume, danmakuOn, wantsPresence
}

class TabStore extends GetxController {
  final tabs = <TabDescriptor>[].obs;       // 有序，即标签顺序
  final activeTabId = RxnString();
  void open(Site site, String roomId, String shareUrl);
  void close(String tabId);
  void activate(String tabId);
  void reorder(int oldIndex, int newIndex);
  TabStateSnapshot detach(String tabId);    // 跨窗移出
  void attach(TabStateSnapshot snap, {int? index}); // 跨窗移入
}
```

标签栏 UI 用 `Obx` 订阅 `tabs / activeTabId`。

### 5.2 Controller 按 tabId 打 tag

现状 `LiveRoomPage extends GetView<LiveRoomController>` 依赖 `Get.find()` 单例，多房间冲突。改造：

- 打开标签：`Get.put(LiveRoomController(pSite:..., pRoomId:..., pShareUrl:...), tag: tabId)`；
- 关闭标签：`Get.delete<LiveRoomController>(tag: tabId)`，触发现有 `onClose`（退房、停心跳、停弹幕、停播放器、写历史）；
- `LiveRoomPage` 改为持有 `tabId`，内部统一 `Get.find<LiveRoomController>(tag: tabId)`；页面内所有弹层 / 子组件中的 `Get.find<LiveRoomController>()` 调用点同步带 tag（实现时 grep 收口）；
- Android 继续无 tag 单例；用一个 `RoomPageResolver`（按平台 / 是否多窗模式返回对应查找方式）封装，页面主体代码不重复。

### 5.3 后台标签都播放

- 内容区 `IndexedStack`：所有 `LiveRoomPage` 保持 mounted，libmpv Player、弹幕 WS、心跳 Timer 全部持续运行，切标签零等待；
- 各标签 Player 独立音量（现有 `player.setVolume` + 每房音量持久化天然支持），控制条静音只影响本标签；
- 新增独立的 `isActiveTab` 概念，**不**复用现有 `isBackground`（那是窗口最小化 / App 生命周期概念，会暂停播放与看门狗）：后台标签播放看门狗（`PlaybackWatchdog`）照常工作；
- 后台标签的弹幕 canvas 绘制在 offstage 继续，V1 不做节流。

资源代价：N 路直播 = N 个 libmpv 实例 + N 个渲染纹理。M0 探针实测同机 4 路硬解 CPU/GPU/内存；不达标则 V1.1 加设置项「后台标签仅音频」（后台标签卸载 `Video` widget、Player 不停，切回重新挂纹理）。

### 5.4 跨窗移动：快照重建

```
源窗 TabStore.detach(tabId) → 抓快照 → IPC tab:attach → 目标窗 TabStore.attach(snap) → 源窗 Get.delete(tag)
```

- 快照字段：siteId / roomId / shareUrl、当前清晰度、线路、音量、弹幕开关、关注状态、wantsPresence（是否曾以账号进入）；弹幕消息列表不迁移；
- 目标窗新建控制器重新拉流，弹幕从最新开始；
- detach 路径与 close 路径严格区分：
  - **close**（用户关标签 / 关窗）：现有完整逻辑——停心跳 + 发 guard `exitRoom` + 写历史 + 释放；
  - **detach**（窗口间移动）：停心跳 Timer，但**不发 exitRoom**（目标窗马上 enter 续租，避免账号瞬间真的离开房间），不写历史（由新窗关闭时统一写）；
- 移动后以同一 tabId 重新向心跳网关注册 / claim，落地时间刷新为最新（见第 7 节）。

## 6. 标签栏 UI 与拖出 / 拖回交互

### 6.1 标签栏

- 位于原生标题栏下方，高约 38px，仅 Windows；
- 主窗最左为固定「首页」底页入口；房间子窗无此入口；
- 标签内容：站点图标或首字 + 房间名 + 直播状态点 + 关闭 ×；
- 当前标签高亮；`loadError` 标签显示红点；
- `[+]`：主窗切回首页选房间；房间子窗通过 IPC 把主窗唤到前台显示首页（子窗 V1 不内置房间选择器）；
- 右键菜单：移到新窗口 / 关闭 / 关闭其他 / 关闭右侧 / 复制房间链接；中键单击 = 关闭。
- 房间列表卡片右键菜单（仅 Windows）：新标签页打开（后台、不切换激活）、新窗口打开（M4 启用，当前置灰）。

### 6.2 标签内排序与拖出：统一指针拖拽

不使用 `ReorderableListView`（其拖拽态难以中途升级为跨窗会话），标签栏自行用 `Listener` + FFI 实现一套手势状态机：

1. 水平拖动且光标始终在本窗标签栏内 → 标签重排，实时显示插入竖线；
2. 拖出本窗边界 → 进入跨窗拖拽会话，源标签显示半透明"摘出中"态；
3. 松手时按落点分流（6.3）。

鼠标与触摸走同一套指针事件。

### 6.3 跨窗拖拽会话（主引擎托管 + Win32 FFI）

Flutter 引擎在光标离开自己窗口后收不到稳定指针位置，因此新增零依赖 FFI 模块 `win32_window_hit.dart`（`dart:ffi` 调 user32）：`GetCursorPos`、`GetAsyncKeyState(VK_LBUTTON)`、`EnumWindows` + `GetWindowThreadProcessId`（只认本进程窗口）、`GetWindowRect`。

会话由主引擎托管（它持有全部窗口注册表）：

```
源窗 → IPC drag:start {tabId, snapshot}
主引擎每 ~16ms 轮询：
  - GetCursorPos 取物理像素坐标
  - EnumWindows 过滤本进程可见窗口；窗口 Rect 由各窗用 window_manager 监听
    onWindowMove/onWindowResize 实时上报主引擎
  - 命中某窗标签栏带（窗口顶部 kTabStripHeight 物理高）
      → IPC drag:hover {x} 给该窗，由该窗按各 tab RenderBox 自行计算并显示插入竖线
  - 命中内容区 → 该窗整体高亮，提示"附加为末尾标签"
  - 都不命中（桌面空白）→ 无悬停目标（松手即建新窗）
提交：GetAsyncKeyState 检测左键抬起（不依赖 Flutter pointer up）
  a) 其他窗标签栏：IPC tab:attach(index) → 源窗 detach（不发 exit 语义）
  b) 其他窗内容区：attach 末尾 + 该窗置前聚焦
  c) 桌面空白：WindowController.create 新建房间窗（位置取光标处偏移），
     arguments 携带 tabs=[snapshot] 与全量数据快照
  → drag:end，清除所有窗口悬停态
```

- 拖回主窗与拖到子窗完全对称（主窗本身也是一个命中目标）；
- 取消：拖拽中按 ESC（任意引擎监听 KeyEvent 并转发主引擎）→ `drag:cancel`，标签留在原位；
- DPI：命中计算全部物理像素；插入位置由目标引擎把物理 x 转自身逻辑坐标后计算，多屏不同缩放正确；
- 显式入口：右键「移到新窗口」直接走 c) 路径。

### 6.4 窗口聚焦

插件仅提供通道，按官方示例在每个引擎注册自定义窗口方法 `window_focus`（调本引擎 `windowManager.focus()`）、`window_close` 等；主引擎通过目标窗的 `WindowMethodChannel` 调用。新建窗口自身即带焦点。

## 7. 抖音登录心跳全局仲裁

### 7.1 服务端约束

guard 服务端对同一个 accountId 只维护一个浏览器页面会话：谁调 `enterRoom` 页面就进谁的房间，心跳 20s 续租，停跳后租约超时才退房。若多个标签各自进房 / 心跳，服务端页面会被互相抢占。因此设计为**全应用一个心跳 Timer、账号态动作全部经主引擎网关**，而非每标签一个 Timer 再互相停止。

### 7.2 组件

**主引擎 `DouyinPresenceGateway`（新建，组合现有 `GuardServerService`）**

- 持有：唯一心跳 Timer、当前持有者 `holder: tabId?`、意图栈 `claimants: List<tabId>`（新意图在尾，尾端 = 最新打开 = 优先）；
- 执行全部账号态 HTTP：`getRoomDetail(asAccount:true)`、`ensureAccount/reregister`、`enterRoom`、`heartbeat`、`exitRoom`，以及 `_applyGuardStatus` 所需返回数据；现有控制器中的相关实现整体搬入网关；
- 同时承载 guard 覆盖的其他平台（bilibili / huya）账号写动作转发（进房、发弹幕、点赞、每日任务），保持"子引擎不实例化 guard 服务"这一边界清晰；
- 抖音 core 的 `htmlFetcher` / `searchFetcher` 在子引擎绑定为 IPC 代理，由主引擎 guard 实际执行。

**各引擎 `PresenceClient`（控制器侧薄代理）**

- `LiveRoomController` 现有 `_doEnterAsAccount / _startGuardHeartbeat / _exitGuardRoom / _requestGuardEnter` 等改为调代理；
- 主引擎内代理 = 直接函数调用；子引擎内代理 = IPC；控制器代码无分支差异；
- Android 不经过网关，保留控制器内现有完整逻辑（单房间无竞争）。

### 7.3 意图栈状态机

入栈条件唯一：用户在该标签**显式进入账号态**（点「进入直播间」，或发弹幕 / 点赞等写动作触发 `ensureAccountPresence`）。纯游客打开标签不入栈，不会踢任何人。

```
claim(B)：B 已在栈中则先移除再入栈尾（幂等，效果为"提到最新"）；
          claimants=[A,B] → B 成为 holder
  网关向 A 发 yield；对 B 执行 enterRoom 并启动唯一心跳
release(X)（X 关闭，close 语义）：
  - X 是 holder：网关发 exitRoom，回退栈尾次新标签自动 enterRoom 接管
  - X 不是 holder（已被 yield、当前游客态）：仅出栈，不发 exitRoom
A 中发弹幕（A 在栈但非 holder）：claim(A) 提到栈尾 → A 抢占回 holder
detach(B)（跨窗移动）：从栈中摘除；holder 时停心跳、不发 exit；
  非 holder 仅出栈。目标窗 attach 后以同一 tabId 重新 claim，落地时间刷新为最新。
  该 claim 是跨窗移动对既有意图（快照 wantsPresence=true）的内部续接，
  不属于"游客标签隐式入栈"。
```

补充规则：

- holder 心跳返回 `inRoom != true`（手机等**外部端**抢占，现有逻辑保留）：网关停止心跳、不自动抢回，该 tab 标记 `suspended`；用户在该标签主动写动作时重新 claim（claim 即清除 suspended 并重新 enter）。若因更新的标签关闭而回退到一个 suspended 标签，回退即重新 enter（用户回到 PC 操作，以最后动作为准）。被 yield 让出 holder 的标签不携带 suspended（它只是本应用内让位，下次 claim 正常 enter）；
- 404 会话丢失的 `reregister` 重注册逻辑保留在网关内；
- `refreshRoom`（房间内刷新）：release 后重新走游客加载，再次进入需用户显式触发，同现状。

### 7.4 IPC 协议（主引擎单一通道）

| 方向 | 方法 | 载荷 | 说明 |
|---|---|---|---|
| tab→主 | `claim` | tabId, siteId, roomId, shareUrl | 显式进入 / 抢占；返回 `{granted, accountDetail, guardStatus}` |
| tab→主 | `release` | tabId | 关闭（close）：持有者则网关发 exitRoom 并回退次新；非持有者仅出栈 |
| tab→主 | `detach` | tabId | 跨窗移动：停心跳不发 exit |
| tab→主 | `heartbeatLost` | tabId | 外部端抢占上报 |
| 主→tab | `yield` | — | 你已不是持有者 |
| 主→tab | `grant` | accountDetail, guardStatus | 你成为持有者（回退接管 / 抢占成功） |

close 发 `exitRoom`、detach 不发，语义与 5.4 一致。

### 7.5 被让位标签的体验

收到 yield：播放不中断（抖音游客流持续），停止心跳、`presence=guest`，用游客详情重连弹幕 WS（best-effort），聊天栏系统提示：

> 已在更新打开的直播间标签中登录进入，本标签保持游客观看；该标签关闭后将自动切回。

不发 exitRoom（账号此时在本应用另一标签的房间里）。

## 8. 子引擎引导与数据一致性

### 8.1 后端可替换，调用点不改

不重写业务代码中 40+ 处 `DBService.instance.xxx` / `AppSettingsController.instance.xxx`，改为给服务注入可替换后端：

| 服务（外观不变） | 主引擎后端 | 子引擎后端 |
|---|---|---|
| `LocalStorageService`（KV 设置） | Hive box（现状） | `RemoteKvStore`：内存值 + IPC |
| `DBService`（关注 / 音量 / 历史） | Hive（现状） | 内存 Map + IPC 写穿 |
| 5 个 `*AccountService`（cookie / 登录态） | 现状持久化 | 内存态，值来自快照 + 登录态广播 |
| `GuardServerService` | 真实服务（现状） | 不实例化；调用全部走 PresenceGateway IPC |
| `FollowService` | Hive（现状） | 内存列表 + IPC |

### 8.2 开窗快照（WindowConfiguration.arguments，JSON）

```json
{
  "type": "room_shell",
  "tabs": [{
    "tabId": "...", "siteId": "douyin", "roomId": "...", "shareUrl": "...",
    "quality": 0, "line": 0, "volume": 80, "danmakuOn": true, "wantsPresence": false
  }],
  "snapshot": {
    "settings": { "<全部 LocalStorageService 键值>": "..." },
    "follows":  { "douyin_123": "shareUrl 字符串" },
    "volumes":  { "douyin_123": 80 },
    "accounts": { "douyin": { "logined": true, "cookie": "..." } }
  }
}
```

- 不包含历史（直播间页不读历史列表）；
- `follows` 为 `"<site>_<roomId>" → shareUrl` 映射：key 存在即已关注（关注按钮状态），value 用于 shareUrl 为空时补全（`hydrateShareUrlFromFollow`）；
- cookie 跨引擎但不跨进程 / 机器，子引擎不落盘，与今天进程内明文持有等价；
- 子窗后续拖入新标签时，增量上下文走 IPC `roomContext:get` 拉取，不依赖启动快照。

### 8.3 子引擎引导 `runSubEngine(args)`

1. `MediaKit.ensureInitialized()`；
2. RemoteKvStore 载入快照 → `Get.put(AppSettingsController())`（读写代码不变）；
3. 内存版 5 个账号服务灌入快照 cookie；
4. core 抖音 `htmlFetcher` / `searchFetcher` 绑定 IPC 代理（主引擎 guard 执行）；
5. `Get.put(TabStore.fromArgs(...))` → `runApp(RoomShellApp)`；
6. window_manager 绑定本窗：标题同步、`setPreventClose` + 收尾流程。

不初始化：Hive、migrateData、SyncService、UpdateService、GuardServerService。

### 8.4 写穿与广播

主引擎注册广播通道，任何落盘写完成后向全部子窗推送：

| IPC | 方向 | 说明 |
|---|---|---|
| `kv:set` / `kv:get` | 子→主 | 设置写穿 / 同步读取 |
| `follow:set` / `follow:remove` | 子→主 | 关注 / 取关 |
| `volume:set` | 子→主 | 每房音量 |
| `history:add` | 子→主 | 观看历史 |
| `roomContext:get` | 子→主 | 拖入标签时取关注 / 音量等增量上下文 |
| `account:login` | 子→主 | 请求主窗代办登录流程 |
| `storeChanged` 广播 | 主→全部子窗 | `{kind, key, value?}`，子窗更新内存后端并刷 Rx |
| `accountChanged` 广播 | 主→全部子窗 | 登录完成 / cookie 更新 |

主窗内标签共享同一批内存对象，天然一致；子窗收广播后关注按钮、音量、登录态即时更新。

### 8.5 子窗登录与设置

- 登录：子窗触发 → IPC `account:login(siteId)` → 主窗置前并打开现有登录页 → 完成后广播 `accountChanged`，子窗等待的 Future 回调完成、弹幕登录弹窗自动继续；
- 设置页：控制条中的弹幕 / 播放设置等页面在子窗正常 push，写入经 RemoteKv 写穿；实现时审计这些页面，把个别直接碰 Hive box 的点改走 LocalStorageService；
- 子窗不提供：数据同步、检查更新、工具箱等非房间功能（仅主窗首页 / 我的中有入口）。

## 9. 原生（Windows）改动

### 9.1 NativeEditHost 自宿主化

现状弹幕原生 EDIT（见 `2026-10-14-windows-native-danmaku-edit-design.md`）依赖 runner 在 `flutter_window.cpp` 的 `MessageHandler` 中拦截 `WM_ACTIVATE / WM_MOVE / WM_SIZE`。插件子窗由插件自身的 `FlutterWindow` 创建，其消息不经过应用 runner，钩子失效。

改造：`NativeEditHost` 内部对 owner HWND 用 `SetWindowSubclass`（comctl32）自行挂消息处理（focus 拦截、owner 移动 / 缩放跟随），随 owner 的 `WM_NCDESTROY` 自动释放。主窗 runner 删除手工消息钩子，行为保持不变。

### 9.2 插件回调注册

按 desktop_multi_window 0.3.1 README 标准改法修改 `windows/runner/flutter_window.cpp`：

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"

// OnCreate() 中 RegisterPlugins 之后：
DesktopMultiWindowSetWindowCreatedCallback([](void* controller) {
  auto* vc = reinterpret_cast<flutter::FlutterViewController*>(controller);
  RegisterPlugins(vc->engine());  // 所有插件按子引擎注册（含 media_kit 等）
  HWND child = vc->view()->GetNativeWindow();
  new NativeEditHost(GetParent(child), child,
                     vc->engine()->messenger());  // 自注册自释放
});
```

子窗弹幕输入 IME 与主窗等价，无需修改插件源码。CMake 无需手改（插件走 Flutter 插件标准注册，NativeEditHost 已在 runner target 内）。

### 9.3 window_manager 共存

官方文档建议子窗场景使用 window_manager 的一个 fork ref。是否必须换用由 M0 探针验证：优先保持 pub 版 `window_manager: ^0.5.1`；仅当探针发现子窗 preventClose / focus 异常时，用 `dependency_overrides` 指向 README 指定 fork，不改版本声明。

## 10. 现有单例假设的适配

- `BackgroundAudioService.setStopRequestedHandler`：现状每 tab `onInit` 互相覆盖，改为按 tabId 注册多处理器；
- 定时关闭：见 4.5，关闭当前标签 / 窗口替代 `exit(0)`；
- 桌面小窗 / 全屏（windowManager resize / fullscreen）：作用于标签所在 OS 窗，每窗天然独立；画中画（floating）仅主窗启用；
- 窗口标题：子窗随当前标签房间名更新；
- wakelock、全局音量键等应用级状态维持现状。

## 11. 探针（M0，先行，throwaway 分支）

正式改造前用最小 spike 验证四个决策点，任一不过则回到设计阶段调整：

1. 不换 fork 的 window_manager 0.5.1 下，子窗 `create / show / focus / setPreventClose / onWindowClose` 是否正常；
2. 子窗内 media_kit 硬解播放，且全部插件经回调 RegisterPlugins 后无崩溃；
3. NativeEditHost `SetWindowSubclass` 自宿主方案编译运行：中文输入、popup 跟随 owner 移动正常；
4. 同机 4 个子窗同时播放实测 CPU / GPU / 内存，决定 V1 是否需要「后台仅音频」。

## 12. 测试策略

- **纯 Dart 单测（重点）**：
  - 心跳意图栈：claim 抢占、release 回退、detach/attach 顺序刷新、外部抢占 suspended、holder 唯一心跳不 flip-flop（扩展现有 `simple_live_app/test/live_room_presence_test.dart`）；
  - TabStore：打开去重、排序、关闭、attach/detach 快照；
  - 开窗参数 JSON 编解码；
  - RemoteKv 写穿与广播更新；
- IPC 契约：用假 channel 测试控制器 ↔ 网关协议；
- 手工验收（Windows）：多标签播放 / 独立静音、拖出拖回（含跨屏不同 DPI）、右键「移到新窗口」、主窗关闭联动、子窗登录代办、设置写穿、三个抖音房间轮换时抓包确认全应用只有一路心跳、被让位标签游客弹幕与提示；
- Android 回归：开房间 / 全屏 / 桌面小窗 / 登录 / 定时关闭路径零变化；
- 门禁：`flutter analyze` 零告警，`flutter test` 全部通过。

## 13. 里程碑

| 里程碑 | 内容 | 产出 |
|---|---|---|
| M0 | 探针（第 11 节） | 四点验证结论；不通过则修订本设计 |
| M1 | 存储后端抽口（LocalStorageService / DBService / 账号服务 / FollowService） | 行为不变的可注入后端 + 现有单测全绿 |
| M2 | 单窗标签壳：TabStore + 标签栏 + tag 化控制器，Windows 内以标签替换路由 push | 不上多窗口即可用的多标签观看 |
| M3 | DouyinPresenceGateway + PresenceClient，单引擎内先跑通意图栈 | 单窗多抖音标签心跳唯一、回退接管 |
| M4 | 子窗 + IPC：bootstrap 分发、快照 / 写穿 / 广播、窗口创建与关闭、跨窗拖拽会话 | 完整拖出 / 拖回多窗口 |
| M5 | 原生：NativeEditHost 自宿主化 + 插件回调注册 | 子窗弹幕中文输入与主窗等价 |
| M6 | 自测打磨、单测补齐、手工验收清单、Android 回归 | 走 live-cover-release 出 APK + Windows 自有渠道包 |

所有多窗口相关代码隔离在 `lib/app/multiwindow/` 与 `Platform.isWindows` 分支内：

```
lib/app/multiwindow/
├── bootstrap.dart                 # main(args) 主窗 / room_shell 分发
├── window_args.dart               # 开窗参数 JSON 编解码
├── shell/
│   ├── room_shell_app.dart        # 两种窗共用根 Widget（标签栏 + 内容区）
│   ├── tab_store.dart             # 每引擎一个
│   ├── tab_descriptor.dart
│   ├── tab_strip.dart             # 标签栏 UI + 右键菜单
│   └── tab_drag_session.dart      # 拖拽状态机
├── native/
│   └── win32_window_hit.dart      # FFI 光标 / 枚举窗口 / Rect
├── presence/
│   ├── douyin_presence_gateway.dart  # 仅主引擎
│   └── presence_client.dart
└── data/
    ├── store_backend.dart         # KV / DB 后端接口
    ├── remote_kv_store.dart       # 子引擎内存 + IPC 写穿
    └── ipc_channels.dart          # 全部 IPC 方法名 / 载荷契约
```

## 14. 非目标（V1 不做）

- macOS / Linux / iOS / TV 端多窗口；Android 端标签化；
- 关闭主窗后房间窗独立存活、子窗提升为主窗；
- Chrome 式无边框融合标签栏、OS 级拖拽虚影（OLE）；
- 标签状态（播放位置 / 弹幕历史）热迁移——直播无进度，统一快照重建；
- 子窗内房间选择器、数据同步、检查更新、工具箱；
- 后台标签弹幕渲染节流、后台仅音频（仅在 M0 指标不达标时作为 V1.1 预案启用）。
