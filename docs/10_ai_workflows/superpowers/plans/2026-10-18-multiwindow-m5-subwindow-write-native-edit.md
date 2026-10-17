# M5 子窗弹幕写动作与 NativeEditHost 多窗宿主 — 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 恢复子窗弹幕输入与发送（NativeEditHost 多窗宿主 + IME），打通 bili/huya/douyu/twitch 子窗写动作，移除两处 toast 拦截，修复非抖音→抖音切房 client 重绑。

**Architecture:** NativeEditHost 改 SetWindowSubclass 自宿主 + per-USERDATA 寻址，在 dmw 回调里对子窗自建；bili/huya 写动作经扩展的 `pr_guard_send` 代理到主窗 GuardServerService；douyu/twitch 借 cookie 后本地 `liveDanmaku.sendMessage`；控制器切房后重建 presence/write client。

**Tech Stack:** C++ Win32 (SetWindowSubclass/IMM32)、Flutter/Dart GetX、desktop_multi_window 0.3.1、既有 pr_ IPC。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-18-multiwindow-m5-subwindow-write-native-edit-design.md`

## Global Constraints

- Flutter 固定 `C:/tools/flutter347/flutter/bin/flutter.bat`（3.47.5 / Dart 3.13.4）；cwd 常为 `D:\project\dart_simple_live\simple_live_app`，git 根 `D:\project\dart_simple_live`（app 路径带 `simple_live_app/` 前缀）。
- analyze 基线 **22 条（2 warning + 20 info）零新增**；全量 `flutter test` 只增不减（当前 354）；接线任务额外 `build windows --debug`。
- **严禁 `git add -A` / `git add .`**，只 add 精确路径；约 40 个无关存量脏文件不碰/不还原/不清理/不提交。
- commit 简体中文，结尾空行 + `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`。
- 敏感键 17 具名 + GuardAccountId_ 前缀；cookie/token **绝不**进 dp_/mw_/开窗快照/RemoteKvBox/日志；`pr_guard_send` 新增字段仅公开房间参数。
- cookie 唯一通道 `pr_apply_enter`，纯内存借用，失效点 yield/suspended/onClose/refreshRemoteTab。
- Android/TV/首页零行为变化；新文件绝对 import；Timer 卫生；站点 id 字面 `bilibili/douyin/douyu/huya/twitch`。
- C++ UTF-8 BOM 源文件；`Color.toARGB32()`（非 `value`）。
- GUI 手工清单只列不做，执行者**不得声称 GUI 已过**。
- dmw 单 handler 槽位只许委托不许重挂。

---

### Task 1: NativeEditHost 自宿主化（C++）

**Files:**
- Modify: `simple_live_app/windows/runner/native_edit_host.h`
- Modify: `simple_live_app/windows/runner/native_edit_host.cpp`
- Modify: `simple_live_app/windows/runner/flutter_window.cpp`

**Interfaces:**
- Produces: `NativeEditHost(HWND parent, HWND engine_window, flutter::BinaryMessenger* messenger)` 自注册自释放；owner 移动/激活由 SetWindowSubclass 自处理；主窗 MessageHandler 不再转发。
- 子窗构造点：`DesktopMultiWindowSetWindowCreatedCallback` 内 `new NativeEditHost(GetParent(child), child, vc->engine()->messenger())`。

**设计要点（已定，照此实现）：**

1. **去 `g_instance`**：构造时 `SetWindowLongPtrW(popup_, GWLP_USERDATA, (LONG_PTR)this)`（在 `EnsureCreated` 创建 popup 后）。`PopupWndProc` 取 `GetWindowLongPtrW(hwnd, GWLP_USERDATA)`；`EditWndProc` 取 `GetParent(hwnd)` 的 USERDATA。
2. **SetWindowSubclass(parent_)**：子类过程处理 `WM_MOVE`/`WM_SIZE` → `OnOwnerMoved()`；`WM_ACTIVATE`（WA_ACTIVE/WA_CLICKACTIVE）→ `Refocus()`；`WM_NCDESTROY` → `RemoveWindowSubclass` + 清资源 + `delete this`。保存 `UINT_PTR subclass_id_`。
3. **构造函数**挂 subclass；**析构**若尚未拆则拆。popup_ 创建失败时不得挂 subclass。
4. **flutter_window.cpp**：
   - 删除 MessageHandler 中对 `native_edit_host_->Refocus()` / `OnOwnerMoved()` 的调用（以及 `WM_MOVE`/`WM_SIZE`/`WM_ACTIVATE` 相关分支里对 host 的依赖）。
   - 删除 `std::unique_ptr<NativeEditHost> native_edit_host_` 成员，改为裸 `new NativeEditHost(...)`（自释放）。
   - `DesktopMultiWindowSetWindowCreatedCallback` 内在 `RegisterPlugins(registry)` 之后追加：
     ```cpp
     HWND child = vc->view()->GetNativeWindow();
     if (child) {
       HWND top = GetAncestor(child, GA_ROOT);
       if (top) new NativeEditHost(top, child, vc->engine()->messenger());
     }
     ```
5. **行为保持**：主窗弹幕原生输入、popup 跟随、IME 组字、Enter/Esc 与改造前一致。
6. **不要**改 desktop_multi_window 插件源码；**不要**动 CMake。

**Steps:**
- [ ] 改 `native_edit_host.h`：去掉对 `g_instance` 的暗示；加 `UINT_PTR subclass_id_ = 0;`、`static LRESULT CALLBACK OwnerSubclassProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);`；注释更新为「每窗一个 host，按 USERDATA 寻址」。
- [ ] 改 `native_edit_host.cpp`：
  - 删 `NativeEditHost* g_instance = nullptr;` 及所有 `g_instance = this` / `g_instance == this` / `g_instance` 读取。
  - `EnsureCreated`：popup 创建成功后 `SetWindowLongPtrW(popup_, GWLP_USERDATA, (LONG_PTR)this)`。
  - `PopupWndProc` / `EditWndProc`：改从 USERDATA 取 `this`（EDIT 经 `GetParent`）。
  - 构造函数末尾 `subclass_id_ = SetWindowSubclass(parent_, OwnerSubclassProc, 1, (DWORD_PTR)this);`（`#include <commctrl.h>`，链接已含 comctl32）。
  - `OwnerSubclassProc`：按上表分发；`WM_NCDESTROY` 时 `RemoveWindowSubclass(hwnd, OwnerSubclassProc, subclass_id_)`（注意从 dwRefData 取 this 拿 id）、释放 popup/EDIT/himc/brush/font（可调析构内逻辑或直接 `delete self`），返回 `DefSubclassProc`。
  - 析构：若 `subclass_id_ != 0 && parent_` 仍有效则 `RemoveWindowSubclass`。
  - `SetWindowLongPtrW(popup_, GWLP_USERDATA, 0)` 在 DestroyWindow 前清理（可选，销毁自动清）。
