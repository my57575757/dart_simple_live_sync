# M4-1 多窗口薄片（游客态独立窗口）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 端支持把直播间用独立 OS 窗口打开（卡片「新窗口打开」、游客标签「移到新窗口」），同一进程内多个 Flutter engine 各自播放、全部有声；同 siteId+roomId 全局去重前置；主窗关闭退出整个应用。本阶段子窗仅游客态。

**Architecture:** 引入 desktop_multi_window 0.3.1（单进程多引擎，主引擎唯一协调者）。主引擎负责窗口注册表、全局去重与开窗 IPC；子引擎用纯内存 KV 后端启动精简服务集（无 Hive、无 presence 网关、无 Sync/Update），按主引擎传来的 JSON 快照（设置/屏蔽词/音量/关注 shareUrl）以游客身份重建直播间。跨窗移动＝快照重建（本阶段即「新窗游客新开 + 本窗标签关闭」）。media_kit_video 必须使用 vendor 补丁版，否则第二引擎创建后主窗消息错路由卡死（M0 实证）。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4（`C:/tools/flutter347/flutter/bin/flutter.bat`）、GetX 4.7.3、Hive 2.2.3、media_kit 1.2.6、media_kit_video 2.0.1（vendor 补丁版）、window_manager 0.5.2、desktop_multi_window 0.3.1。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-15-multi-window-tabs-design.md`（16 条决策已冻结；本计划实现其 M4 的第一切片，推迟项见 Global Constraints）

## Global Constraints

- 全程简体中文（代码注释、提交信息、用户可见文案）；标识符/命令/路径/报错原文保持英文。
- Flutter 一律用 `C:/tools/flutter347/flutter/bin/flutter.bat`（3.47.5 / Dart 3.13.4）。**不要**用 AGENTS.md 写的 3.38（机器上没有）。
- 仅 Windows：所有新行为必须在 `Platform.isWindows` 或子引擎角色之后；Android/iOS 路径零改动（`RoutePath.kLiveRoomDetail` 整页跳转、tabId==null 分支一律不碰）。
- **不 push、不发版**，只本地 commit。每个 commit message 结尾空行后加：
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`
- 工作区有约 40 个与本任务无关的存量脏文件（.idea/ 等）。**严禁 `git add -A` / `git add .`**，每个 commit 只 add 本任务列出的精确路径（仓根在 `D:/project/dart_simple_live`，Flutter 包在其下 `simple_live_app/`）。
- TDD：纯 Dart 逻辑先写失败测试再实现；新测试统一放 `simple_live_app/test/multiwindow/`。
- 静态检查用 scoped 命令：`C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`（在 `simple_live_app/` 下执行），不得引入新增告警；存量告警（如 ConnectivityResult 那条 unrelated_type_equality_checks）不在本任务改动行上即视为通过。
- 不修改 pub cache 里的任何包；media_kit_video 补丁版以 vendor 副本入仓 `simple_live_app/third_party/media_kit_video/`（原始补丁存档于 `simple_live_app/third_party/patches/`）。
- **M4-1 仅游客态**：子引擎不注册 Hive、DouyinPresenceGateway、SyncService、UpdateService、IndexedController；五个账号服务（Douyin/Bili/Douyu/Huya/Twitch）照常注册但凭据已被快照剥离，空 cookie 天然游客态；抖音账号态标签的「移到新窗口」置灰并提示「账号跨窗在下一阶段支持」；卡片「新窗口打开」始终可用（＝全新游客进入）。
- Ruling（Task 6 控制器预排雷修正，覆盖早前"不注册 4 账号服务"裁决）：五个账号服务子窗全部注册。证据：斗鱼进房播放路径 `loadData()` 直查 `DouyuAccountService.instance`（live_room_controller.dart:1435，未注册即崩）；弹幕登录态 getter `danmakuLogined`（:1237）UI 构建期遍历五服务。四服务 onInit 均只读 KV + setSite（Bili 的 loadUserInfo 在 cookie 空时立即 return），快照剥离 cookie/token 后 logined/configured 全 false、无网络与定时器，游客态成立。SyncService 仅同步页、UpdateService 仅 IndexedController（首页，子窗不建）使用，不注册。子窗内账号管理深路由等边缘交互报错仍留 M4-3 收口，GUI 验收不覆盖。
- 明确不做（后续里程碑）：IPC 数据写穿/子窗设置页（M4-2）、账号跨窗 presence IPC（M4-3）、标签拖出/拖回/跨窗合并手势（M4-4）、NativeEditHost 的 SetWindowSubclass（M5）。
- dmw 0.3.1 已核实的关键 API（以 pub cache 实际源码为准，不要照抄网上旧示例）：
  - `WindowController.fromCurrentEngine()` → `Future<WindowController>`，字段 `String windowId`、`String arguments`；**主窗 `arguments == ''`**（空串），windowId 是 UUID 字符串。
  - `WindowController.create(WindowConfiguration(arguments: json, hiddenAtLaunch: true))`，**无** title/size 参数（原生硬编码 800x600@(10,10)+空标题，尺寸标题由子引擎 window_manager 接管后设置）。
  - IPC：`controller.invokeMethod('focus_tab', args)` 走该窗专属 channel `mixin.one/window_controller/$windowId`（unidirectional）；接收方在**自己 engine** 上 `WindowController.fromCurrentEngine()`（或同 id 的 `fromWindowId`）后 `setWindowMethodHandler((MethodCall call) async {...})`。自定义方法名**不需要** `window_` 前缀（前缀 assert 只作用于内建 show/hide）。
  - 顶层 `onWindowsChanged` 是 `Stream<void>`（不带 payload），事件后用 `WindowController.getAll()` 对账。
  - dmw **没有** close/destroy 的 Dart API：关子窗＝自定义方法让子窗自己 `windowManager.close()`（M0 结论：子窗严禁 `destroy()`，那是 PostQuitMessage 会杀掉整个进程）。

---

## File Structure

新建（均在 `simple_live_app/lib/app/multiwindow/` 下）：

| 文件 | 职责 |
|---|---|
| `bootstrap/kv_box.dart` | KV 接缝：`KvBox<T>` 抽象 + `HiveKvBox<T>` / `MemoryKvBox<T>`，方法名与 Hive Box 一致 |
| `window/window_args.dart` | 子窗参数 JSON 编解码：`RoomWindowArgs` / `RoomTabArg` / `WindowSnapshot` |
| `bootstrap/in_memory_services.dart` | `InMemoryLocalStorageService` / `InMemoryDBService`，子引擎专用，快照播种 |
| `window/sub_window_port.dart` | 窗口能力端口抽象 `SubWindowPort` + `SubWindowHandle`（测试可 fake） |
| `window/dmw_sub_window_port.dart` | dmw 生产实现；持有主窗 controller |
| `window/window_registry.dart` | 纯逻辑：windowId→tabKeys 注册表、去重查询、存活对账 |
| `window/window_open_service.dart` | 主引擎开窗协调者（GetxService）+ `WindowSnapshotBuilder` |
| `window/window_role.dart` | `MultiWindowRole.isSubWindow` + `SubWindowCommands.closeRequested` |
| `bootstrap/sub_engine_bootstrap.dart` | `runSubEngine()` 精简引导（runApp 复用参数化后的 `MyApp(isSubWindow: true)`，不另写 App 骨架） |

修改：

| 文件 | 改动 |
|---|---|
| `lib/services/local_storage_service.dart` | 两个 box 字段改 `KvBox`，init 包 HiveKvBox |
| `lib/services/db_service.dart` | 四个 box 字段改 `KvBox`；新增 `getFollowShareUrl` / `exportVolumes` / `exportFollowShareUrls` |
| `lib/modules/live_room/live_room_controller.dart` | `hydrateShareUrlFromFollow` 去掉 followBox 直连，走新方法 |
| `lib/services/follow_service.dart` | 构造参数 `enableScheduledRefresh`（默认 true），false 时 onInit 不起定时器 |
| `lib/app/multiwindow/shell/tab_store.dart` | `findByKey` / `activateByKey` |
| `lib/main.dart` | main 按 dmw arguments 分发主/子引擎；原主体改 `runMainEngine()` |
| `lib/app/multiwindow/shell/room_shell_page.dart` | `isSubWindow` 变体：无首页、空态、最后标签关窗、标题同步、close 语义、联动子窗文案 |
| `lib/app/multiwindow/shell/tab_strip.dart` | 标签右键加「移到新窗口」（账号态置灰、子窗不显示） |
| `lib/app/multiwindow/shell/room_context_menu.dart` | 「新窗口打开」启用 |
| `lib/routes/app_pages.dart` | kShell binding 注册 `WindowOpenService`（仅 Windows） |
| `lib/routes/app_navigation.dart` | Windows 分支走协调器：主窗常规打开也做全局去重前置 |
| `windows/runner/flutter_window.cpp` | RegisterPlugins 后注册 dmw WindowCreatedCallback |
| `pubspec.yaml` / `pubspec.lock` | 加 desktop_multi_window 0.3.1；media_kit_video 改 path 依赖 |

测试新建：`test/multiwindow/kv_box_test.dart`、`window_args_test.dart`、`in_memory_services_test.dart`、`window_open_service_test.dart`；增补 `test/tab_store_test.dart`、`test/follow_service_444_test.dart`。

---

### Task 1: vendor media_kit_video 补丁版并接入 desktop_multi_window

**Files:**
- Create: `simple_live_app/third_party/media_kit_video/`（从 pub cache 复制，非手写）
- Modify: `simple_live_app/pubspec.yaml:59,73-75`
- Modify（生成）: `simple_live_app/pubspec.lock`

**Interfaces:**
- Produces: `package:media_kit_video` 2.0.1 的 hwnd 分派补丁版（`MediaKitVideoPlugin::hwnd_instances_`），`desktop_multi_window 0.3.1` 可用。

- [ ] **Step 1: 复制补丁后的包到 third_party，剔除探针备份**

在 Git Bash 中执行：

```bash
cd /d/project/dart_simple_live/simple_live_app
cp -r "/c/Users/mayi/AppData/Local/Pub/Cache/hosted/pub.dev/media_kit_video-2.0.1" third_party/media_kit_video
find third_party/media_kit_video -name "*.orig-spike" -delete
find third_party/media_kit_video \( -name "*.orig*" -o -name "*spike*" \)
```

最后一条 find 应无输出。确认补丁标记存在（应输出 ≥3）：

```bash
grep -c "hwnd_instances_" third_party/media_kit_video/windows/media_kit_video_plugin.cc third_party/media_kit_video/windows/media_kit_video_plugin.h
```

- [ ] **Step 2: 把探针注释正式化（3 处，用 Edit 工具精确替换）**

vendor 副本来自早期探针，补丁注释仍写着 `SPIKE PATCH`，入仓前改为正式中文注释：

`third_party/media_kit_video/windows/media_kit_video_plugin.h` 第 54 行：

```cpp
  // SPIKE PATCH: per-HWND window proc dispatch for multiple Flutter engines.
```

改为：

