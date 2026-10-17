# M5 子窗弹幕写动作与 NativeEditHost 多窗宿主 — 设计

**日期**：2026-10-18
**范围**：恢复子窗弹幕输入与发送；bili/huya/douyu/twitch 子窗写动作；移除两处 toast 拦截；子窗非抖音→抖音切房 client 动态重绑。
**前置**：M4-4 已合入 my_dev（`6cece98`）。M4-3 铺好 `pr_guard_send` 写通道与 cookie 借用；M4-1 将子窗弹幕 UI 置灰并留 M5。

---

## 1. 问题与缺口

| # | 缺口 | 现状 |
|---|------|------|
| A | 子窗无 NativeEditHost | host 仅在主窗 `flutter_window.cpp:41-43` 构造；`g_instance` 进程级单例被后建子窗覆盖（M0 实测串台）；dmw 子窗消息不经过主窗 MessageHandler，WM_ACTIVATE/WM_MOVE 钩子失效 |
| B | 子窗弹幕 UI 置灰 | `live_room_page.dart` SendDanmakuBar：InputDecorator `enabled:false` + Tooltip「请在主窗口发送弹幕」+ 发送按钮 `onPressed:null` |
| C | 两处 toast 拦截 | `live_room_controller.dart` 全屏回车与 `showDanmakuInputDialog` 各一处「请在主窗口发送弹幕」并 return |
| D | 四站子窗写动作不可用 | 子窗 GuardServerService `configured=false`、五账号服务空 cookie；bili/huya 走 guard 必失败、douyu/twitch 走 `liveDanmaku.sendMessage` 报 not_login；guard 互动入口 `guardActionEnabled` 子窗仅抖音放行 |
| E | 切房不重绑 client | `_presenceClient` 仅 `onInit` 绑一次；`resetRoom` 只 `refreshRemoteTab`，非抖音→抖音切房后无 client |

---

## 2. 总体方案

**原则**（沿用 M4-3）：
- 账号态 HTTP（GuardServerService）全部在主引擎执行；
- cookie 只在 `pr_apply_enter` 内存载荷下行一次，不落盘、不进 dp_/mw_/快照/日志；
- 子窗 Guest 起步，账号态按需升级。

**四条写路径**：

| 站点 | 弹幕发送 | 互动动作 |
|------|---------|---------|
| douyin | `pr_guard_send` → 网关 holder 串行域（**已通**） | 同左（**已通**） |
| bilibili | `pr_guard_send` → 主窗 `GuardServerService.sendDanmaku`（**新**） | `pr_guard_send` → 主窗 `sendAction`（**新**） |
| huya | 同 bilibili（**新**） | 无 UI（现状保留） |
| douyu | cookie 借用 → 本地 `liveDanmaku.sendMessage`（**新**） | 无 UI |
| twitch | 同 douyu（**新**） | 无 UI |

**为何拆两条**：bili/huya 弹幕与全部互动是 GuardServerService HTTP，可代理到主窗；douyu/twitch 弹幕走各自 WebSocket 连接（`sendMessage` 读 `danmakuArgs.cookie`），主窗无该连接，只能在子窗本地发——故借 cookie。bili/huya 弹幕走代理而非本地 HTTP，守住「账号态 HTTP 在主引擎」。

---

## 3. NativeEditHost 多窗自宿主化（§9.1/§9.2 落地）

### 3.1 去单例

- 删除进程级 `g_instance`。
- popup 创建后 `SetWindowLongPtrW(popup_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this))`。
- `PopupWndProc` 取自身：`GetWindowLongPtrW(hwnd, GWLP_USERDATA)`。
- `EditWndProc` 取自身：`GetParent(hwnd)` 的 USERDATA（EDIT 是 popup 子窗口）。

### 3.2 SetWindowSubclass 自宿主

构造函数对 `parent_`（owner 顶层窗）挂 `SetWindowSubclass`：

| 消息 | 行为 |
|------|------|
| `WM_MOVE` / `WM_SIZE` | `OnOwnerMoved()` |
| `WM_ACTIVATE`（WA_ACTIVE/WA_CLICKACTIVE） | `Refocus()` |
| `WM_NCDESTROY` | `RemoveWindowSubclass` + `delete this`（自释放） |

主窗 `flutter_window.cpp` 删除 MessageHandler 中的 `Refocus`/`OnOwnerMoved` 转发。

### 3.3 子窗构造（dmw 回调）

`DesktopMultiWindowSetWindowCreatedCallback` 内（已在对子引擎 `RegisterPlugins` 之后）：

```cpp
HWND child = vc->view()->GetNativeWindow();
new NativeEditHost(GetParent(child), child, vc->engine()->messenger());
```

自注册自释放，不持有指针。多 engine MethodChannel 天然按 messenger 隔离。

### 3.4 生命周期安全

- owner `WM_NCDESTROY` 时先拆 subclass 再 `delete this`，不碰已释放的 `flutter_controller_`。
- popup/EDIT 销毁链在析构函数既有逻辑；HIMC/brush/font 同步释放。