- [ ] 改 `flutter_window.cpp`：按设计要点 4。
- [ ] Run: `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`（cwd `simple_live_app`）
  Expected: 编译成功。
- [ ] Commit（精确路径三个文件）。

---

### Task 2: 子窗弹幕 UI 恢复 + 两处 toast 移除

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_page.dart`（SendDanmakuBar，约 :1080-1185）
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（两处 toast，约 :1347-1362）
- Modify: `simple_live_app/test/...`（既有断言「请在主窗口发送弹幕」/置灰 UI 的测试改为断言可用或删除对应子窗禁用断言）

**Interfaces:**
- Consumes: Task 1 完成后子窗存在 NativeEditHost（运行时）；本任务纯 Dart，不依赖 C++ 编译结果即可合入。
- Produces: 子窗 SendDanmakuBar 可点击/可发送；`showDanmakuInputDialog` 与全屏回车不再 toast 拦截。

**Steps:**
- [ ] `live_room_page.dart` SendDanmakuBar：
  - 删除子窗 `InputDecorator` 的 `enabled: false` 与 Tooltip「请在主窗口发送弹幕」分支（恢复与主窗相同外观，仅 Windows 走 NativeEditField）。
  - 发送按钮：删除子窗 `onPressed: null`，恢复 `onPressed: busy ? null : _send`（或既有发送回调）。
  - 保留非 Windows / 非子窗既有逻辑零变化。
- [ ] `live_room_controller.dart`：
  - 全屏回车分支：删除 `SmartDialog.showToast('请在主窗口发送弹幕'); return;`，保留后续 `showDanmakuInputDialog` 调用。
  - `showDanmakuInputDialog` 首行：删除同样 toast+return，保留对话框逻辑。
  - grep 确认 `请在主窗口发送弹幕` 在 lib/ 下 **0** 处。
- [ ] 同步测试：搜索 test/ 中该文案与置灰断言，改为：
  - 子窗弹幕栏不再断言 Tooltip/disabled；
  - 或改为断言「子窗可调用 showDanmakuInputDialog / 发送按钮 enabled」。
- [ ] Run: `C:/tools/flutter347/flutter/bin/flutter.bat test` （只跑改到的测试文件可先单文件）
  Expected: 改过的测试 PASS。
- [ ] Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze`
  Expected: 22 条基线，零新增。