```cpp
  // 多引擎支持：按 HWND 分派 WindowProc 到对应插件实例。
```

`third_party/media_kit_video/windows/media_kit_video_plugin.cc` 第 16 行：

```cpp
// SPIKE PATCH
```

改为：

```cpp
// 多引擎支持：HWND → 插件实例分发表。
```

`third_party/media_kit_video/windows/media_kit_video_plugin.cc` 第 79 行：

```cpp
  // SPIKE PATCH: resolve plugin instance by HWND instead of the global instance_.
```

改为：

```cpp
  // 多引擎支持：按 HWND 查找插件实例，替代单实例全局指针。
```

验证无残留：

```bash
grep -rn "SPIKE" third_party/media_kit_video/ || echo "clean"
```

Expected: `clean`。

- [ ] **Step 3: pubspec 加依赖、切换 media_kit_video 为 path 依赖**

`pubspec.yaml` 第 59 行 `window_manager: ^0.5.1` 下方加一行：

```yaml
  desktop_multi_window: 0.3.1 #多窗口（同进程多引擎，仅 Windows）
```

把：

```yaml
  media_kit: ^1.2.2
  media_kit_video: ^2.0.0
  media_kit_libs_video: ^1.0.7
```

改为：

```yaml
  media_kit: ^1.2.2
  # 2.0.1 + hwnd 分派补丁：多引擎下按 HWND 路由 WindowProc，否则第二引擎后主窗卡死。
  # 补丁源文件：third_party/patches/media-kit-video-2.0.1-hwnd-dispatch.patch
  media_kit_video:
    path: third_party/media_kit_video
  media_kit_libs_video: ^1.0.7
```

- [ ] **Step 4: pub get**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat pub get
```

Expected: 成功；`windows/flutter/generated_plugins.cmake` 的 FLUTTER_PLUGIN_LIST 出现 `desktop_multi_window`，`.plugin_symlinks/desktop_multi_window` 生成。

- [ ] **Step 5: Windows 构建冒烟（补丁版插件 + 新插件链接通过）**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug
```

Expected: 构建成功（耗时较长属正常）。若 dmw 头文件找不到，检查 `windows/flutter/generated_plugins.cmake` 是否含 desktop_multi_window（pub get 应自动重新生成，勿手改该文件）。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/third_party/media_kit_video simple_live_app/third_party/patches simple_live_app/pubspec.yaml simple_live_app/pubspec.lock simple_live_app/windows/flutter/generated_plugins.cmake
git commit -m "$(cat <<'EOF'
chore(deps): vendor 补丁版 media_kit_video 2.0.1，接入 desktop_multi_window 0.3.1

media_kit_video 补丁按 HWND 分派 WindowProc，修复同进程第二引擎创建后主窗
消息错路由卡死；补丁源存档 third_party/patches/。dmw 供 M4-1 多窗口使用。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

（`generated_plugins.cmake` 若被 gitignore 则 git add 会报忽略路径，跳过它即可；`third_party/patches` 已在仓则无新增也跳过。）

---

### Task 2: runner 注册 dmw 子引擎插件回调

**Files:**
- Modify: `simple_live_app/windows/runner/flutter_window.cpp`（OnCreate，现有 `RegisterPlugins(flutter_controller_->engine());` 之后）

**Interfaces:**
- Consumes: dmw 头文件 `desktop_multi_window/desktop_multi_window_plugin.h`（Task 1 pub get 后由 plugin symlink 的 include 目录提供，runner 已通过 generated_plugins.cmake 链接 `${plugin}_plugin`，无需改 CMakeLists）。
- Produces: 此后 dmw 原生创建子窗时，子引擎的插件（含 media_kit、window_manager）会被 RegisterPlugins 注册。

- [ ] **Step 1: 加 include**

在 `flutter_window.cpp` 顶部现有 `#include "flutter/generated_plugin_registrant.h"` 一行下方加：

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"
```

- [ ] **Step 2: 在 OnCreate 的 RegisterPlugins 之后注册回调**

现有代码：

```cpp
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
```

改为：

```cpp
  RegisterPlugins(flutter_controller_->engine());
  // desktop_multi_window：子窗由原生创建、子引擎独立，须在回调里为其注册插件；
  // void* 即 flutter::FlutterViewController*（见头文件 typedef）
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *flutter_view_controller =
        reinterpret_cast<flutter::FlutterViewController *>(controller);
    auto *registry = flutter_view_controller->engine();
    RegisterPlugins(registry);
  });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
```

**不要**动同文件的 NativeEditHost（M5 才改为 SetWindowSubclass），不要动 MessageHandler。

- [ ] **Step 3: 构建验证**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug
```

Expected: 成功。

- [ ] **Step 4: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/windows/runner/flutter_window.cpp
git commit -m "$(cat <<'EOF'
feat(windows): runner 注册 desktop_multi_window 子引擎插件回调

子窗引擎创建后由回调 RegisterPlugins，保证 media_kit/window_manager 等
插件在第二引擎可用。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 子窗参数 JSON 编解码（TDD）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/window/window_args.dart`
- Test: `simple_live_app/test/multiwindow/window_args_test.dart`

**Interfaces:**
- Produces（后续任务直接依赖，签名冻结）：
  - `RoomTabArg({required String siteId, required String roomId, String shareUrl = ''})`，三字段同名 getter。
  - `WindowSnapshot({Map<String,dynamic> settings = const {}, List<String> shield = const [], Map<String,double> volumes = const {}, Map<String,String> followShareUrls = const {}})`，四字段同名 getter。
  - `RoomWindowArgs({required List<RoomTabArg> tabs, WindowSnapshot snapshot = const WindowSnapshot()})`；`static const String type = 'room_shell'`；`String encode()`；`factory RoomWindowArgs.decode(String raw)`；`factory RoomWindowArgs.fromJson(Map<String,dynamic>)`。

- [ ] **Step 1: 写失败测试**

创建 `simple_live_app/test/multiwindow/window_args_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';