---

## 4. 子窗写动作协议扩展

### 4.1 `pr_guard_send` 载荷扩展

现有：`{windowId, tabId, kind, content?|action?}`。

扩展可选房间标识（非凭据，均为公开房间参数）：

```
+ siteId   : String   // 非抖音必填；抖音可省（走网关）
+ roomId   : String
+ webRid   : String?  // 默认 ''
+ extra    : Map?     // 默认 {}
```

### 4.2 主端 `_guardSend` 分流

```
if (call 无 siteId || siteId == douyin) {
  // 既有：gateway.sendDanmakuAsHolder / sendActionAsHolder
} else {
  // 新：直接 GuardServerService
  accountId = await guard.ensureAccount(siteId);
  if (accountId == null) → { success:false, code:'not_login' }
  kind==danmaku → guard.sendDanmaku(...)
  kind==action  → guard.sendAction(...)
}
```

失败码沿用 `kPresenceCodeNotHolder` / `kPresenceCodeNotLogin`。

### 4.3 `pr_register` 放开非抖音

现拒绝 `siteId != kDouyin`。改为：

- 一律写入 `_tabWindow[tabId] = windowId`（死亡对账索引）；
- 仅抖音走 handoff / RemotePresenceTab 逻辑；
- 非抖音 register 成功后主端立即回推 `pr_apply_enter`（见 §5）。

### 4.4 子端 client

- 抖音：既有 `_IpcPresenceClient` 全功能（claim/release/sendDanmaku/sendAction）。
- bili/huya：同一 client 类，**只调 `sendAction`/`sendDanmaku`，不 claim/release**（无仲裁语义）。
- douyu/twitch：不建 client，本地 liveDanmaku。

---

## 5. Cookie 借用扩展（douyu / twitch）

### 5.1 通道

沿用唯一凭据通道 `pr_apply_enter`。载荷扩展可选 `creds`（多键凭据）：

```
{ tabId, cookie: String,   // 单串凭据：抖音/斗鱼/虎牙/B站（可为 ''）
  creds: Map<String,String>?,  // 多键凭据：twitch {oauthToken,userLogin,clientId}
  status: Map, reentered: bool }
```

非抖音场景 `status` 为空 map，语义退化为「凭据下发」。cookie 仍必填 String（可空）；`creds` 可省。**凭据值只出现在此方法**，`cookie` 与 `creds` 同级同等敏感，不进日志/其他通道。

主端 register 成功后触发一次（房间进入/refresh 后）；子端 `refreshRemoteTab` 仍先清借用凭据再 register。

### 5.2 子端内存单点

新增纯内存写入，**不写 KV、不翻 logined 持久态**：

| 站点 | 方法 | 写入 |
|------|------|------|
| douyu | `setBorrowedLoginCookie(String?)` | `cookie` 字段 |
| twitch | `setBorrowedLoginCreds(Map<String,String>?)` | `oauthToken`/`userLogin`/`clientId`（缺省 clientId 回落 `TwitchSite.kWebClientId`） |

失效点与抖音一致三处 + refresh：yield/suspended/onClose/refreshRemoteTab。

### 5.3 弹幕升级时序

1. 进房 Guest 起步（凭据空）连接弹幕；
2. `pr_apply_enter` 到达 → 写借用凭据；
3. **重启该站 `liveDanmaku`**（复用 `reloginDouyu` 式重建：`site.liveSite.getDanmaku()` + 新 args 带凭据）；
4. 之后 `sendMessage` 读 `danmakuArgs` 凭据即有登录态。

未登录用户凭据为空：不重启，保持 Guest，发送报 `not_login`（现有文案）。

---

## 6. 控制器接线

### 6.1 UI 恢复

- `live_room_page.dart` SendDanmakuBar：删除子窗置灰分支与 Tooltip；发送按钮恢复 `onPressed`。
- `live_room_controller.dart`：删除两处 `SmartDialog.showToast('请在主窗口发送弹幕'); return;`，保留后续正常弹幕框逻辑。

### 6.2 发送分流（`sendDanmaku` / `_sendGuardAction`）

```
if (抖音 && presenceClient != null) → _sendDanmakuViaPresence / _sendActionViaPresence   // 既有
else if (子窗 && (bilibili || huya) && writeClient != null)
    → writeClient.sendDanmaku / sendAction                                                // 新
else if (guard.configured && _guardPlatforms.contains(site.id))
    → guard.ensureAccount + guard.sendDanmaku                                              // 既有主窗
else
    → liveDanmaku.sendMessage                                                              // douyu/twitch + 主窗回退
```

`guardActionEnabled` 扩展：子窗 bilibili 放行（`|| (_isSubWindow && site.id == 'bilibili')`），与抖音子窗同理。

### 6.3 Client 动态重绑（缺口 E）