- [ ] Commit。

---

### Task 3: Cookie/凭据借用扩展（douyu/twitch）+ 弹幕升级

**Files:**
- Modify: `simple_live_app/lib/services/douyu_account_service.dart`
- Modify: `simple_live_app/lib/services/twitch_account_service.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/presence_protocol.dart`（pr_apply_enter 空 status + creds）
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart`（register 非抖音后回推 apply_enter）
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart`（非抖音 apply_enter 只写凭据）
- Test: `simple_live_app/test/services/douyu_account_service_test.dart`（新建或扩展）、`test/multiwindow/...`

**Interfaces:**
- Produces:
  - `DouyuAccountService.setBorrowedLoginCookie(String? cookie)` — 纯内存写 `cookie` 字段，不写 KV、不翻 logined。
  - `TwitchAccountService.setBorrowedLoginCreds(Map<String,String>? creds)` — 纯内存写 `oauthToken`/`userLogin`/`clientId`（clientId 缺省 `TwitchSite.kWebClientId`），不写 KV。
  - `PresenceApplyEnterCall` 增可选 `creds: Map<String,String>?`；`status` 允许空 Map/缺失（默认 `{}`）。
- Consumes: 既有 `DouyinAccountService.setBorrowedLoginCookie` 作同构参照（`douyin_account_service.dart:104-116`）。

**Steps:**
- [ ] 两个 account service 各加纯内存 setter：
  ```dart
  /// Douyu：纯内存单点，只写 cookie 字段，不写 KV、不翻 logined。
  void setBorrowedLoginCookie(String? cookie) {
    this.cookie = cookie ?? '';
  }

  /// Twitch：纯内存单点，OAuth 三元组，不写 KV、不翻 configured。
  void setBorrowedLoginCreds(Map<String, String>? creds) {
    oauthToken = creds?['oauthToken'] ?? '';
    userLogin = creds?['userLogin'] ?? '';
    clientId = (creds?['clientId'] ?? '').isNotEmpty
        ? creds!['clientId']!
        : TwitchSite.kWebClientId;
    // 注意：不调 setSite()——那会把值写进 Site 并可能触发持久化路径；
    // 若 TwitchDanmakuArgs 构造直接读 service 字段（如 live_room 构 args），
    // 只写字段即可；若必须写 site.oauthToken 则与 setSite 拆开只赋值。
  }
  ```
  **实现前先读** `TwitchSite`/`TwitchDanmakuArgs` 与 `live_room_controller` 构 args 处，确认 send/start 读的是 service 字段还是 args 快照，按实际读取点写入。