void main() {
  test('完整快照往返编解码，中文与各类型不丢', () {
    final args = RoomWindowArgs(
      tabs: const [
        RoomTabArg(siteId: 'douyin', roomId: '123456', shareUrl: 'https://live.douyin.com/123456'),
        RoomTabArg(siteId: 'bilibili', roomId: '654321'),
      ],
      snapshot: const WindowSnapshot(
        settings: {
          'kThemeMode': 2,
          'kDanmuEnable': true,
          'kPlayerVolume': 66.5,
          'kName': '弹幕',
        },
        shield: ['垃圾词', 'bad'],
        volumes: {'douyin_123456': 33.0},
        followShareUrls: {'douyin_123456': 'https://live.douyin.com/123456', 'douyin_x': ''},
      ),
    );

    final decoded = RoomWindowArgs.decode(args.encode());

    expect(decoded.tabs.length, 2);
    expect(decoded.tabs[0].siteId, 'douyin');
    expect(decoded.tabs[0].roomId, '123456');
    expect(decoded.tabs[0].shareUrl, 'https://live.douyin.com/123456');
    expect(decoded.tabs[1].shareUrl, '');
    expect(decoded.snapshot.settings['kThemeMode'], 2);
    expect(decoded.snapshot.settings['kDanmuEnable'], true);
    expect(decoded.snapshot.settings['kPlayerVolume'], 66.5);
    expect(decoded.snapshot.settings['kName'], '弹幕');
    expect(decoded.snapshot.shield, ['垃圾词', 'bad']);
    expect(decoded.snapshot.volumes['douyin_123456'], 33.0);
    expect(decoded.snapshot.followShareUrls['douyin_123456'],
        'https://live.douyin.com/123456');
    expect(decoded.snapshot.followShareUrls['douyin_x'], '');
  });

  test('缺省 snapshot 编解码得到空集合', () {
    final decoded = RoomWindowArgs.decode(
      const RoomWindowArgs(tabs: [
        RoomTabArg(siteId: 'huya', roomId: 'r'),
      ]).encode(),
    );
    expect(decoded.snapshot.settings, isEmpty);
    expect(decoded.snapshot.shield, isEmpty);
    expect(decoded.snapshot.volumes, isEmpty);
    expect(decoded.snapshot.followShareUrls, isEmpty);
  });

  test('type 不匹配抛 FormatException', () {
    expect(
      () => RoomWindowArgs.decode('{"type":"other"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart
```

Expected: 编译失败（找不到文件/类）。

- [ ] **Step 3: 实现 window_args.dart**

创建 `simple_live_app/lib/app/multiwindow/window/window_args.dart`：

```dart
import 'dart:convert';

/// 单个待打开的房间（跨窗重建用）
class RoomTabArg {
  const RoomTabArg({
    required this.siteId,
    required this.roomId,
    this.shareUrl = '',
  });

  final String siteId;
  final String roomId;
  final String shareUrl;

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'roomId': roomId,
        'shareUrl': shareUrl,
      };

  factory RoomTabArg.fromJson(Map<String, dynamic> json) => RoomTabArg(
        siteId: json['siteId'] as String,
        roomId: json['roomId'] as String,
        shareUrl: (json['shareUrl'] as String?) ?? '',
      );
}

/// 主引擎 → 子引擎的只读数据快照（M4-1：设置/屏蔽词/音量/关注存在性）
class WindowSnapshot {
  const WindowSnapshot({
    this.settings = const {},
    this.shield = const [],
    this.volumes = const {},
    this.followShareUrls = const {},
  });

  final Map<String, dynamic> settings;
  final List<String> shield;
  final Map<String, double> volumes;

  /// key=siteId_roomId，value=shareUrl（可能为空串，仅用于关注存在性判断）
  final Map<String, String> followShareUrls;

  Map<String, dynamic> toJson() => {
        'settings': settings,
        'shield': shield,
        'volumes': volumes,
        'followShareUrls': followShareUrls,
      };

  factory WindowSnapshot.fromJson(Map<String, dynamic> json) => WindowSnapshot(
        settings:
            Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),
        shield: ((json['shield'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        volumes: ((json['volumes'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
        followShareUrls: ((json['followShareUrls'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
      );
}

/// 子窗启动参数（dmw WindowConfiguration.arguments 承载的 JSON 字符串）
class RoomWindowArgs {
  const RoomWindowArgs({required this.tabs, this.snapshot = const WindowSnapshot()});

  static const String type = 'room_shell';

  final List<RoomTabArg> tabs;
  final WindowSnapshot snapshot;

  Map<String, dynamic> toJson() => {
        'type': type,
        'tabs': tabs.map((e) => e.toJson()).toList(),
        'snapshot': snapshot.toJson(),
      };

  String encode() => jsonEncode(toJson());

  factory RoomWindowArgs.fromJson(Map<String, dynamic> json) {
    if (json['type'] != type) {
      throw FormatException('unknown window args type: ${json['type']}');
    }
    final snapshotJson =
        (json['snapshot'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RoomWindowArgs(
      tabs: ((json['tabs'] as List?) ?? const [])
          .map((e) => RoomTabArg.fromJson(e as Map<String, dynamic>))
          .toList(),
      snapshot: WindowSnapshot.fromJson(snapshotJson),
    );
  }

  factory RoomWindowArgs.decode(String raw) =>
      RoomWindowArgs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart
```

Expected: 3 tests passed。

- [ ] **Step 5: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/window/window_args.dart simple_live_app/test/multiwindow/window_args_test.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 子窗参数 JSON 编解码（房间列表+设置/屏蔽/音量/关注快照）

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: KV 接缝与内存后端，收口两处 Box 直连（TDD）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/bootstrap/kv_box.dart`
- Create: `simple_live_app/lib/app/multiwindow/bootstrap/in_memory_services.dart`
- Modify: `simple_live_app/lib/services/local_storage_service.dart:211-221`
- Modify: `simple_live_app/lib/services/db_service.dart:14-25`（+3 个新方法）
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart:84-92`
- Modify: `simple_live_app/lib/services/follow_service.dart`（构造函数 + onInit/initTimer）
- Test: `simple_live_app/test/multiwindow/kv_box_test.dart`
- Test: `simple_live_app/test/multiwindow/in_memory_services_test.dart`
- Test: `simple_live_app/test/follow_service_444_test.dart`（追加 1 个测试）

**Interfaces:**
- Produces:
  - `abstract class KvBox<T>`：`T? get(Object key, {T? defaultValue})`、`Future<void> put(Object key, T value)`、`Future<void> delete(Object key)`、`bool containsKey(Object key)`、`Iterable<T> get values`、`Iterable<Object> get keys`、`Future<int> clear()`、`Map<Object,T> toMap()`、`Future<void> putAll(Map<Object,T> entries)`；实现 `HiveKvBox<T>`、`MemoryKvBox<T>`。
  - `InMemoryLocalStorageService()`：`void applySnapshot(WindowSnapshot)`；init() 为 no-op。
  - `InMemoryDBService()`：`void applySnapshot(WindowSnapshot)`；override `getFollowExist/getFollowShareUrl/getFollowList/addFollow/updateFollow/deleteFollow`（见代码）。
  - DBService 新增：`String? getFollowShareUrl(String id)`、`Map<String,double> exportVolumes()`、`Map<String,String> exportFollowShareUrls()`。
  - `FollowService({bool enableScheduledRefresh = true})`。
- Consumes: Task 3 的 `WindowSnapshot`。
- 注意：现有所有 box 调用点（sync/history/follow_user/other_settings/webdav 等约 20 处）方法名与 KvBox 完全一致，**不改这些调用点**。

- [ ] **Step 1: 写 KvBox 失败测试**

创建 `simple_live_app/test/multiwindow/kv_box_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';

void main() {
  test('MemoryKvBox 基础读写与默认值', () async {
    final box = MemoryKvBox<String>();
    expect(box.get('a'), isNull);
    expect(box.get('a', defaultValue: 'd'), 'd');
    expect(box.containsKey('a'), isFalse);

    await box.put('a', 'x');
    expect(box.get('a'), 'x');
    expect(box.containsKey('a'), isTrue);
    expect(box.values, ['x']);
    expect(box.keys, ['a']);
    expect(box.toMap(), {'a': 'x'});

    await box.putAll({'b': 'y', 'c': 'z'});
    expect(box.values, ['x', 'y', 'z']);

    final cleared = await box.clear();
    expect(cleared, 3);
    expect(box.values, isEmpty);
  });

  test('MemoryKvBox 支持非字符串键（标签排序用 int 键）', () async {
    final box = MemoryKvBox<String>();
    await box.put(0, '零');
    expect(box.get(0), '零');
    await box.delete(0);
    expect(box.containsKey(0), isFalse);
  });
}
```

- [ ] **Step 2: 运行确认失败**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/kv_box_test.dart
```

Expected: 编译失败（KvBox 不存在）。

- [ ] **Step 3: 实现 kv_box.dart**

创建 `simple_live_app/lib/app/multiwindow/bootstrap/kv_box.dart`：

```dart
import 'package:hive/hive.dart';

/// 同构 KV 存储接缝：生产走 Hive，房间子引擎走纯内存。
///
/// 子引擎与主引擎同进程但属于不同 engine/isolate，重复 open 同一 Hive box
/// 文件会触发文件锁与 TypeAdapter 重复注册，因此子引擎不得接触 Hive。
/// 方法名与 Hive Box 保持一致，调用方无需感知后端。
abstract class KvBox<T> {
  T? get(Object key, {T? defaultValue});
  Future<void> put(Object key, T value);
  Future<void> delete(Object key);
  bool containsKey(Object key);
  Iterable<T> get values;
  Iterable<Object> get keys;
  Future<int> clear();
  Map<Object, T> toMap();
  Future<void> putAll(Map<Object, T> entries);
}

class HiveKvBox<T> implements KvBox<T> {
  HiveKvBox(this.box);

  final Box<T> box;

  @override
  T? get(Object key, {T? defaultValue}) =>
      box.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(Object key, T value) => box.put(key, value);

  @override
  Future<void> delete(Object key) => box.delete(key);

  @override
  bool containsKey(Object key) => box.containsKey(key);

  @override
  Iterable<T> get values => box.values;

  @override
  Iterable<Object> get keys => box.keys.cast<Object>();

  @override
  Future<int> clear() => box.clear();

  @override
  Map<Object, T> toMap() => box.toMap().cast<Object, T>();

  @override
  Future<void> putAll(Map<Object, T> entries) => box.putAll(entries);
}

class MemoryKvBox<T> implements KvBox<T> {
  final Map<Object, T> _map = {};

  @override
  T? get(Object key, {T? defaultValue}) =>
      _map.containsKey(key) ? _map[key] : defaultValue;

  @override
  Future<void> put(Object key, T value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(Object key) async {
    _map.remove(key);
  }

  @override
  bool containsKey(Object key) => _map.containsKey(key);

  @override
  Iterable<T> get values => _map.values;

  @override
  Iterable<Object> get keys => _map.keys;

  @override
  Future<int> clear() async {
    final count = _map.length;
    _map.clear();
    return count;
  }

  @override
  Map<Object, T> toMap() => Map<Object, T>.of(_map);

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    _map.addAll(entries);
  }
}
```

运行测试，Expected: 2 tests passed。

- [ ] **Step 4: LocalStorageService 切接缝**

`lib/services/local_storage_service.dart` 顶部 import 区加：

```dart
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
```

把：

```dart
  late Box settingsBox;
  late Box<String> shieldBox;

  Future init() async {
    settingsBox = await Hive.openBox(
      "LocalStorage",
    );
    shieldBox = await Hive.openBox(
      "DanmuShield",
    );
  }
```

改为：

```dart
  late KvBox<dynamic> settingsBox;
  late KvBox<String> shieldBox;

  Future init() async {
    settingsBox =
        HiveKvBox<dynamic>(await Hive.openBox("LocalStorage"));
    shieldBox =
        HiveKvBox<String>(await Hive.openBox<String>("DanmuShield"));
  }
```

`getValue/setValue/removeValue` 与 app_settings_controller、webdav、other_settings 里的 `.toMap()/.putAll()/.clear()` 全部不用改（KvBox 同名）。

- [ ] **Step 5: DBService 切接缝 + 三个新方法**

`lib/services/db_service.dart` 顶部 import 区加：

```dart
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
```

把：

```dart
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  late Box<double> volumeBox;
  Future init() async {
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    volumeBox = await Hive.openBox("Volume");
    tagBox = await Hive.openBox("FollowUserTag");
  }
```

改为：

```dart
  late KvBox<History> historyBox;
  late KvBox<FollowUser> followBox;
  late KvBox<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  late KvBox<double> volumeBox;
  Future init() async {
    historyBox = HiveKvBox<History>(await Hive.openBox("History"));
    followBox = HiveKvBox<FollowUser>(await Hive.openBox("FollowUser"));
    volumeBox = HiveKvBox<double>(await Hive.openBox("Volume"));
    tagBox =
        HiveKvBox<FollowUserTag>(await Hive.openBox("FollowUserTag"));
  }
```

在 `getFollowList()` 下方加三个方法：

```dart
  /// 关注记录中保存的分享链接；未关注或为空返回 null。
  /// 供直播间构造期同步回填 shareUrl（替代对 followBox 的直连）。
  String? getFollowShareUrl(String id) {
    return followBox.get(id)?.shareUrl;
  }

  /// 导出全部房间音量（跨窗快照用）
  Map<String, double> exportVolumes() {
    return {
      for (final key in volumeBox.keys)
        key.toString(): volumeBox.get(key) ?? 70,
    };
  }

  /// 导出关注房间 id → shareUrl（含空串，空串也代表“已关注”）
  Map<String, String> exportFollowShareUrls() {
    return {
      for (final follow in followBox.values) follow.id: follow.shareUrl,
    };
  }
```

- [ ] **Step 6: LiveRoomController 去掉 followBox 直连**

`lib/modules/live_room/live_room_controller.dart` 的 `hydrateShareUrlFromFollow` 整个方法改为：

```dart
  void hydrateShareUrlFromFollow() {
    if (shareUrl.isNotEmpty) {
      return;
    }
    final followShareUrl =
        DBService.instance.getFollowShareUrl("${site.id}_$roomId");
    if (followShareUrl != null && followShareUrl.isNotEmpty) {
      rxShareUrl.value = followShareUrl;
    }
  }
```

- [ ] **Step 7: FollowService 定时刷新开关**

`lib/services/follow_service.dart`：类名行下方加构造参数与字段：

```dart
class FollowService extends GetxService with WidgetsBindingObserver {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  /// 子引擎（房间子窗）注入 false：不启动任何定时网络刷新，
  /// 关注列表只来自启动快照
  FollowService({this.enableScheduledRefresh = true});

  final bool enableScheduledRefresh;
```

`initTimer()` 方法开头加守卫：

```dart
  void initTimer() {
    if (!enableScheduledRefresh) {
      updateTimer?.cancel();
      updateTimer = null;
      return;
    }
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
```

（其后内容不动。）

- [ ] **Step 8: 写内存后端测试（含 FollowService 开关）**

创建 `simple_live_app/test/multiwindow/in_memory_services_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/db_service.dart';

void main() {
  test('InMemoryLocalStorageService：快照播种后设置与屏蔽词可读', () {
    final storage = InMemoryLocalStorageService();
    storage.applySnapshot(const WindowSnapshot(
      settings: {'kThemeMode': 2, 'kDanmuEnable': false, 'kName': '弹幕'},
      shield: ['垃圾词', 'bad'],
    ));

    expect(storage.getValue('kThemeMode', 0), 2);
    expect(storage.getValue('kDanmuEnable', true), false);
    expect(storage.getValue('kName', ''), '弹幕');
    expect(storage.getValue('kMissing', '默认'), '默认');
    expect(storage.shieldBox.values.toSet(), {'垃圾词', 'bad'});
  });

  test('InMemoryDBService：音量/关注快照、默认音量、空关注列表', () {
    final db = InMemoryDBService();
    db.applySnapshot(const WindowSnapshot(
      volumes: {'douyin_1': 33.0},
      followShareUrls: {'douyin_1': 'http://x', 'douyin_2': ''},
    ));

    expect(db.getVolume('douyin_1'), 33.0);
    expect(db.getVolume('unknown'), 70);
    expect(db.getFollowExist('douyin_1'), isTrue);
    expect(db.getFollowExist('douyin_2'), isTrue, reason: '空 shareUrl 也代表已关注');
    expect(db.getFollowExist('douyin_3'), isFalse);
    expect(db.getFollowShareUrl('douyin_1'), 'http://x');
    expect(db.getFollowShareUrl('douyin_2'), '');
    expect(db.getFollowList(), isEmpty, reason: '子窗不承载完整关注对象');
  });

  test('InMemoryDBService：子窗内关注写操作只在本窗生效，不触碰 Hive', () async {
    final db = InMemoryDBService();
    await db.addFollow(FollowUser(
      id: 'bili_9',
      roomId: '9',
      siteId: 'bili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://9',
    ));
    expect(db.getFollowExist('bili_9'), isTrue);
    await db.deleteFollow('bili_9');
    expect(db.getFollowExist('bili_9'), isFalse);
    // 历史写入内存不报错、不持久化
    await db.addOrUpdateVolume('huya_r', 12.5);
    expect(db.getVolume('huya_r'), 12.5);
  });
}
```

在 `test/follow_service_444_test.dart` 的 `main()` 内末尾（最后一个 test 之后）追加：

```dart
  test('enableScheduledRefresh=false：initTimer 不创建定时刷新', () {
    AppSettingsController.instance.autoUpdateFollowEnable.value = true;

    final disabled = FollowService(enableScheduledRefresh: false);
    disabled.initTimer();
    expect(disabled.updateTimer, isNull);

    final enabled = FollowService();
    enabled.initTimer();
    expect(enabled.updateTimer, isNotNull);
    enabled.updateTimer?.cancel();
  });
```

（该文件 setUp 已提供真实 Hive LocalStorage + AppSettingsController；直接测 `initTimer()` 单元，不经 onInit，避免 WidgetsBinding/EventBus 与残留周期定时器。）

- [ ] **Step 9: 实现 in_memory_services.dart 让测试通过**

创建 `simple_live_app/lib/app/multiwindow/bootstrap/in_memory_services.dart`：

```dart
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 子引擎专用：纯内存 LocalStorage，按启动快照播种，init() 不打开 Hive
class InMemoryLocalStorageService extends LocalStorageService {
  InMemoryLocalStorageService() {
    settingsBox = MemoryKvBox<dynamic>();
    shieldBox = MemoryKvBox<String>();
  }

  @override
  Future<void> init() async {}

  void applySnapshot(WindowSnapshot snapshot) {
    for (final entry in snapshot.settings.entries) {
      settingsBox.put(entry.key, entry.value);
    }
    for (final word in snapshot.shield) {
      shieldBox.put(word, word);
    }
  }
}

/// 子引擎专用：关注只保留 id→shareUrl 映射（无完整 FollowUser），
/// 音量/标签/历史走内存 box，进程结束即丢弃
class InMemoryDBService extends DBService {
  InMemoryDBService() {
    historyBox = MemoryKvBox<History>();
    followBox = MemoryKvBox<FollowUser>();
    tagBox = MemoryKvBox<FollowUserTag>();
    volumeBox = MemoryKvBox<double>();
  }

  @override
  Future<void> init() async {}

  final Map<String, String> _followShareUrls = {};

  void applySnapshot(WindowSnapshot snapshot) {
    snapshot.volumes.forEach(volumeBox.put);
    _followShareUrls.addAll(snapshot.followShareUrls);
  }

  @override
  bool getFollowExist(String id) => _followShareUrls.containsKey(id);

  @override
  String? getFollowShareUrl(String id) => _followShareUrls[id];

  @override
  List<FollowUser> getFollowList() => const [];

  @override
  Future<void> addFollow(FollowUser follow) async {
    // 与生产逻辑一致：不覆盖已有有效 shareUrl
    final existing = _followShareUrls[follow.id];
    final share = (existing != null &&
            existing.isNotEmpty &&
            follow.shareUrl.isEmpty)
        ? existing
        : follow.shareUrl;
    _followShareUrls[follow.id] = share;
  }

  @override
  Future<void> updateFollow(FollowUser follow) => addFollow(follow);

  @override
  Future<void> deleteFollow(String id) async {
    _followShareUrls.remove(id);
  }
}
```

- [ ] **Step 10: 跑新测试 + 全量回归**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/kv_box_test.dart test/multiwindow/in_memory_services_test.dart test/follow_service_444_test.dart
C:/tools/flutter347/flutter/bin/flutter.bat test
```

Expected: 新增全过；全量 167+ 用例全绿（接缝改造不得影响主引擎行为）。

- [ ] **Step 11: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/bootstrap/kv_box.dart simple_live_app/lib/app/multiwindow/bootstrap/in_memory_services.dart simple_live_app/lib/services/local_storage_service.dart simple_live_app/lib/services/db_service.dart simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/lib/services/follow_service.dart simple_live_app/test/multiwindow/kv_box_test.dart simple_live_app/test/multiwindow/in_memory_services_test.dart simple_live_app/test/follow_service_444_test.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): KV 存储接缝与内存后端，子引擎免 Hive 启动

LocalStorage/DB 的 Box 字段切到同名 KvBox 接缝（生产仍 Hive）；新增
getFollowShareUrl/export* 快照方法并收口 LiveRoomController 的 followBox
直连；FollowService 支持关闭定时刷新供子引擎使用。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 窗口注册表、端口抽象与开窗协调者（TDD）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/window/sub_window_port.dart`
- Create: `simple_live_app/lib/app/multiwindow/window/dmw_sub_window_port.dart`
- Create: `simple_live_app/lib/app/multiwindow/window/window_registry.dart`
- Create: `simple_live_app/lib/app/multiwindow/window/window_open_service.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_store.dart`（+2 方法）
- Test: `simple_live_app/test/multiwindow/window_open_service_test.dart`
- Test: `simple_live_app/test/tab_store_test.dart`（追加 1 个测试）

**Interfaces:**
- Consumes: `TabOpenRequest({required siteId, required roomId, shareUrl})`、`String get key => "${siteId}_$roomId"`；`TabStore.open/close/tabs`；Task 3 快照类型；Task 4 内存服务。
- Produces:
  - `SubWindowPort`：`Future<SubWindowHandle> createRoomWindow(String argumentsJson)`、`Future<void> invoke(String windowId, String method, Object? arguments)`、`Future<List<String>> listWindowIds()`、`Stream<void> get windowsChanged`；`SubWindowHandle(String windowId)`。
  - `DmwSubWindowPort implements SubWindowPort`；`static WindowController? mainController`、`static String? get mainWindowId`、`static void attachMain(WindowController)`。
  - `WindowRegistry({required String mainWindowId})`：`void registerChild(String windowId, Set<String> tabKeys)`、`String? windowForTab(String tabKey)`、`void reconcile(Iterable<String> aliveWindowIds)`、`Set<String> tabsOf(String)`、`int get childCount`、`List<String> get childWindowIds`。
  - `WindowOpenService extends GetxService`：构造 `({required SubWindowPort port, required TabStore store, required WindowRegistry registry})`；`Future<void> openInNewWindow(TabOpenRequest)`（卡片「新窗口打开」）、`Future<void> openLocallyWithGlobalDedup(TabOpenRequest, {bool background = false})`（主窗常规入口的全局去重前置）、`Future<void> moveTabToNewWindow(String tabId)`、`Future<void> requestCloseAllChildren()`、`int get childWindowCount`、`static WindowOpenService get instance`。
  - `TabStore.findbyKey(String)` / `TabStore.activateByKey(String)`。

- [ ] **Step 1: TabStore 增补两方法（先测试）**

在 `test/tab_store_test.dart` 的 `main()` 末尾追加：

```dart
  test('findByKey 与 activateByKey（跨窗置前用）', () {
    final t1 = store.open(req('douyin', 'r1'));
    final t2 = store.open(req('douyin', 'r2'));
    store.activate(t2.tabId);
    expect(store.activeTabId.value, t2.tabId);

    store.activateByKey('douyin_r1');
    expect(store.activeTabId.value, t1.tabId);
    expect(store.findByKey('douyin_r1')?.tabId, t1.tabId);
    expect(store.findByKey('douyin_missing'), isNull);
    store.activateByKey('douyin_missing');
    expect(store.activeTabId.value, t1.tabId, reason: '未命中不改变激活态');
  });
```

运行确认失败，然后在 `lib/app/multiwindow/shell/tab_store.dart` 的 `activateHome()` 下方加：

```dart
  /// 按 siteId_roomId 查找标签（跨窗全局去重用）
  TabDescriptor? findByKey(String key) =>
      tabs.firstWhereOrNull((t) => t.request.key == key);

  /// 跨窗 IPC 置前：按 siteId_roomId 激活本窗标签
  void activateByKey(String key) {
    final tab = findByKey(key);
    if (tab != null) {
      activeTabId.value = tab.tabId;
    }
  }
```

- [ ] **Step 2: 端口抽象与 dmw 实现**

创建 `sub_window_port.dart`：

```dart
/// 子窗操作能力抽象：生产用 dmw，单测用内存 fake
abstract class SubWindowPort {
  Future<SubWindowHandle> createRoomWindow(String argumentsJson);
  Future<void> invoke(String windowId, String method, Object? arguments);
  Future<List<String>> listWindowIds();
  Stream<void> get windowsChanged;
}

class SubWindowHandle {
  const SubWindowHandle(this.windowId);
  final String windowId;
}
```

创建 `dmw_sub_window_port.dart`：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';

import 'sub_window_port.dart';

class DmwSubWindowPort implements SubWindowPort {
  /// 主引擎自己的 controller（main() 分发时挂载）；kShell binding 据此
  /// 构造 WindowRegistry
  static WindowController? mainController;

  static String? get mainWindowId => mainController?.windowId;

  static void attachMain(WindowController controller) {
    mainController = controller;
  }

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final controller = await WindowController.create(
      WindowConfiguration(arguments: argumentsJson, hiddenAtLaunch: true),
    );
    return SubWindowHandle(controller.windowId);
  }

  @override
  Future<void> invoke(
      String windowId, String method, Object? arguments) async {
    await WindowController.fromWindowId(windowId)
        .invokeMethod(method, arguments);
  }

  @override
  Future<List<String>> listWindowIds() async {
    final all = await WindowController.getAll();
    return all.map((e) => e.windowId).toList();
  }

  @override
  Stream<void> get windowsChanged => onWindowsChanged;
}
```

- [ ] **Step 3: 写注册表 + 协调者失败测试**

创建 `test/multiwindow/window_open_service_test.dart`：

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

TabOpenRequest req(String site, String room, [String share = '']) =>
    TabOpenRequest(siteId: site, roomId: room, shareUrl: share);

class FakeRegistry implements RoomControllerRegistry {
  final registered = <String, TabOpenRequest>{};
  @override
  void register(String tabId, TabOpenRequest request) =>
      registered[tabId] = request;
  @override
  void unregister(String tabId) => registered.remove(tabId);
  @override
  bool isRegistered(String tabId) => registered.containsKey(tabId);
}

class FakeSubWindowPort implements SubWindowPort {
  final Map<String, String> created = {};
  final List<(String, String, Object?)> invocations = [];
  final List<String> alive = ['main'];
  final StreamController<void> changedController =
      StreamController<void>.broadcast();
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    final id = 'w${++_seq}';
    created[id] = argumentsJson;
    alive.add(id);
    return SubWindowHandle(id);
  }

  @override
  Future<void> invoke(String windowId, String method, Object? arguments) async {
    invocations.add((windowId, method, arguments));
  }

  @override
  Future<List<String>> listWindowIds() async => List<String>.of(alive);

  @override
  Stream<void> get windowsChanged => changedController.stream;
}

void main() {
  late FakeSubWindowPort port;
  late TabStore store;
  late WindowRegistry registry;
  late WindowOpenService service;

  setUp(() {
    Get.put<LocalStorageService>(InMemoryLocalStorageService(), permanent: true);
    Get.put<DBService>(InMemoryDBService(), permanent: true);
    port = FakeSubWindowPort();
    store = TabStore(registry: FakeRegistry());
    registry = WindowRegistry(mainWindowId: 'main');
    service = WindowOpenService(port: port, store: store, registry: registry);
    service.onInit();
  });

  tearDown(() async {
    service.onClose();
    await Get.reset();
  });

  test('WindowRegistry：登记/查询/对账', () {
    registry.registerChild('w1', {'douyin_a'});
    registry.registerChild('w2', {'douyin_b', 'bili_c'});
    expect(registry.childCount, 2);
    expect(registry.childWindowIds, ['w1', 'w2']);
    expect(registry.windowForTab('douyin_b'), 'w2');
    expect(registry.windowForTab('douyin_x'), isNull);
    expect(registry.tabsOf('w1'), {'douyin_a'});

    registry.reconcile(['main', 'w2']);
    expect(registry.childCount, 1);
    expect(registry.windowForTab('douyin_a'), isNull);
  });

  test('卡片新窗口：全新房间创建子窗，参数为 room_shell JSON', () async {
    await service.openInNewWindow(req('douyin', 'a', 'http://a'));

    expect(port.created.length, 1);
    final args = RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.siteId, 'douyin');
    expect(args.tabs.single.roomId, 'a');
    expect(registry.childCount, 1);
  });

  test('全局去重：主窗已有的 key 只激活标签，不建窗', () async {
    final tab = store.open(req('douyin', 'a'));
    store.activateHome();
    await service.openInNewWindow(req('douyin', 'a', 'http://a'));

    expect(port.created, isEmpty);
    expect(store.activeTabId.value, tab.tabId);
  });

  test('全局去重：子窗已有的 key 置前该窗并 IPC 激活，不建第二窗', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    await service.openInNewWindow(req('douyin', 'a'));

    expect(port.created.length, 1);
    expect(port.invocations, contains(('w1', 'focus_tab', 'douyin_a')));
  });

  test('移到新窗口：创建子窗后关闭本窗标签', () async {
    final tab = store.open(req('douyin', 'a', 'http://a'));
    await service.moveTabToNewWindow(tab.tabId);

    expect(port.created.length, 1);
    final args = RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.shareUrl, 'http://a');
    expect(store.tabs, isEmpty);
  });

  test('onWindowsChanged：窗口消失后注册表自动对账摘除', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    expect(registry.childCount, 1);

    port.alive.remove('w1');
    port.changedController.add(null);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(registry.childCount, 0);
    expect(registry.windowForTab('douyin_a'), isNull);
  });

  test('requestCloseAllChildren：对每个子窗发 close_window，单点失败不阻断', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    await service.openInNewWindow(req('douyin', 'b'));
    await service.requestCloseAllChildren();

    expect(
      port.invocations,
      containsAll([('w1', 'close_window', null), ('w2', 'close_window', null)]),
    );
  });

  test('常规打开：本窗无重复时按 background 语义开主窗标签', () async {
    await service.openLocallyWithGlobalDedup(req('douyin', 'a'),
        background: true);
    expect(store.tabs.length, 1);
    expect(store.activeTabId.value, isNull, reason: '后台打开不激活');

    await service.openLocallyWithGlobalDedup(req('douyin', 'b'));
    expect(store.tabs.length, 2);
    expect(store.activeTabId.value, store.tabs.last.tabId);
  });

  test('常规打开命中子窗已有房间：只 IPC 置前，主窗不新增标签', () async {
    await service.openInNewWindow(req('douyin', 'a'));
    port.invocations.clear();

    await service.openLocallyWithGlobalDedup(req('douyin', 'a'),
        background: true);
    expect(port.invocations, contains(('w1', 'focus_tab', 'douyin_a')));
    expect(store.tabs, isEmpty);
  });

  test('常规打开命中主窗已有标签：不发 IPC，并激活该标签', () async {
    final tab = store.open(req('douyin', 'a'), activate: false);
    store.activateHome();

    await service.openLocallyWithGlobalDedup(req('douyin', 'a'));
    expect(port.invocations, isEmpty);
    expect(store.activeTabId.value, tab.tabId);
  });

  test('快照剥离登录凭据/guard 配置，保留外观播放设置与屏蔽词', () {
    final storage =
        Get.find<LocalStorageService>() as InMemoryLocalStorageService;
    storage.settingsBox.put('DouyinLoginCookie', 'sessionid=secret');
    storage.settingsBox.put('DouyinCookie', 'ttwid=x');
    storage.settingsBox.put('GuardServerUrl', 'http://guard');
    storage.settingsBox.put('GuardServerToken', 'tok');
    storage.settingsBox.put('GuardAccountId_douyin', 'acct1');
    storage.settingsBox.put('BilibiliCookie', 'sess=b');
    storage.settingsBox.put('DouyuLoginPassword', 'pw');
    storage.settingsBox.put('kWebDAVPassword', 'wp');
    storage.settingsBox.put('ThemeMode', 2);
    storage.settingsBox.put('DanmuEnable', true);
    storage.settingsBox.put('PlayerVolume', 66.0);
    storage.shieldBox.put('垃圾词', '垃圾词');

    final args = WindowSnapshotBuilder.build([req('douyin', 'a')]);

    expect(args.snapshot.settings, containsPair('ThemeMode', 2));
    expect(args.snapshot.settings, containsPair('DanmuEnable', true));
    expect(args.snapshot.settings, containsPair('PlayerVolume', 66.0));
    for (final key in [
      'DouyinLoginCookie',
      'DouyinCookie',
      'GuardServerUrl',
      'GuardServerToken',
      'BilibiliCookie',
      'DouyuLoginPassword',
      'kWebDAVPassword',
    ]) {
      expect(args.snapshot.settings, isNot(contains(key)),
          reason: '$key 不得跨窗传播');
    }
    expect(
      args.snapshot.settings.keys
          .any((k) => k.startsWith('GuardAccountId_')),
      isFalse,
    );
    expect(args.snapshot.shield, contains('垃圾词'));
  });
}
```

运行确认失败（类不存在）。

- [ ] **Step 4: 实现 WindowRegistry**

创建 `window_registry.dart`：

```dart
/// 主引擎持有的子窗注册表：windowId → 该窗承载的 tab keys。
/// 纯内存逻辑，不碰 dmw，便于单测。主窗自身标签不在此表（归 TabStore）。
class WindowRegistry {
  WindowRegistry({required this.mainWindowId});

  final String mainWindowId;
  final Map<String, Set<String>> _childTabs = {};

  /// 打开顺序，关闭联动时按序通知
  final List<String> _order = [];

  int get childCount => _childTabs.length;
  List<String> get childWindowIds => List<String>.unmodifiable(_order);

  void registerChild(String windowId, Set<String> tabKeys) {
    if (!_childTabs.containsKey(windowId)) {
      _order.add(windowId);
    }
    _childTabs[windowId] = <String>{...tabKeys};
  }

  Set<String> tabsOf(String windowId) => {
        ...?_childTabs[windowId],
      };

  /// tabKey（siteId_roomId）所在子窗；主窗标签由调用方先查 TabStore
  String? windowForTab(String tabKey) {
    for (final entry in _childTabs.entries) {
      if (entry.value.contains(tabKey)) return entry.key;
    }
    return null;
  }

  /// onWindowsChanged 后按存活窗口列表对账，摘除已关闭窗口
  void reconcile(Iterable<String> aliveWindowIds) {
    final alive = aliveWindowIds.toSet();
    _childTabs.removeWhere((id, _) => !alive.contains(id));
    _order.removeWhere((id) => !_childTabs.containsKey(id));
  }
}
```

- [ ] **Step 5: 实现 WindowOpenService + WindowSnapshotBuilder**

创建 `window_open_service.dart`：

```dart
import 'dart:async';

import 'package:collection/collection.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'sub_window_port.dart';
import 'window_args.dart';
import 'window_registry.dart';

/// 从主引擎当前 Hive 数据构造子窗只读快照
class WindowSnapshotBuilder {
  /// 禁止跨窗传播的键：各平台登录凭据、guard 服务配置/账号、WebDAV 与
  /// 局域网同步信息。M4-1 子窗固定游客态：若带入抖音登录 cookie，子引擎
  /// DouyinAccountService.onInit 会判定 logined=true；带入 GuardServerUrl
  /// 会使 GuardServerService.configured=true——均破坏游客态假设。
  static const Set<String> sensitiveKeys = {
    'BilibiliCookie',
    'DouyinCookie',
    'DouyinLoginCookie',
    'GuardServerUrl',
    'GuardServerToken',
    'DouyuCookie',
    'DouyuLoginAccount',
    'DouyuLoginPassword',
    'HuyaCookie',
    'TwitchClientId',
    'TwitchToken',
    'TwitchUserLogin',
    'WebDAVUri',
    'WebDAVUser',
    'kWebDAVPassword',
    'userName',
    'syncUrl',
  };

  /// 敏感键前缀（guard 账号 id 按平台存多份）
  static const String sensitivePrefix = 'GuardAccountId_';

  static bool isSensitiveKey(String key) =>
      sensitiveKeys.contains(key) || key.startsWith(sensitivePrefix);

  static RoomWindowArgs build(List<TabOpenRequest> requests) {
    final storage = LocalStorageService.instance;
    final db = DBService.instance;

    final settings = <String, dynamic>{};
    for (final entry in storage.settingsBox.toMap().entries) {
      final key = entry.key.toString();
      if (isSensitiveKey(key)) continue;
      final value = entry.value;
      // IPC/JSON 只接受基础类型；LocalStorage 现存值均为 num/String/bool
      if (value == null ||
          value is num ||
          value is String ||
          value is bool) {
        settings[key] = value;
      }
    }

    return RoomWindowArgs(
      tabs: [
        for (final request in requests)
          RoomTabArg(
            siteId: request.siteId,
            roomId: request.roomId,
            shareUrl: request.shareUrl,
          ),
      ],
      snapshot: WindowSnapshot(
        settings: settings,
        shield: storage.shieldBox.values.toList(),
        volumes: db.exportVolumes(),
        followShareUrls: db.exportFollowShareUrls(),
      ),
    );
  }
}

/// 主引擎开窗协调者：全局去重前置、开窗登记、子窗存活对账与联动关闭
class WindowOpenService extends GetxService {
  WindowOpenService({
    required this.port,
    required this.store,
    required this.registry,
  });

  static WindowOpenService get instance => Get.find<WindowOpenService>();

  final SubWindowPort port;
  final TabStore store;
  final WindowRegistry registry;

  StreamSubscription<void>? _windowsChangedSub;

  @override
  void onInit() {
    super.onInit();
    _windowsChangedSub = port.windowsChanged.listen((_) async {
      try {
        registry.reconcile(await port.listWindowIds());
      } catch (_) {
        // 对账失败等下一事件自愈，不影响开窗主流程
      }
    });
  }

  @override
  void onClose() {
    unawaited(_windowsChangedSub?.cancel());
    _windowsChangedSub = null;
    super.onClose();
  }

  /// 卡片「新窗口打开」：主窗已有→激活；子窗已有→IPC 置前；否则新建
  Future<void> openInNewWindow(TabOpenRequest request) async {
    if (store.findByKey(request.key) != null) {
      store.open(request);
      return;
    }
    final existingWindow = registry.windowForTab(request.key);
    if (existingWindow != null) {
      await port.invoke(existingWindow, 'focus_tab', request.key);
      return;
    }
    final handle = await port.createRoomWindow(
      WindowSnapshotBuilder.build([request]).encode(),
    );
    registry.registerChild(handle.windowId, {request.key});
  }

  /// 主窗常规入口（首页/卡片进房、右键后台标签）：全局去重前置。
  /// 房间已在某子窗 → IPC 置前该子窗；否则在主窗按 background 语义开/激活。
  Future<void> openLocallyWithGlobalDedup(
    TabOpenRequest request, {
    bool background = false,
  }) async {
    if (store.findByKey(request.key) == null) {
      final existingWindow = registry.windowForTab(request.key);
      if (existingWindow != null) {
        await port.invoke(existingWindow, 'focus_tab', request.key);
        return;
      }
    }
    store.open(request, activate: !background);
  }

  /// 标签右键「移到新窗口」。M4-1 前置条件：游客态
  /// （账号态由 UI 置灰，不进入此方法）。快照重建：先开新窗再关本标签。
  Future<void> moveTabToNewWindow(String tabId) async {
    final descriptor =
        store.tabs.firstWhereOrNull((tab) => tab.tabId == tabId);
    if (descriptor == null) return;
    final request = descriptor.request;
    final handle = await port.createRoomWindow(
      WindowSnapshotBuilder.build([request]).encode(),
    );
    registry.registerChild(handle.windowId, {request.key});
    store.close(tabId);
  }

  int get childWindowCount => registry.childCount;

  /// 主窗关闭前尽力联动关闭所有子窗；单个失败不阻断退出
  Future<void> requestCloseAllChildren() async {
    for (final windowId in registry.childWindowIds) {
      try {
        await port.invoke(windowId, 'close_window', null);
      } catch (_) {}
    }
  }
}
```

- [ ] **Step 6: 跑测试与静态检查**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_open_service_test.dart test/tab_store_test.dart
C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test
```

Expected: 测试全过；analyze 无新增告警。

- [ ] **Step 7: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/window/sub_window_port.dart simple_live_app/lib/app/multiwindow/window/dmw_sub_window_port.dart simple_live_app/lib/app/multiwindow/window/window_registry.dart simple_live_app/lib/app/multiwindow/window/window_open_service.dart simple_live_app/lib/app/multiwindow/shell/tab_store.dart simple_live_app/test/multiwindow/window_open_service_test.dart simple_live_app/test/tab_store_test.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 窗口注册表与开窗协调者——全局去重前置/存活对账/联动关闭

SubWindowPort 抽象 dmw 能力便于单测；TabStore 增按 key 查询/置前；
快照构建器从主引擎 Hive 抽取设置/屏蔽/音量/关注。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: 主/子引擎启动分发与子窗壳页面

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/window/window_role.dart`
- Create: `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`
- Modify: `simple_live_app/lib/main.dart:47-68`
- Modify: `simple_live_app/lib/app/multiwindow/shell/room_shell_page.dart`（整文件改）

**Interfaces:**
- Consumes: Task 1-5 全部产物；`RoomShellPage({bool isSubWindow = false})`；`MyApp({bool isSubWindow = false})`（本任务给 MyApp 加此参数，子窗复用整个 App 骨架：侧键关标签、ESC 退全屏、SmartDialog、logWriter、动态取色）。
- Produces: 子引擎能以无首页壳启动、按快照进房、响应 focus_tab/close_window IPC；主窗关闭走联动文案。

- [ ] **Step 1: 引擎角色与子窗命令挂载点**

创建 `window_role.dart`：

```dart
/// 当前 engine 角色：主引擎 false（默认），房间子引擎 true。
/// 纯 Dart 静态位，由 main() 分发时在子引擎置位。
class MultiWindowRole {
  static bool isSubWindow = false;
}

/// 主引擎 IPC → 子窗壳的命令挂载点。
/// close_window 具体动作（关播放器、防重复、close 窗口）由 RoomShellPage
/// 在 initState 注册，引导期/IPC 处理器不持有 widget 上下文。
class SubWindowCommands {
  static Future<void> Function()? closeRequested;
}
```

- [ ] **Step 2: main.dart 主/子分发 + MyApp 参数化**

`lib/main.dart` 顶部 import 区加（`dart:io` 已存在）：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/sub_engine_bootstrap.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_shell_page.dart';
import 'package:simple_live_app/app/multiwindow/window/dmw_sub_window_port.dart';
```

把现有 `void main() async { ... }`（47-68 行，到 `runApp(const MyApp());` 为止）替换为：

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    // 主窗 arguments 为空串；子窗为 RoomWindowArgs JSON
    final self = await WindowController.fromCurrentEngine();
    if (self.arguments.isNotEmpty) {
      await runSubEngine(self);
      return;
    }
    DmwSubWindowPort.attachMain(self);
  }
  await runMainEngine();
}

Future<void> runMainEngine() async {
  await migrateData();
  await initWindow();
  MediaKit.ensureInitialized();
  await Hive.initFlutter(
    (!Platform.isAndroid && !Platform.isIOS)
        ? (await getApplicationSupportDirectory()).path
        : null,
  );
  //初始化服务
  await initServices();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  //设置状态栏为透明
  SystemUiOverlayStyle systemUiOverlayStyle = const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarColor: Colors.transparent,
  );
  SystemChrome.setSystemUIOverlayStyle(systemUiOverlayStyle);
  runApp(const MyApp());
}
```

给 MyApp 加子窗参数。现有：

```dart
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
```

改为：

```dart
class MyApp extends StatelessWidget {
  const MyApp({super.key, this.isSubWindow = false});

  /// 房间子引擎：以 home 直挂 RoomShellPage，不经 kShell binding
  /// （避免重复注册 presence 网关/IndexedController）；其余 App 行为与主窗一致
  final bool isSubWindow;

  @override
  Widget build(BuildContext context) {
```

`GetMaterialApp` 的 initialRoute/getPages 两个参数：

```dart
        initialRoute:
            Platform.isWindows ? RoutePath.kShell : RoutePath.kIndex,
        getPages: AppPages.routes,
```

改为：

```dart
        if (isSubWindow)
          home: const RoomShellPage(isSubWindow: true)
        else
          initialRoute:
              Platform.isWindows ? RoutePath.kShell : RoutePath.kIndex,
        getPages: AppPages.routes,
```

（home 与 getPages 可共存；路由表保留给子窗内可能触发的深路由。migrateData/initWindow/initServices 等其余内容一律不动。）

- [ ] **Step 3: 实现子引擎引导**

创建 `sub_engine_bootstrap.dart`（不另写 App 骨架——runApp 复用参数化后的
`MyApp(isSubWindow: true)`，侧键关标签、ESC 退全屏、SmartDialog、logWriter、
动态取色等行为与主窗一致）：

```dart
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';

import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/shell/getx_room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/main.dart' show MyApp;
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';

import 'in_memory_services.dart';

/// 房间子引擎入口：精简服务集，无 Hive / presence 网关 / Sync / Update /
/// IndexedController；只读快照 + 内存后端，五个账号服务空凭据游客态进房。
Future<void> runSubEngine(WindowController self) async {
  final RoomWindowArgs args;
  try {
    args = RoomWindowArgs.decode(self.arguments);
  } catch (e, st) {
    Log.logPrint(e);
    Log.logPrint(st);
    await windowManager.ensureInitialized();
    await windowManager.close();
    return;
  }

  MultiWindowRole.isSubWindow = true;
  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  // 原生建窗时为 800x600 空标题且 hiddenAtLaunch，由 window_manager 接管外观
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1200, 720),
      minimumSize: Size(360, 400),
      center: true,
      title: 'Simple Live',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  // —— 内存后端（必须先于一切服务）——
  final storage = InMemoryLocalStorageService();
  storage.applySnapshot(args.snapshot);
  Get.put<LocalStorageService>(storage, permanent: true);
  final db = InMemoryDBService();
  db.applySnapshot(args.snapshot);
  Get.put<DBService>(db, permanent: true);

  // —— 最小服务集 ——
  Get.put(AppSettingsController(), permanent: true);
  // configured=false：不联网、不 rehydrate、不绑 htmlFetcher
  Get.put(GuardServerService(), permanent: true);
  // 空 cookie：logined=false，纯游客
  Get.put(DouyinAccountService(), permanent: true);
  // 其余四平台账号服务也必须注册：斗鱼 loadData() 进房路径直查
  // DouyuAccountService（live_room_controller.dart:1435），弹幕登录态
  // getter danmakuLogined（:1237）构建期遍历五服务；快照已剥离全部
  // cookie/token，onInit 纯本地读 KV、无网络/定时器，注册即天然游客态
  Get.put(BiliBiliAccountService(), permanent: true);
  Get.put(DouyuAccountService(), permanent: true);
  Get.put(HuyaAccountService(), permanent: true);
  Get.put(TwitchAccountService(), permanent: true);
  // 不起定时刷新、不跑状态查询网络
  Get.put(FollowService(enableScheduledRefresh: false), permanent: true);

  // —— 标签壳（无首页、无 presence 网关）——
  Get.put<RoomControllerRegistry>(GetxRoomControllerRegistry(),
      permanent: true);
  final store = Get.put<TabStore>(
    TabStore(
      registry: Get.find<RoomControllerRegistry>(),
      hasHome: false,
    ),
    permanent: true,
  );

  for (final tab in args.tabs) {
    try {
      store.open(
        TabOpenRequest(
          siteId: tab.siteId,
          roomId: tab.roomId,
          shareUrl: tab.shareUrl,
        ),
      );
    } catch (e, st) {
      Log.logPrint('子窗打开标签失败：${tab.siteId}/${tab.roomId}');
      Log.logPrint(e);
      Log.logPrint(st);
    }
  }
  if (store.tabs.isEmpty) {
    await windowManager.close();
    return;
  }

  // —— 跨窗 IPC（handler 只能挂在本 engine 自己的 controller 上）——
  self.setWindowMethodHandler((call) async {
    switch (call.method) {
      case 'focus_tab':
        await windowManager.show();
        await windowManager.focus();
        store.activateByKey(call.arguments as String);
        return true;
      case 'close_window':
        final closer = SubWindowCommands.closeRequested;
        if (closer != null) {
          await closer();
        }
        return true;
      default:
        return null;
    }
  });

  runApp(const MyApp(isSubWindow: true));
}
```

- [ ] **Step 4: 壳页面支持子窗变体（整文件替换）**

用以下内容整体替换 `lib/app/multiwindow/shell/room_shell_page.dart`：

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_core/simple_live_core.dart' show LiveRoomDetail;
import 'package:window_manager/window_manager.dart';

import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';

import 'room_controller_registry.dart';
import 'tab_store.dart';
import 'tab_strip.dart';

class RoomShellPage extends StatefulWidget {
  const RoomShellPage({super.key, this.isSubWindow = false});

  /// 子引擎房间窗：无首页、最后一个标签关闭即关窗、关窗走 close() 不 destroy
  final bool isSubWindow;

  @override
  State<RoomShellPage> createState() => _RoomShellPageState();
}

class _RoomShellPageState extends State<RoomShellPage> with WindowListener {
  /// 关闭流程重入保护：确认框弹出期间窗口关闭事件可能被再次触发
  bool _closing = false;

  Worker? _emptyWorker;
  Worker? _activeWorker;
  Worker? _titleWorker;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);

    final store = Get.find<TabStore>();
    if (widget.isSubWindow) {
      // IPC close_window 的实际执行者
      SubWindowCommands.closeRequested = _forceClose;
      // 最后一个标签被关掉 → 窗口随之关闭（无首页可停留）
      _emptyWorker = ever(store.tabs, (_) {
        if (store.tabs.isEmpty) {
          unawaited(_forceClose());
        }
      });
    }
    _activeWorker = ever(store.activeTabId, (_) => _bindTitle());
    _bindTitle();
  }

  @override
  void dispose() {
    if (widget.isSubWindow) {
      SubWindowCommands.closeRequested = null;
    }
    _emptyWorker?.dispose();
    _activeWorker?.dispose();
    _titleWorker?.dispose();
    windowManager.removeListener(this);
    super.dispose();
  }

  /// OS 标题跟随子窗激活标签的房间名
  void _bindTitle() {
    _titleWorker?.dispose();
    _titleWorker = null;
    if (!widget.isSubWindow) return;

    final store = Get.find<TabStore>();
    final id = store.activeTabId.value;
    if (id == null) {
      windowManager.setTitle('Simple Live');
      return;
    }
    final registry = Get.find<RoomControllerRegistry>();
    if (!registry.isRegistered(id)) return;

    final controller = Get.find<LiveRoomController>(tag: id);
    void update(LiveRoomDetail? detail) {
      final title = detail?.title ?? '';
      if (title.isNotEmpty) {
        windowManager.setTitle(title);
      }
    }

    update(controller.detail.value);
    _titleWorker = ever(controller.detail, update);
  }

  @override
  void onWindowClose() async {
    if (_closing) return;
    final store = Get.find<TabStore>();
    final childWindowCount =
        (!widget.isSubWindow && Get.isRegistered<WindowOpenService>())
            ? WindowOpenService.instance.childWindowCount
            : 0;

    if (store.tabs.isNotEmpty || childWindowCount > 0) {
      _closing = true;
      final message = widget.isSubWindow
          ? '还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？'
          : childWindowCount > 0
              ? store.tabs.isNotEmpty
                  ? '还有 ${store.tabs.length} 个直播间标签正在播放，关闭将同时退出 $childWindowCount 个直播间窗口，确定关闭吗？'
                  : '关闭将同时退出 $childWindowCount 个直播间窗口，确定关闭吗？'
              : '还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？';
      final ok = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('关闭窗口'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Get.back(result: true),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
      if (ok != true) {
        _closing = false;
        return;
      }
    }

    if (!widget.isSubWindow && Get.isRegistered<WindowOpenService>()) {
      await WindowOpenService.instance.requestCloseAllChildren();
    }
    await store.closeAll();

    if (widget.isSubWindow) {
      // 子窗只能 close：destroy 会 PostQuitMessage 杀掉整个进程（M0 结论）
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } else {
      await windowManager.destroy();
    }
  }

  /// IPC close_window / 最后标签关闭：不经确认框直接收尾关窗
  Future<void> _forceClose() async {
    if (_closing) return;
    _closing = true;
    final store = Get.find<TabStore>();
    await store.closeAll();
    await windowManager.setPreventClose(false);
    await windowManager.close();
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    return Column(
      children: [
        const TabStrip(),
        Expanded(
          child: Obx(() {
            final livePages = <Widget>[
              for (final tab in store.tabs)
                LiveRoomPage(
                  key: ValueKey(tab.tabId),
                  tag: tab.tabId,
                ),
            ];

            // 主窗：首页 + 所有标签全部常驻，后台标签持续播放
            if (!widget.isSubWindow) {
              final children = <Widget>[
                const IndexedPage(),
                ...livePages,
              ];
              final index = store.activeTabId.value == null
                  ? 0
                  : store.tabs.indexWhere(
                          (t) => t.tabId == store.activeTabId.value) +
                      1;
              return IndexedStack(
                  index: index < 0 ? 0 : index, children: children);
            }

            // 子窗：无首页；收尾瞬间可能为空
            if (livePages.isEmpty) {
              return const SizedBox.shrink();
            }
            final index = store.tabs
                .indexWhere((t) => t.tabId == store.activeTabId.value);
            return IndexedStack(
              index: index < 0 ? 0 : index,
              children: livePages,
            );
          }),
        ),
      ],
    );
  }
}
```

- [ ] **Step 5: 静态检查 + 构建**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test
C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug
```

Expected: analyze 无新增告警；构建成功。本任务无法自动验证子窗 GUI（开窗需桌面会话），GUI 验收在 Task 8 由用户本机执行。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/window/window_role.dart simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart simple_live_app/lib/main.dart simple_live_app/lib/app/multiwindow/shell/room_shell_page.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 主/子引擎分发，子引擎精简引导与无首页房间壳

main 按 dmw arguments 分发；子引擎内存后端+最小服务集游客进房，响应
focus_tab/close_window IPC；壳支持子窗变体（最后标签关窗、标题跟随、
close 而非 destroy、主窗关闭联动文案）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: UI 接线——卡片新窗口菜单、标签移动菜单、服务注册

**Files:**
- Modify: `simple_live_app/lib/routes/app_pages.dart:64-78`（kShell binding）
- Modify: `simple_live_app/lib/routes/app_navigation.dart:60-66`（Windows 分支）
- Modify: `simple_live_app/lib/app/multiwindow/shell/room_context_menu.dart:48-69`
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart:150-192`

**Interfaces:**
- Consumes: `WindowOpenService.instance.openInNewWindow/openLocallyWithGlobalDedup/moveTabToNewWindow`、`MultiWindowRole.isSubWindow`、`LiveRoomController.presence.value == RoomPresence.account`、`TabOpenRequest.key`。

- [ ] **Step 1: kShell binding 注册 WindowOpenService**

`lib/routes/app_pages.dart` 顶部 import 区加（该文件当前无 `dart:io`）：

```dart
import 'dart:io';

import 'package:simple_live_app/app/multiwindow/window/dmw_sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
```

把 kShell 的 binding：

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

改为：

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
        // 仅主引擎 Windows 壳需要开窗协调者（main() 已挂主窗 controller）
        if (Platform.isWindows &&
            !MultiWindowRole.isSubWindow &&
            DmwSubWindowPort.mainWindowId != null) {
          Get.put(
            WindowOpenService(
              port: DmwSubWindowPort(),
              store: Get.find<TabStore>(),
              registry: WindowRegistry(
                mainWindowId: DmwSubWindowPort.mainWindowId!,
              ),
            ),
            permanent: true,
          );
        }
      }),
```

- [ ] **Step 2: 卡片右键「新窗口打开」启用**

`room_context_menu.dart` 当前已 import `dart:io`；顶部再加：

```dart
import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
```

把 items 由 const 列表：

```dart
    items: const [
      PopupMenuItem(value: 'tab', child: Text('新标签页打开')),
      PopupMenuItem(
        enabled: false,
        child: Tooltip(
          message: '即将支持',
          child: Text('新窗口打开'),
        ),
      ),
    ],
```

改为：

```dart
    items: const [
      PopupMenuItem(value: 'tab', child: Text('新标签页打开')),
      PopupMenuItem(value: 'window', child: Text('新窗口打开')),
    ],
```

方法末尾（`if (value == 'tab') { ... }` 之后）加：

```dart
  if (value == 'window' && Get.isRegistered<WindowOpenService>()) {
    unawaited(
      WindowOpenService.instance.openInNewWindow(
        TabOpenRequest(siteId: site.id, roomId: roomId, shareUrl: shareUrl),
      ),
    );
  }
```

更新文件头文档注释中「新窗口打开：M4 实现，当前置灰」为：

```dart
/// - 新窗口打开：独立 OS 窗口游客身份进入；同 siteId+roomId 全局去重，
///   已在任一窗口打开时只置前已有窗口/标签。
```

- [ ] **Step 3: 标签右键加「移到新窗口」**

`tab_strip.dart` 当前已有 `dart:async`（unawaited）与 `get`，顶部只需新增 3 行：

```dart
import 'dart:io';

import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
```

把 `_showMenu` 里 `final value = await showMenu<String>(...)` 的入参整体替换。现有：

```dart
    final value = await showMenu<String>(
      context: context,
      position: rel,
      items: const [
        PopupMenuItem(value: 'close', child: Text('关闭')),
        PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
        PopupMenuItem(value: 'right', child: Text('关闭右侧标签')),
        PopupMenuItem(value: 'copy', child: Text('复制房间链接')),
      ],
    );
```

改为：

```dart
    LiveRoomController? controller;
    if (registry.isRegistered(descriptor.tabId)) {
      controller = Get.find<LiveRoomController>(tag: descriptor.tabId);
    }
    final isAccount =
        controller?.presence.value == RoomPresence.account;
    // M4-1：移动仅主窗游客态可用；子窗不显示该项，账号态置灰
    final showMoveItem = Platform.isWindows &&
        !MultiWindowRole.isSubWindow &&
        Get.isRegistered<WindowOpenService>();
    Widget moveChild = const Text('移到新窗口');
    if (isAccount) {
      moveChild = const Tooltip(
        message: '账号跨窗在下一阶段支持',
        child: Text('移到新窗口'),
      );
    }

    final value = await showMenu<String>(
      context: context,
      position: rel,
      items: [
        const PopupMenuItem(value: 'close', child: Text('关闭')),
        const PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
        const PopupMenuItem(value: 'right', child: Text('关闭右侧标签')),
        if (showMoveItem)
          PopupMenuItem(
            value: 'move_window',
            enabled: !isAccount,
            child: moveChild,
          ),
        const PopupMenuItem(value: 'copy', child: Text('复制房间链接')),
      ],
    );
```

在 switch 的 `case 'right':` 与 `case 'copy':` 之间加分支：

```dart
      case 'move_window':
        unawaited(
          WindowOpenService.instance
              .moveTabToNewWindow(descriptor.tabId),
        );
```

（`RoomPresence` 随 `live_room_controller.dart` 的现有 import 可见，无需新增 import。）

- [ ] **Step 4: AppNavigator Windows 分支走全局去重**

`lib/routes/app_navigation.dart` 顶部 import 区加：

```dart
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
```

把 Windows 分支：

```dart
    if (Platform.isWindows) {
      Get.find<TabStore>().open(
        TabOpenRequest(siteId: site.id, roomId: roomId, shareUrl: shareUrl),
        activate: !background,
      );
      return;
    }
```

改为：

```dart
    if (Platform.isWindows) {
      final request = TabOpenRequest(
        siteId: site.id,
        roomId: roomId,
        shareUrl: shareUrl,
      );
      if (Get.isRegistered<WindowOpenService>()) {
        // 已在子窗打开 → 置前子窗；否则按 background 语义在主窗开/激活
        await WindowOpenService.instance
            .openLocallyWithGlobalDedup(request, background: background);
      } else {
        Get.find<TabStore>().open(request, activate: !background);
      }
      return;
    }
```

- [ ] **Step 5: 静态检查 + 全量测试**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test
C:/tools/flutter347/flutter/bin/flutter.bat test
```

Expected: 无新增告警；全部测试通过。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/routes/app_pages.dart simple_live_app/lib/routes/app_navigation.dart simple_live_app/lib/app/multiwindow/shell/room_context_menu.dart simple_live_app/lib/app/multiwindow/shell/tab_strip.dart
git commit -m "$(cat <<'EOF'
feat(multiwindow): 接线卡片「新窗口打开」与标签「移到新窗口」

卡片新窗口与主窗常规打开均走全局去重协调者；标签移动仅主窗游客态可用，
抖音账号态置灰提示下一阶段支持，子窗不显示移动项。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: 最终构建门禁与 GUI 手工验收清单

**Files:**
- 无新代码；仅验证。GUI 步骤只能由用户在 Windows 桌面会话执行，执行者（subagent）不得声称 GUI 已通过——跑完自动门禁后把清单原样交回。

- [ ] **Step 1: 全量静态检查**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test
```

Expected: 无新增告警（存量 ConnectivityResult unrelated_type_equality_checks 等与本次改动无关）。

- [ ] **Step 2: 全量单测**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat test
```

Expected: 全绿（M3 基线 167 + 本计划新增）。

- [ ] **Step 3: Windows debug 构建**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug
```

Expected: 成功。

- [ ] **Step 4: 输出 GUI 手工验收清单给用户（不自动执行）**

向用户报告时附以下清单（桌面运行 `build/windows/x64/debug/simple_live_app.exe` 或 `flutter run -d windows`）：

1. 主窗启动、首页、M2 多标签与 M3 心跳行为无回归。
2. 房间卡片右键「新窗口打开」→ 弹出独立 OS 窗（1200x720 居中、标题 Simple Live），游客播放正常，与主窗声音同时存在。
3. 连开 3 个子窗播放不同房间（至少含 1 个抖音），持续 30 秒，所有窗口不卡死、不串声音（验证 media_kit_video hwnd 分派补丁）。
4. 全局去重：同一房间在已有子窗时再次「新窗口打开」→ 对应子窗置前且标签激活，不新建；主窗已有的房间再点 → 只激活主窗标签；对已在子窗播放的房间点「新标签页打开」→ 同样只置前子窗，主窗不新增标签。
5. 主窗游客标签右键「移到新窗口」→ 新窗播放同一房间、原标签关闭；抖音**账号态**标签该项置灰，悬停提示「账号跨窗在下一阶段支持」；子窗标签右键不显示该项。
6. 子窗点 X：弹确认框；确认后只关该子窗，主窗与其他子窗继续播放；子窗内直接关闭最后一个标签 → 窗口随之关闭、无残留进程。
7. 主窗点 X：存在子窗时文案含「将同时退出 N 个直播间窗口」；确认后全部窗口关闭，任务管理器中无 simple_live_app 残留进程。
8. 子窗切换标签（多标签场景可由后续 M4-4 产生；本阶段单标签跳过）——本阶段改为：子窗 OS 标题在房间详情加载后变为房间标题。
9. 子窗内弹幕屏蔽词生效（快照验证）、音量为主引擎快照值；子窗内改设置不影响主窗（M4-2 才做写穿，本阶段属预期）。
10. bili/huya 房间卡片「新窗口打开」可游客播放；子窗弹幕输入框显式置灰、悬停提示「请在主窗口发送弹幕」且发送按钮禁用（终审 I-1 裁决：方案 B 纯 Dart 降级——NativeEditHost 仅主窗构造，原生多窗 EDIT 宿主并入 M5）；主窗抖音游客弹幕（含游客验证→组字→发送）完整回归。
11. Android 相关代码路径零改动（发布前真机回归 6 项仍为 push/发版门禁，本任务不执行）。

- [ ] **Step 5: 计划实施记录回填**

在用户确认 GUI 验收结果后，由控制器（非 implementer）把：commit 清单、测试数、GUI 验收结果、遗留事项（M4-2/3/4、M5）追加到本计划文件末尾「实施记录」一节，并按仓库惯例单独提交文档（只 add 本计划路径）。

---

## 实施记录（2026-10-16 完成，已 ff 合入 my_dev @33d22fc）

12 个 commit（基线 my_dev 5b83e28）：

- T1 vendor/依赖：13f6430（vendor hwnd 分派补丁版 media_kit_video 2.0.1 + desktop_multi_window 0.3.1）→ 611fd46（剔除 vendor android/build 探针产物 99 文件，补全平台插件注册产物）→ d061e59（.gitignore/patch 存档溯源卫生收口）
- T2：b725893（runner 注册 dmw 子引擎插件回调）
- T3：caaa99c（RoomWindowArgs JSON 编解码：tabs+settings/shield/volumes/followShareUrls 快照）
- T4：a295b53（KvBox 接缝与内存后端，子引擎免 Hive 启动；五账号服务全注册预排雷修正）+ ca4dede（删测试 2 个 unused import 保 analyze 零新增）
- T5：0b29673（窗口注册表/SubWindowPort/dmw 适配/WindowOpenService 全局去重与存活对账/快照构建器凭据剥离）+ 6366127（17 个敏感键逐名断言 + List/Map 拒绝 + null 保留安全回归用例）
- T6：7d21e61（主/子引擎 main 分发、子引擎精简引导、RoomShellPage 子窗变体与联动关闭）
- T7：680aa56（卡片「新窗口打开」、标签「移到新窗口」置灰规则、AppNavigator 全局去重接线）
- 终审修复：33d22fc（I-1 子窗弹幕输入显式降级、M-1 同步空址 toast、M-2 子引擎 PackageInfo、M-3 const）

门禁：**189/189**（M3 基线 167 + 本计划新增 22：T3 14 + T4 6 + T5 12+1 安全增补 - 重叠口径以各任务报告为准）、analyze 22 条（2 warning+20 info）全存量零新增、build windows --debug 通过（终审 16.9s）。

whole-branch 终审（opus）裁定 **READY TO MERGE**，关键裁决：

- **I-1（方案 B 收范围）**：子窗弹幕输入确定性无宿主——NativeEditHost 仅主窗 flutter_window.cpp 构造（非 plugin，不进 RegisterPlugins），dmw 子窗回调无 HWND/messenger 入口；M4-1 取纯 Dart 显式降级（置灰 InputDecorator + Tooltip「请在主窗口发送弹幕」+ 发送按钮禁用），**原生多窗 EDIT 宿主并入 M5**。
- M-1：syncUrl 空时关注/取关必弹「同步失败」toast（子窗 100% 必现、主窗未配置用户存量同病），addUserData/delUserData 加 trim().isEmpty 早退；syncAll 手动入口不动。
- M-2：子引擎 runApp 前补 PackageInfo.fromPlatform()（package_info_plus 9.0.1 Windows 纯 FFI），消除 LogFileWriter LateError。
- 两处编译性偏离经评审定合法：get 4.7.3 reset() 返回 void 不可 await（仓内 8 处同款裸调）；Dart 3.13 不支持参数列表条件命名参数，home/initialRoute 改三元（get_material_app + WidgetsApp assert 双向取证）。

GUI 验收：**2026-10-16 用户本机 Windows 桌面 11 项全部 PASS**（含高风险项：3 子窗并发 30s 不串声不卡死、关窗无残留进程、子窗弹幕框置灰与主窗抖音游客弹幕回归）。

Finishing：ff 合入本地 my_dev（5b83e28..33d22fc），合并结果复跑测试 189/189，特性分支已删；**未 push、未发版**（my_dev 领先 origin/my_dev 37 commits）。

### 遗留事项（移交后续里程碑）

- **M4-2 数据面 IPC 写穿**：子窗设置/音量/屏蔽词等写操作经 IPC 落主引擎 Hive（本阶段子窗改设置不影响主窗属预期）；补 T5 park 的 IPC 失败注入测试（requestCloseAllChildren 单点失败、建窗失败保标签）。
- **M4-3 账号面 presence IPC**：落实 M3 计划末尾「M4 开工前记账」9 条（抽 PresenceClient 接口且 IPC 远端实现 isClosed、写动作入 claim 串行域、网关生命周期/dispose、detach Timer 残留、beat 非重入等）；R-1 showDanmakuInputDialog 首行加 MultiWindowRole.isSubWindow 守卫；子窗账号深路由收口；T6 close_window 首帧竞态健壮性；InMemoryDBService followBox 6 处直连在子引擎的不可达性复核；账号态标签跨窗移动解禁。
- **M4-4 跨窗拖拽**：子窗内新增标签的子→主 IPC 回报（消除注册表只记初始 key 的全局去重盲区），拖拽手势与拖出成窗。
- **M5**：NativeEditHost 多窗原生宿主（按窗持有 + WM_ACTIVATE/WM_MOVE 窗口过程）、SetWindowSubclass 修 IME 串台，并恢复子窗发弹幕能力与中文 IME 真机回归。
- **M6 发布门禁**：push/发版前补 Android 真机回归 6 项 + M3 Windows GUI 9 项 + M4 GUI 11 项。