`resetRoom` 完成 `_reRegisterSubWindowTabAfterLeave` 后：

```
_presenceClient = null;
if (!bindSubWindowPresence()) {
  // 非抖音子窗：按站点挂 write client（bili/huya）
  bindSubWindowWriteClient();
}
```

`bindSubWindowPresence` 保持抖音专用（claim 语义）；`bindSubWindowWriteClient` 新建，仅 `clientForTab` 赋值。非抖音→抖音切房由此拿到 presence client；反向释放旧 client 即可（无 claim 需 release）。

### 6.4 `danmakuLogined`

子窗五账号服务空 cookie 恒 false。douyu/twitch 借用 cookie 后 `loginCookie` 非空，判定自然变真；bili/huya 不借 cookie，发送走代理不受 `danmakuLogined` 门控（代理在主窗判登录）。子窗登录提示对话框文案沿用（引导主窗登录）。

---

## 7. 凭据安全（逐条）

| 面 | 约束 |
|----|------|
| `pr_apply_enter` | **唯一**凭据值流（`cookie` 单串 + `creds` 多键）；仅内存载荷；空值亦走此通道 |
| `pr_guard_send` | 新增 siteId/roomId/webRid/extra 均为公开房间参数，**无**凭据 |
| `mw_` / `dp_` / 开窗快照 | 一律不改，仍无凭据字段 |
| 日志 | 不打 cookie/oauthToken；IPC 异常固定文案 |
| 失效点 | yield / suspended / onClose / refreshRemoteTab 四处清借用凭据 |

---

## 8. 测试

| 层 | 用例 |
|----|------|
| 协议 | `pr_guard_send` 带/不带 siteId 编解码；非法载荷 null；room 参数缺省 |
| 主端分流 | 非抖音 guardSend → mock GuardServerService 一次调用；not_login；douyin 不进新分支 |
| register | 非抖音建索引返回 true 且不建 RemotePresenceTab；抖音 handoff 不回归 |
| cookie 借用 | douyu/twitch setBorrowed 纯内存；三失效点+refresh 清零；空 cookie 不重启弹幕 |
| 控制器 | 子窗 bili sendDanmaku → writeClient；douyu → liveDanmaku；切房非抖音→抖音重建 client |
| UI | 子窗 SendDanmakuBar 可点（widget 测试）；两处 toast 文案断言移除 |
| 结转 | target 窗死亡 fail-fast（M4-4 §9.3）；NIT-1 兜底文案断言 |
| 门禁 | analyze 基线 22 零新增；全量 test 只增不减（354→）；接线任务 `build windows --debug` |

---

## 9. GUI 手工验收（用户统一验证，执行者不得声称已过）

1. 子窗弹幕输入框点击弹出原生 EDIT，搜狗拼音组字/选词/中文提交正常。
2. 开过子窗后回主窗测 IME 无串台（g_instance 已除）。
3. popup 跟随子窗移动/缩放；子窗关闭后主窗 IME 正常。
4. 子窗 bili 房发弹幕成功；点赞/灯牌各一次成功。
5. 子窗 huya 房发弹幕成功。
6. 子窗 douyu/twitch 房登录态发弹幕成功；未登录提示 not_login 文案。
7. 子窗全屏回车弹输入框（不再 toast）；输入后发送成功。
8. 子窗非抖音→抖音切房后发弹幕/点赞走 presence，心跳唯一。
9. 子窗抖音→bili 切房后发弹幕走代理。
10. 主窗各站发弹幕/点赞无回归。

---

## 10. 文件清单

| 文件 | 改动 |
|------|------|
| `windows/runner/native_edit_host.h/.cpp` | 去 g_instance、USERDATA、SetWindowSubclass、自释放 |
| `windows/runner/flutter_window.cpp` | 删 MessageHandler 钩子；回调 `new NativeEditHost` |
| `lib/app/multiwindow/presence/ipc/presence_protocol.dart` | guard_send 载荷扩展 + 编解码 |
| `lib/app/multiwindow/presence/ipc/main_presence_service.dart` | register 放开；guardSend 分流 |
| `lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart` | 非抖音 register 后 apply_enter；refresh 清 cookie |
| `lib/services/douyu_account_service.dart` | setBorrowedLoginCookie |
| `lib/services/twitch_account_service.dart` | setBorrowedLoginCookie |
| `lib/modules/live_room/live_room_controller.dart` | UI 门解除、发送分流、client 重绑、guardActionEnabled |
| `lib/modules/live_room/live_room_page.dart` | SendDanmakuBar 恢复 |
| `test/**` | 协议/主端/cookie/控制器/UI/结转用例 |

---

## 11. 明确不做

- 不改插件源码（desktop_multi_window / window_manager）；
- 不做子窗登录代办 UI（account:login 留后续）；
- 不做 huya/douyu/twitch 互动动作（无 UI）；
- 不做子窗 GuardServerService 配置（serverUrl/token 不下发）；
- Android/TV/首页零行为变化。