- [ ] `presence_protocol.dart`：
  - `PresenceApplyEnterCall` 加 `final Map<String, String>? creds;`
  - encode 带上非空 `creds`；decode 允许 `status` 空 Map/缺失、`creds` 缺失。
  - cookie 仍必填 String（可为 `''`）。
- [ ] `main_presence_service.dart` `_register`：
  - 删除 `call.siteId != Constant.kDouyin` 拒绝；所有站点 `_tabWindow[call.tabId] = call.windowId`。
  - 仅抖音走既有 handoff/RemotePresenceTab。
  - 非抖音：按 siteId 读对应账号服务凭据，构造 `PresenceApplyEnterCall`（douyu→cookie 字段；twitch→creds 三键；cookie 可 `''`）经 `port.invoke(windowId, pr_apply_enter, ...)` 回推；best-effort 吞错。
  - cookieReader 现为抖音专用；扩为 `String Function(String siteId)` 或新增 `cookieReaderFor`；twitch 另需 `credsReaderFor`。**最小改动**：`switch (siteId)` 直读四个账号服务字段。
- [ ] `ipc_presence_coordinator.dart`：
  - `registerRemoteTab` 存 `tabId → siteId`。
  - `handleCall` `mApplyEnter`：按 tabId 查 siteId 分发——抖音→既有 `setBorrowedLoginCookie`；douyu→`setBorrowedLoginCookie`；twitch→`setBorrowedLoginCreds`。**不** fetchAccountDetail / applyAccountEnter。
  - 非抖音分支随后调用已绑定回调 `onCredentialsApplied?.call(tabId, siteId)`（coordinator 新增接线点，live_room_controller 注册）。
  - `refreshRemoteTab`：清凭据时三站 setter 传 null/空。
- [ ] 弹幕升级：`live_room_controller` 在 `onCredentialsApplied` 回调里（仅 douyu/twitch）：凭据非空且 `liveDanmaku` 已连接则 stop → `site.liveSite.getDanmaku()` → `start(newArgs 带凭据)`（同 `reloginDouyu` 结构）；凭据空则不重启。
- [ ] Tests：
  - setBorrowed 纯内存（不写 LocalStorage）；null 清空。
  - decodeApplyEnter 空 status / 缺 status / 带 creds 合法；cookie 仍必填。
  - 非抖音 register 回推 apply_enter 一次；douyu 走 cookie 字段、twitch 走 creds；**载荷无其他字段**。
  - apply_enter 后 douyu.cookie / twitch.oauthToken 正确；yield/suspended/refresh 清零。
- [ ] analyze + 相关 test。
- [ ] Commit。

---

### Task 4: 写动作协议扩展 + 主端分流

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/presence_protocol.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/main_presence_service.dart`
- Modify: `simple_live_app/lib/app/multiwindow/presence/presence_client.dart`（接口若需带房间参数）
- Modify: `simple_live_app/lib/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart`（`_IpcPresenceClient` send 时带 room 参数）
- Test: `simple_live_app/test/multiwindow/presence_protocol_test.dart`、`main_presence_service_test.dart` 或既有测试文件扩展

**Interfaces:**
- Consumes: Task 3 的 register 非抖音索引。
- Produces:
  - `PresenceGuardSendCall` 增可选 `siteId, roomId, webRid, extra`。
  - `PresenceClient.sendDanmaku/sendAction` 扩展携带房间参数（或 client 构造时固化 `PresenceClaimArgs`——**推荐**：client 已持有 `args()` 闭包，send 时读取即可，接口签名可不变，encode 时把 args 里 room 字段带上）。
  - 主端 `_guardSend`：无 siteId 或 douyin → 现网关；否则 GuardServerService。

**Steps:**
- [ ] `presence_protocol.dart`：
  ```dart
  class PresenceGuardSendCall {
    // 既有 windowId, tabId, kind, content?, action?
    final String? siteId;   // 缺省/空 = 抖音走网关
    final String? roomId;
    final String? webRid;
    final Map<String, Object?>? extra;
  }
  ```
  encode 带上非空字段；decode 允许缺省。`extra` 仅 JSON 兼容标量/Map/List，无凭据键校验（协议层不放 cookie 字段即可，由评审 lens grep）。
- [ ] `_IpcPresenceClient.sendDanmaku/sendAction`：encode 时从 `args()` 读 `guardRoomId/guardWebRid/guardExtra` 与外部传入/闭包中的 `siteId` 填入。`PresenceClaimArgs` 若无 siteId，client 构造参数加 `siteId`（`clientForTab` 已知 siteId，从 coordinator 传入）。
- [ ] `main_presence_service.dart` `_guardSend`：
  ```dart
  final call = PresenceProtocol.decodeGuardSend(arguments);
  if (call == null) return {'success': false, 'code': 'bad_args'};
  final siteId = call.siteId;
  if (siteId == null || siteId == Constant.kDouyin) {
    // 既有 gateway 路径，一行不改语义
  } else {
    final guard = GuardServerService.instance;
    if (!guard.configured) return {'success': false, 'code': 'not_configured'};
    final accountId = await guard.ensureAccount(siteId);
    if (accountId == null) return {'success': false, 'code': kPresenceCodeNotLogin};
    try {
      if (call.kind == PresenceProtocol.kDanmaku) {
        final data = await guard.sendDanmaku(
          platform: siteId, accountId: accountId,
          roomId: call.roomId ?? '', webRid: call.webRid ?? '',
          content: call.content!, extra: call.extra?.cast<String, dynamic>(),
        );
        return {'success': data['success'] == true, if (data['message'] != null) 'message': data['message']};
      } else {
        final data = await guard.sendAction(
          accountId: accountId, roomId: call.roomId ?? '',
          webRid: call.webRid ?? '', action: call.action!,
        );
        return {'success': data['success'] == true, if (data['message'] != null) 'message': data['message']};
      }
    } catch (e) {
      return {'success': false, 'code': 'guard_error', 'message': '网络请求失败'};
    }
  }
  ```
  **不**在此路径做 holder 检查（非抖音无仲裁）。douyin 既有索引归属门保留。
- [ ] Tests：
  - encode/decode 带 siteId/roomId/webRid/extra  round-trip；缺省可解码。
  - mock GuardServerService：非抖音 sendDanmaku/sendAction 各一次调用、参数正确。
  - ensureAccount null → not_login；guard 未配置 → not_configured。
  - douyin 载荷（无 siteId）仍走 mock gateway，不调 GuardServerService。
  - grep 载荷无 cookie/token 字段。
- [ ] analyze + test。
- [ ] Commit。

---

### Task 5: 控制器接线（发送分流 + client 重绑 + guardActionEnabled）

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`
- Test: `simple_live_app/test/sub_window_presence_controller_test.dart` 或 `live_room_controller_*_test.dart`

**Interfaces:**
- Consumes: Task 3 cookie 升级回调；Task 4 write client（`coordinator.clientForTab` 带 siteId）。
- Produces: 子窗 bili/huya 发弹幕/动作走 writeClient；douyu/twitch 走 liveDanmaku（cookie 到位后）；切房重建 client；`guardActionEnabled` 子窗 bilibili 放行。

**Steps:**
- [ ] `sendDanmaku` 分流（在既有抖音 presence 分支之后）：
  ```dart
  } else if (_isSubWindow && (site.id == 'bilibili' || site.id == 'huya') && _writeClient != null) {
    result = await _writeClient!.sendDanmaku(content);
    // 映射 PresenceSendResult → DanmakuSendResult
  } else {
    // 既有 guard / liveDanmaku 回退（douyu/twitch 走 liveDanmaku）
  }
  ```
  `PresenceSendResult → DanmakuSendResult`：success→success；code 作 errorCode；message 作 errorMessage。
- [ ] `_sendGuardAction` 同构：抖音 presence 分支之后加子窗 bili writeClient 分支。
- [ ] `_writeClient` 字段：`PresenceClient?`；`bindSubWindowWriteClient()`：
  ```dart
  bool bindSubWindowWriteClient() {
    if (!_isSubWindow || tabId == null || !Get.isRegistered<IpcPresenceCoordinator>()) return false;
    if (site.id != 'bilibili' && site.id != 'huya') return false;
    _writeClient = Get.find<IpcPresenceCoordinator>().clientForTab(
      tabId: tabId!, args: presenceClaimArgs, siteId: site.id,
    );
    return true;
  }
  ```
  （`clientForTab` 若 Task 4 已加 siteId 参数则对齐签名。）
- [ ] `onInit`：`if (!bindSubWindowPresence()) { bindSubWindowWriteClient(); }`。
- [ ] `resetRoom` 末尾（`_reRegisterSubWindowTabAfterLeave` 之后）：
  ```dart
  _presenceClient = null;
  _writeClient = null;
  if (!bindSubWindowPresence()) {
    bindSubWindowWriteClient();
  }
  ```
  这实现「非抖音→抖音切房 client 动态重绑」与反向。
- [ ] `guardActionEnabled`：
  ```dart
  bool get guardActionEnabled =>
      (GuardServerService.instance.configured &&
          (site.id == "douyin" || site.id == "bilibili") &&
          danmakuLogined) ||
      _isSubWindowDouyin ||
      (_isSubWindow && site.id == "bilibili");
  ```
- [ ] Tests（mock coordinator/client）：
  - 子窗 bili `sendDanmaku` → `writeClient.sendDanmaku` 恰一次。
  - 子窗 douyu `sendDanmaku` → `liveDanmaku.sendMessage`（不调 writeClient）。
  - `resetRoom` 后 `_presenceClient` 重建（非抖音→抖音）。
  - `guardActionEnabled` 子窗 bili 为 true。
  - 主窗行为零变化用例不回归。
- [ ] analyze + test。
- [ ] Commit。

---

### Task 6: 结转用例 + 跨任务回归

**Files:**
- Test: `simple_live_app/test/multiwindow/...`（M4-4 §9.3 target 窗死亡 fail-fast）
- Test: 既有兜底文案断言（NIT-1）补全
- 其余测试缺口按实现情况补

**Steps:**
- [ ] target 窗死亡 fail-fast：按 M4-4 spec §9.3 补用例（目标窗已关闭时迁移/发送返回失败不悬挂）。
- [ ] NIT-1：兜底文案断言（invokeMain 抛错 → 固定 toast 文案，不 rethrow）。
- [ ] 全量 `flutter test`：只增不减（354 → N≥354）。
- [ ] analyze 零新增。
- [ ] Commit。

---

### Task 7: 全量门禁 + GUI 清单

**Steps:**
- [ ] `flutter analyze` → 22 基线零新增。
- [ ] `flutter test` → 全绿，只增不减。
- [ ] `flutter build windows --debug` → 成功。
- [ ] 输出 GUI 手工清单（spec §9 十项），明确「执行者不得声称 GUI 已过，留用户统一验证」。
- [ ] 汇总测试数、analyze 数、涉及文件列表。

---

## 自检

- [x] Spec 覆盖：A 宿主=Task1；B/C UI=Task2；D 写动作=Task3+4+5；E 重绑=Task5；结转=Task6；门禁=Task7。
- [x] 无 TBD/TODO 占位。
- [x] 类型一致：`setBorrowedLoginCookie`、`bindSubWindowWriteClient`、`_writeClient`、`clientForTab(siteId:)`、`PresenceGuardSendCall.siteId` 后文一致。
