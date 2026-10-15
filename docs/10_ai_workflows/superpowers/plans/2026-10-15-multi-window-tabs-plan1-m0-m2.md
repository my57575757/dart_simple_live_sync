# SimpleLive 多窗口/多标签 计划 1（M0 探针 + M2 单窗多标签）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Windows 端在单个主窗口内以标签页同时打开/观看多个直播间（后台标签持续播放有声），并先行完成多引擎窗口技术探针。

**Architecture:** 每个引擎一个 `TabStore`（GetxController）管理有序标签；每个标签以 tabId 为 tag 注册一个 `LiveRoomController`，内容区 `IndexedStack` 全部挂载实现后台持续播放；房间控制器的创建/删除经 `RoomControllerRegistry` 抽象，纯逻辑可单测。M0 探针在 throwaway 分支验证 desktop_multi_window 0.3.1、子窗 media_kit、NativeEditHost 子类化与 4 路性能。

**Tech Stack:** Flutter 3.38 / Dart ≥3.0.5、GetX 4.7.3、media_kit、window_manager 0.5.1、desktop_multi_window 0.3.1（仅探针分支引入）、dart:ffi（计划 3 使用）。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-15-multi-window-tabs-design.md`（实施时 spec 与本计划一并阅读；本计划覆盖 spec 的 M0 与 M2，M1 存储后端抽口调整到计划 3，M3–M6 由后续计划覆盖）

## 与 spec 里程碑的偏差说明

spec 第 13 节顺序为 M0→M1→M2。本计划将 **M1（存储后端抽口）推迟到计划 3**：M1 的唯一消费者是子引擎（M4），单引擎多标签共享同一 Hive 实例无并发问题，提前抽取是无用户价值的大 diff（涉及 5 个账号服务与 963 行 FollowService）。计划 1 交付 M0 + M2：不依赖 M1。

## Global Constraints

- 工作目录：`D:\project\dart_simple_live\simple_live_app`；所有 flutter/dart 命令在此目录执行。
- Flutter SDK 3.38；门禁：`flutter analyze` 零告警、`flutter test` 全绿。
- 仅 Windows 行为变化；Android 开房间必须继续走 `Get.toNamed(RoutePath.kLiveRoomDetail)` 整页路由，本计划所有新代码在 Windows 分支生效。
- 多窗口相关代码一律放在 `lib/app/multiwindow/` 下。
- 用户可见文案使用简体中文；代码标识符遵循 AGENTS.md（类 PascalCase、文件 snake_case）。
- 提交信息使用仓库现有风格（`feat:` / `fix(windows):` 等中文描述），结尾固定加一行：
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`
- M0 全部产物在 throwaway 分支 `spike/multi-window-m0` 上，**不合并、不发布**；只有 Task 4 的结论写回本文件（在 main 上提交）。
- 探针分支的验证以本计划给出的手工检查为准；不写自动化测试。

---

# Phase A：M0 技术探针（throwaway 分支）

探针回答四个问题：

1. pub 版 window_manager 0.5.1 与 desktop_multi_window 0.3.1 共存时，子窗 create/show/focus/preventClose/onWindowClose 是否正常（异常则切 fork）；
2. 子窗内 media_kit 能否正常出画面出声、4 个子窗是否稳定；
3. NativeEditHost 经 `DesktopMultiWindowSetWindowCreatedCallback` 在子窗挂载后，中文 IME 是否工作；
4. 4 路同时播放的 CPU/GPU/内存数据，决定计划 3 是否需要「后台仅音频」开关。

### Task 1: M0-1 子窗生命周期探针

**Files（spike 分支，全部 throwaway）:**
- Modify: `pubspec.yaml`（加依赖）
- Create: `lib/spike/spike_window.dart`
- Modify: `lib/main.dart`（仅探针分支）

**Interfaces:**
- Consumes: `desktop_multi_window` 0.3.1 的 `WindowController.fromCurrentEngine()` / `WindowController.create(WindowConfiguration)` / `controller.show()`
- Produces: Task 4 结论表第 1 行

- [ ] **Step 1: 建探针分支并加依赖**

```bash
cd /d/project/dart_simple_live && git checkout -b spike/multi-window-m0
```

在 `simple_live_app/pubspec.yaml` 的 dependencies 中（`window_manager` 附近）加：

```yaml
  desktop_multi_window: 0.3.1 # 探针：多引擎窗口
```

执行 `flutter pub get`。若解析失败记录错误，停止探针并回报（不要自行换 git 依赖）。

- [ ] **Step 2: 写子窗 Widget（生命周期日志）**

创建 `simple_live_app/lib/spike/spike_window.dart`：

```dart
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

class SpikeWindow extends StatefulWidget {
  const SpikeWindow({required this.kind, super.key});
  final String kind;

  @override
  State<SpikeWindow> createState() => _SpikeWindowState();
}

class _SpikeWindowState extends State<SpikeWindow> with WindowListener {
  final logs = <String>[];

  void log(String m) {
    final line = '[${DateTime.now().toIso8601String()}] $m';
    debugPrint(line);
    setState(() => logs.add(line));
  }

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(720, 480),
        center: false,
        title: 'Spike Sub Window',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
        log('ready: show+focus+preventClose done, args=${widget.kind}');
      },
    );
  }

  @override
  void onWindowClose() async {
    log('onWindowClose');
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowFocus() => log('onWindowFocus');

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: Text('Spike ${widget.kind}')),
        body: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('arguments: ${widget.kind}'),
              const SizedBox(height: 12),
              Expanded(
                child: ListView(
                  children: logs.map(Text.new).toList(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: main.dart 加子窗入口分发与 SPAWN 按钮**

在 `main()` 中 `await initWindow();` 之前（`WidgetsFlutterBinding.ensureInitialized()` 之后）插入：

```dart
  if (Platform.isWindows) {
    final wc = await WindowController.fromCurrentEngine();
    if (wc.arguments.startsWith('spike:')) {
      await windowManager.ensureInitialized();
      runApp(SpikeWindow(kind: wc.arguments));
      return;
    }
  }
```

顶部加 import：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:simple_live_app/spike/spike_window.dart';
```

在 `MyApp` 的 DEBUG 按钮 `Stack` 中（main.dart 现有 `Visibility(visible: !kReleaseMode ...)` 按钮旁）再加一个按钮：

```dart
Positioned(
  right: 12,
  bottom: 150 + context.mediaQueryViewPadding.bottom,
  child: Opacity(
    opacity: 0.4,
    child: ElevatedButton(
      child: const Text("SPAWN"),
      onPressed: () async {
        final c = await WindowController.create(
          const WindowConfiguration(
            arguments: 'spike:lifecycle',
            hiddenAtLaunch: true,
          ),
        );
        await c.show();
      },
    ),
  ),
),
```

- [ ] **Step 4: 运行并验证**

`flutter run -d windows`（debug 即可），依次检查并记录：

1. 点 SPAWN：出现一个 720x480 子窗，日志含 `ready` 与 `onWindowFocus`；
2. 点子窗关闭按钮：看到 `onWindowClose` 日志后窗口真正销毁（任务栏图标消失），主窗不受影响；
3. 连开 3 个子窗，各自 SPAWN…（在任一子窗无 SPAWN 按钮，从主窗连点 3 次），全部正常显示、可独立聚焦/拖动/缩放；
4. 关闭主窗：应用整体退出（子窗随之消失）。

判定：4 项全过 = **pub 版 window_manager 0.5.1 通过**；任何一项异常（关闭不触发、焦点错乱、创建失败等），在探针分支加 `dependency_overrides:` 指向 spec 9.3 的 fork（`boyan01/window_manager` ref `6fae92d21b4c80ce1b8f71c1190d7970cf722bd4`，path `packages/window_manager`）重测，结论记录用哪一版。

- [ ] **Step 5: 提交探针代码（分支上，不推送）**

```bash
git add simple_live_app/pubspec.yaml simple_live_app/pubspec.lock simple_live_app/lib/spike simple_live_app/lib/main.dart
git commit -m "spike: 多窗口生命周期探针（throwaway）"
```

### Task 2: M0-2 子窗 media_kit 播放探针

**Files（spike 分支）:**
- Modify: `windows/runner/flutter_window.cpp`（加 RegisterPlugins 回调）
- Modify: `lib/spike/spike_window.dart`（加播放页）
- Modify: `lib/main.dart`（spike:video 分发）

**Interfaces:**
- Consumes: Task 1 的子窗分发；media_kit（已在依赖中）；C++ 回调 `DesktopMultiWindowSetWindowCreatedCallback`
- Produces: Task 4 结论表第 2、4 行

- [ ] **Step 1: 子引擎注册全部插件**

在 `windows/runner/flutter_window.cpp` 顶部 include 区加：

```cpp
#include "desktop_multi_window/desktop_multi_window_plugin.h"
```

在 `OnCreate()` 中现有 `RegisterPlugins(flutter_controller_->engine());` 一行之后加：

```cpp
  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *vc = reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterPlugins(vc->engine());
  });
```

执行 `flutter run -d windows` 确认主窗正常编译启动（此时回调尚未被使用，验证编译通过即可）。

- [ ] **Step 2: 子窗加 media_kit 播放页**

在 `spike_window.dart` 中新增（`MediaKit.ensureInitialized()` 已在主 `main()` 调用；子引擎入口在 Task 1 Step 3 的 early-return 分支，需在 `runApp(SpikeWindow...)` 之前加 `MediaKit.ensureInitialized();`）：

```dart
class SpikeVideoWindow extends StatefulWidget {
  const SpikeVideoWindow({required this.kind, super.key});
  final String kind;
  @override
  State<SpikeVideoWindow> createState() => _SpikeVideoWindowState();
}

class _SpikeVideoWindowState extends State<SpikeVideoWindow>
    with WindowListener {
  late final player = Player();
  late final controller = VideoController(player);
  final urlCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.waitUntilReadyToShow(
      const WindowOptions(size: Size(960, 600), title: 'Spike Video'),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  @override
  void onWindowClose() async {
    await player.dispose();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Spike Video'),
          actions: [
            SizedBox(
              width: 420,
              child: TextField(
                controller: urlCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: const InputDecoration(
                  hintText: '粘贴可播放的直播流地址后点 Play',
                  hintStyle: TextStyle(color: Colors.white60, fontSize: 12),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.play_arrow),
              onPressed: () => player.open(Media(urlCtrl.text.trim())),
            ),
          ],
        ),
        body: Video(controller: controller),
      ),
    );
  }
}
```

SPAWN 按钮改为创建 `spike:video` 参数：`arguments: 'spike:video'`；main.dart 分发处把 `spike:lifecycle`/`spike:video` 都放行，`spike:video` 时 `runApp(const SpikeVideoWindow(kind: 'video'))`。

- [ ] **Step 3: 取一条真实直播流地址**

在主窗正常进入一个抖音或虎牙直播间，从 debug 日志（`flutter run` 控制台会打印播放 URL；或 DEBUG LOG 面板）复制一条 `.flv`/`.m3u8` 地址。

- [ ] **Step 4: 验证单子窗播放**

`flutter run -d windows`：主窗点 SPAWN → 子窗地址栏粘贴流地址 → Play。检查：画面出现、声音正常、拖动进度无关（直播流）、连续播放 5 分钟无崩溃；关闭子窗进程无残留（任务管理器看内存句柄回落）。

- [ ] **Step 5: 验证 4 子窗并发（Task 4 同时采集数据）**

连开 4 个 `spike:video` 子窗，每个播放同一条流（或 4 个不同直播间的流）。在任务管理器「详细信息」标签给 `simple_live_app.exe` 加列 CPU、GPU、工作集，稳定播放 10 分钟后记录：

- 总 CPU 占用 %（机器 CPU 核数一并记录）；
- GPU 占用 %（3D 与 Video Decode 引擎）；
- 进程总内存 MB；
- 是否有花屏/卡顿/音频爆音/子窗崩溃。

- [ ] **Step 6: 提交**

```bash
git add simple_live_app/windows/runner/flutter_window.cpp simple_live_app/lib/spike simple_live_app/lib/main.dart
git commit -m "spike: 子窗 media_kit 播放与插件注册探针（throwaway）"
```

### Task 3: M0-3 子窗 NativeEditHost 探针

**Files（spike 分支）:**
- Modify: `windows/runner/flutter_window.cpp`（回调中创建 NativeEditHost）
- Modify: `lib/spike/spike_window.dart`（加触发按钮）

**Interfaces:**
- Consumes: 现有 `simple_live/native_edit` MethodChannel（见 `windows/runner/native_edit_host.cpp:100`）
- Produces: Task 4 结论表第 3 行；验证「不改插件源码、回调内 new NativeEditHost(GetParent(child), child, messenger)」这条路可行（spec 9.2 的正式改法）

- [ ] **Step 1: 回调中为子窗挂 NativeEditHost**

把 Task 2 的回调改为：

```cpp
#include "native_edit_host.h"
// （include 区）

  DesktopMultiWindowSetWindowCreatedCallback([](void *controller) {
    auto *vc = reinterpret_cast<flutter::FlutterViewController *>(controller);
    RegisterPlugins(vc->engine());
    HWND child = vc->view()->GetNativeWindow();
    new NativeEditHost(GetParent(child), child, vc->engine()->messenger());
  });
```

- [ ] **Step 2: SpikeVideoWindow 加一个调用原生 EDIT 的按钮**

子窗弹幕输入走 `WindowsNativeEdit` 单例（`lib/services/windows_native_edit.dart`，通道名 `simple_live/native_edit`）。在 SpikeVideoWindow 的 AppBar actions 加编辑图标按钮，onPressed 内联如下（rect 用当前 context 的逻辑坐标转物理像素）：

```dart
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.edit),
                onPressed: () async {
                  final edit = WindowsNativeEdit.instance;
                  edit.onSubmit = (text) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('submit: $text')),
                    );
                  };
                  edit.onClosed = () {};
                  final dpr = MediaQuery.of(context).devicePixelRatio;
                  final box = context.findRenderObject() as RenderBox;
                  final origin = box.localToGlobal(Offset.zero);
                  final rect = nativeEditPhysicalRect(
                    globalLogicalOrigin: Offset(origin.dx + 16, origin.dy + 96),
                    logicalSize: const Size(300, 36),
                    devicePixelRatio: dpr,
                  );
                  await edit.show(
                    rect: rect,
                    fontSizePx: 16 * dpr,
                    bgColor: 0xFFFFFFFF,
                    textColor: 0xFF000000,
                    hintColor: 0xFF999999,
                    radiusPx: (8 * dpr).round(),
                    padXPx: (8 * dpr).round(),
                    hintText: '子窗中文测试',
                    text: '',
                  );
                },
              ),
            ),
```

加 import：

```dart
import 'package:simple_live_app/services/windows_native_edit.dart';
```

验证点：EDIT 出现在**子窗自身**坐标（顶部下方），不是主窗；搜狗拼音组字、选词、回车后 SnackBar 显示中文。

- [ ] **Step 3: 验证**

热重启后：子窗点编辑按钮 → 出现原生 EDIT；切搜狗输入法输入中文（拼音组字、选词、回车提交）→ SnackBar 显示中文；英文输入正常；ESC 取消。重复 3 轮，并在主窗同样操作一次确认主窗未受影响。

记录：子窗中文是否可用、popup 位置是否跟随子窗（而不是主窗）。若 NativeEditHost 现有实现依赖 runner 的 `WM_ACTIVATE/WM_MOVE/WM_SIZE` 钩子导致子窗异常，记录具体现象——这正是计划 3 Task（NativeEditHost 改 `SetWindowSubclass` 自宿主）要解决的问题，本探针只需判定「不改插件源码 + 回调挂载」方向是否成立。

- [ ] **Step 4: 提交**

```bash
git add simple_live_app/windows/runner/flutter_window.cpp simple_live_app/lib/spike
git commit -m "spike: 子窗 NativeEditHost IME 探针（throwaway）"
```

### Task 4: M0 结论写回与分支清理

**Files:**
- Modify: 本计划文件（追加「M0 探针结论」一节，main 分支提交）

- [ ] **Step 1: 切回 main，把结论追加到本文件末尾**

```bash
git checkout main
```

在本文件末尾追加 `## M0 探针结论（YYYY-MM-DD 填写）`，包含：四项逐项 PASS/FAIL 与证据摘要；window_manager 用 pub 版还是 fork；4 路数据（CPU/GPU/内存/机器配置）；**计划 3 是否需要「后台仅音频」开关**的判定（建议阈值：4 路稳定播放 10 分钟，CPU 持续 >70% 任一核满载或出现可感知卡顿/爆音，则需要）。

- [ ] **Step 2: 提交结论，删除探针分支**

```bash
git add docs/10_ai_workflows/superpowers/plans/2026-10-15-multi-window-tabs-plan1-m0-m2.md
git commit -m "docs: 记录多窗口 M0 探针结论"
git branch -D spike/multi-window-m0
```

---

# Phase B：M2 单窗口多标签（main 分支，TDD）

### Task 5: StopHandlerRegistry 多处理器支持

**背景：** 现状 `BackgroundAudioService.setStopRequestedHandler` 每次 onInit 互相覆盖、onClose 置 null；多标签同时存在时后开的标签会顶掉前一个（`live_room_controller.dart:196`、onClose 中置 null）。Android 前台服务只有一个 channel，需要一份处理器注册表扇出。

**Files:**
- Create: `simple_live_app/lib/services/stop_handler_registry.dart`
- Modify: `simple_live_app/lib/services/background_audio_service.dart`
- Test: `simple_live_app/test/stop_handler_registry_test.dart`

**Interfaces:**
- Produces: `StopHandlerRegistry.set(key, handler)` / `invokeAll()` / `isEmpty`；`BackgroundAudioService.setStopRequestedHandler(String key, FutureOr<void> Function()? handler)`

- [ ] **Step 1: 写失败测试**

`test/stop_handler_registry_test.dart`：

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/stop_handler_registry.dart';

void main() {
  test('多处理器按注册顺序全部执行', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () async => calls.add('a'));
    r.set('b', () => calls.add('b'));
    expect(r.isEmpty, false);
    await r.invokeAll();
    expect(calls, ['a', 'b']);
  });

  test('传 null 移除指定处理器，不影响其他', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () => calls.add('a'));
    r.set('b', () => calls.add('b'));
    r.set('a', null);
    await r.invokeAll();
    expect(calls, ['b']);
  });

  test('同 key 重复注册为覆盖', () async {
    final calls = <String>[];
    final r = StopHandlerRegistry();
    r.set('a', () => calls.add('old'));
    r.set('a', () => calls.add('new'));
    await r.invokeAll();
    expect(calls, ['new']);
  });
}
```

- [ ] **Step 2: 运行确认失败**

`flutter test test/stop_handler_registry_test.dart`，Expected: 编译失败（文件不存在）。

- [ ] **Step 3: 实现**

`lib/services/stop_handler_registry.dart`：

```dart
import 'dart:async';

/// 一组带 key 的异步处理器，用于单通道事件扇出到多个标签
class StopHandlerRegistry {
  final _handlers = <String, FutureOr<void> Function()>{};

  bool get isEmpty => _handlers.isEmpty;

  void set(String key, FutureOr<void> Function()? handler) {
    if (handler == null) {
      _handlers.remove(key);
    } else {
      _handlers[key] = handler;
    }
  }

  Future<void> invokeAll() async {
    for (final handler in _handlers.values.toList()) {
      await handler();
    }
  }
}
```

`background_audio_service.dart` 中把单个 handler 改为注册表：

```dart
import 'stop_handler_registry.dart';
// ...
  final _stopHandlers = StopHandlerRegistry();

  void setStopRequestedHandler(
    String key,
    FutureOr<void> Function()? handler,
  ) {
    _stopHandlers.set(key, handler);
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'stopRequested') {
        await _stopHandlers.invokeAll();
      }
    });
  }
```

- [ ] **Step 4: 更新两个调用点**

`live_room_controller.dart`：onInit 中（约 196 行）改为

```dart
    BackgroundAudioService.instance.setStopRequestedHandler(tabId ?? 'android',
        () async {
      _audioServiceActive = false;
      BackgroundAudioService.instance.markStopped();
      await player.pause();
    });
```

onClose 中 `setStopRequestedHandler(null)` 改为：

```dart
    BackgroundAudioService.instance
        .setStopRequestedHandler(tabId ?? 'android', null);
```

`LiveRoomController` 增加可空字段（本 Task 先加字段，构造参数 Task 7 再加会造成中间状态编译失败——因此本 Step 同时在构造函数加 `this.tabId`）：

```dart
  final String? tabId;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    required this.pShareUrl,
    this.tabId,
  }) {
```

- [ ] **Step 5: 跑测试与分析**

`flutter test test/stop_handler_registry_test.dart` 全绿；`flutter analyze` 零告警。

- [ ] **Step 6: 提交**

```bash
git add simple_live_app/lib/services/stop_handler_registry.dart simple_live_app/lib/services/background_audio_service.dart simple_live_app/lib/modules/live_room/live_room_controller.dart simple_live_app/test/stop_handler_registry_test.dart
git commit -m "feat: 后台音频停止回调支持按标签注册多处理器"
```

### Task 6: 标签模型、控制器注册表与 TabStore（纯逻辑 TDD）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/shell/tab_open_request.dart`
- Create: `simple_live_app/lib/app/multiwindow/shell/tab_descriptor.dart`
- Create: `simple_live_app/lib/app/multiwindow/shell/room_controller_registry.dart`
- Create: `simple_live_app/lib/app/multiwindow/shell/tab_store.dart`
- Test: `simple_live_app/test/tab_store_test.dart`

**Interfaces:**
- Consumes: `uuid`（已在依赖中）
- Produces（后续任务依赖，签名冻结）:

```dart
class TabOpenRequest {
  final String siteId, roomId, shareUrl;
  TabOpenRequest({required this.siteId, required this.roomId, this.shareUrl = ""});
  String get key; // "$siteId_$roomId"
}

class TabDescriptor {
  final String tabId;
  final TabOpenRequest request;
  final RxString title;
  final RxBool hasError;
}

abstract class RoomControllerRegistry {
  void register(String tabId, TabOpenRequest request);
  void unregister(String tabId);
  bool isRegistered(String tabId);
}

class TabStore extends GetxController {
  TabStore({required this.registry, this.hasHome = true});
  final RxList<TabDescriptor> tabs;
  final RxnString activeTabId;            // null = 首页
  bool get isHomeActive;
  TabDescriptor? get activeTab;
  TabDescriptor open(TabOpenRequest request);   // 去重：已存在则激活并返回
  void activate(String tabId);
  void activateHome();
  TabDescriptor close(String tabId);            // unregister + 相邻标签激活
  void closeOthers(String tabId);
  void closeRight(String tabId);
  void reorder(int oldIndex, int newIndex);     // ListView 语义（已做 >old 修正）
  Future<void> closeAll();
}
```

- [ ] **Step 1: 写失败测试**

`test/tab_store_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_descriptor.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';

TabOpenRequest req(String site, String room, [String share = ""]) =>
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

void main() {
  late FakeRegistry registry;
  late TabStore store;

  setUp(() {
    registry = FakeRegistry();
    store = TabStore(registry: registry);
  });

  test('初始无标签，首页为激活态', () {
    expect(store.tabs, isEmpty);
    expect(store.isHomeActive, true);
    expect(store.activeTab, null);
  });

  test('open 注册控制器、加标签并激活', () {
    final t = store.open(req('douyin', 'r1'));
    expect(store.tabs.single.tabId, t.tabId);
    expect(store.activeTabId.value, t.tabId);
    expect(registry.registered[t.tabId]?.roomId, 'r1');
    expect(store.isHomeActive, false);
  });

  test('同 site+room 再 open 不重复创建，只激活已有标签', () {
    final t1 = store.open(req('douyin', 'r1'));
    store.open(req('douyin', 'r2'));
    final again = store.open(req('douyin', 'r1'));
    expect(store.tabs.length, 2);
    expect(again.tabId, t1.tabId);
    expect(store.activeTabId.value, t1.tabId);
    expect(registry.registered.length, 2);
  });

  test('关闭激活标签后激活相邻标签并注销控制器', () {
    final t1 = store.open(req('douyin', 'r1'));
    final t2 = store.open(req('douyin', 'r2'));
    store.close(t1.tabId);
    expect(store.tabs.single.tabId, t2.tabId);
    expect(store.activeTabId.value, t2.tabId);
    expect(registry.registered.containsKey(t1.tabId), false);
  });

  test('关闭最后一个标签回到首页', () {
    final t = store.open(req('douyin', 'r1'));
    store.close(t.tabId);
    expect(store.tabs, isEmpty);
    expect(store.isHomeActive, true);
    expect(registry.registered, isEmpty);
  });

  test('关闭非激活标签不改变激活态', () {
    store.open(req('a', '1'));
    final t2 = store.open(req('a', '2'));
    store.activate(store.tabs.first.tabId);
    store.close(t2.tabId);
    expect(store.activeTabId.value, store.tabs.single.tabId);
  });

  test('closeOthers / closeRight', () {
    final t1 = store.open(req('a', '1'));
    store.open(req('a', '2'));
    store.open(req('a', '3'));
    store.closeOthers(t1.tabId);
    expect(store.tabs.single.tabId, t1.tabId);
    expect(store.activeTabId.value, t1.tabId);

    store.open(req('a', '2'));
    store.open(req('a', '3'));
    store.closeRight(t1.tabId);
    expect(store.tabs.map((t) => t.request.roomId), ['1']);
  });

  test('reorder 使用 ListView onReorder 语义', () {
    final t1 = store.open(req('a', '1'));
    final t2 = store.open(req('a', '2'));
    final t3 = store.open(req('a', '3'));
    store.reorder(2, 0); // 3 移到最前
    expect(store.tabs.map((t) => t.tabId), [t3.tabId, t1.tabId, t2.tabId]);
    expect(store.activeTabId.value, isNotNull);
  });

  test('closeAll 注销全部控制器并回首页', () async {
    store.open(req('a', '1'));
    store.open(req('a', '2'));
    await store.closeAll();
    expect(store.tabs, isEmpty);
    expect(registry.registered, isEmpty);
    expect(store.isHomeActive, true);
  });
}
```

- [ ] **Step 2: 运行确认失败**

`flutter test test/tab_store_test.dart`，Expected: 编译失败。

- [ ] **Step 3: 实现四个文件**

`tab_open_request.dart`：

```dart
class TabOpenRequest {
  TabOpenRequest({
    required this.siteId,
    required this.roomId,
    this.shareUrl = "",
  });

  final String siteId;
  final String roomId;
  final String shareUrl;

  /// 跨标签去重键：同一直播间不同 shareUrl 视为同一房间
  String get key => "${siteId}_$roomId";
}
```

`tab_descriptor.dart`：

```dart
import 'package:get/get.dart';
import 'tab_open_request.dart';

class TabDescriptor {
  TabDescriptor({required this.tabId, required this.request})
      : title = request.roomId.obs,
        hasError = false.obs;

  final String tabId;
  final TabOpenRequest request;
  final RxString title;
  final RxBool hasError;
}
```

`room_controller_registry.dart`：

```dart
import 'tab_open_request.dart';

/// 标签 tabId → LiveRoomController 实例的注册抽象，
/// 生产实现用 GetX tag 容器，测试用内存假实现
abstract class RoomControllerRegistry {
  void register(String tabId, TabOpenRequest request);
  void unregister(String tabId);
  bool isRegistered(String tabId);
}
```

`tab_store.dart`：

```dart
import 'dart:async';

import 'package:get/get.dart';
import 'package:uuid/uuid.dart';

import 'room_controller_registry.dart';
import 'tab_descriptor.dart';
import 'tab_open_request.dart';

class TabStore extends GetxController {
  TabStore({required this.registry, this.hasHome = true});

  final RoomControllerRegistry registry;
  final bool hasHome;
  final _uuid = const Uuid();

  final RxList<TabDescriptor> tabs = <TabDescriptor>[].obs;
  final RxnString activeTabId = RxnString<String>();

  bool get isHomeActive => activeTabId.value == null;

  TabDescriptor? get activeTab {
    final id = activeTabId.value;
    if (id == null) return null;
    return tabs.firstWhereOrNull((t) => t.tabId == id);
  }

  /// 打开（或激活已存在的）直播间标签
  TabDescriptor open(TabOpenRequest request) {
    final existing =
        tabs.firstWhereOrNull((t) => t.request.key == request.key);
    if (existing != null) {
      activeTabId.value = existing.tabId;
      return existing;
    }
    final tabId = _uuid.v4();
    registry.register(tabId, request);
    final descriptor = TabDescriptor(tabId: tabId, request: request);
    tabs.add(descriptor);
    activeTabId.value = tabId;
    return descriptor;
  }

  void activate(String tabId) {
    if (tabs.any((t) => t.tabId == tabId)) {
      activeTabId.value = tabId;
    }
  }

  void activateHome() {
    if (hasHome) activeTabId.value = null;
  }

  TabDescriptor close(String tabId) {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    if (index < 0) {
      throw ArgumentError('tab not found: $tabId');
    }
    final removed = tabs.removeAt(index);
    registry.unregister(tabId);
    if (activeTabId.value == tabId) {
      activeTabId.value =
          tabs.isEmpty ? null : tabs[index.clamp(0, tabs.length - 1)].tabId;
    }
    return removed;
  }

  void closeOthers(String tabId) {
    final victims = tabs.where((t) => t.tabId != tabId).toList();
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    activeTabId.value = tabId;
  }

  void closeRight(String tabId) {
    final index = tabs.indexWhere((t) => t.tabId == tabId);
    final victims = tabs.sublist(index + 1);
    for (final t in victims) {
      registry.unregister(t.tabId);
      tabs.remove(t);
    }
    if (!tabs.any((t) => t.tabId == activeTabId.value)) {
      activeTabId.value = tabId;
    }
  }

  /// 参数语义同 ReorderableListView.onReorder（old>new 时调用方已减 1）
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tabs.length) return;
    final t = tabs.removeAt(oldIndex);
    tabs.insert(newIndex.clamp(0, tabs.length), t);
  }

  Future<void> closeAll() async {
    final all = tabs.toList();
    for (final t in all) {
      registry.unregister(t.tabId);
    }
    tabs.clear();
    activeTabId.value = null;
  }
}
```

注意：`closeOthers` 测试后又 open 了 2、3，`closeRight(t1)` 时列表为 1/2/3，结果只留 1，断言成立。

- [ ] **Step 4: 跑测试**

`flutter test test/tab_store_test.dart` 全绿。

- [ ] **Step 5: 提交**

```bash
git add simple_live_app/lib/app/multiwindow simple_live_app/test/tab_store_test.dart
git commit -m "feat: 新增标签存储 TabStore 与房间控制器注册表抽象"
```

### Task 7: GetX 标签注册表与 LiveRoomPage tag 化

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart`
- Modify: `simple_live_app/lib/modules/live_room/live_room_page.dart:31-33`

**Interfaces:**
- Consumes: Task 5 的 `LiveRoomController({tabId})`、`Sites.allSites`、Task 6 的 `RoomControllerRegistry`
- Produces: `GetxRoomControllerRegistry`；`LiveRoomPage({String? tag})`

- [ ] **Step 1: 实现生产注册表**

`getx_room_controller_registry.dart`：

```dart
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class GetxRoomControllerRegistry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {
    final site = Sites.allSites[request.siteId];
    if (site == null) {
      throw ArgumentError('unknown site: ${request.siteId}');
    }
    Get.put(
      LiveRoomController(
        pSite: site,
        pRoomId: request.roomId,
        pShareUrl: request.shareUrl,
        tabId: tabId,
      ),
      tag: tabId,
    );
  }

  @override
  void unregister(String tabId) {
    Get.delete<LiveRoomController>(tag: tabId);
  }

  @override
  bool isRegistered(String tabId) {
    return Get.isRegistered<LiveRoomController>(tag: tabId);
  }
}
```

- [ ] **Step 2: LiveRoomPage 支持 tag**

把 `live_room_page.dart:31-32`：

```dart
class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({Key? key}) : super(key: key);
```

改为：

```dart
class LiveRoomPage extends GetView<LiveRoomController> {
  const LiveRoomPage({this.tag, Key? key}) : super(key: key);

  @override
  final String? tag;
```

（GetX 的 `GetView.tag` 是可覆盖字段；`controller` getter 自动按 tag 查找，页面其余代码零改动。）

- [ ] **Step 3: 静态检查**

`flutter analyze` 零告警；`flutter test` 全绿（Android 路由 binding 仍无 tag put，行为不变）。

- [ ] **Step 4: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart simple_live_app/lib/modules/live_room/live_room_page.dart
git commit -m "feat: 标签以 tabId 为 tag 注册房间控制器，LiveRoomPage 支持 tag 查找"
```

### Task 8: RoomShell 标签壳（标签栏 + IndexedStack + 首页底页）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart`
- Create: `simple_live_app/lib/app/multiwindow/shell/room_shell_page.dart`
- Modify: `simple_live_app/lib/routes/route_path.dart`（加 kShell）
- Modify: `simple_live_app/lib/routes/app_pages.dart`（加路由与 binding）
- Modify: `simple_live_app/lib/main.dart`（Windows 初始路由 kShell）

**Interfaces:**
- Consumes: Task 6 `TabStore`、Task 7 `GetxRoomControllerRegistry`、现有 `IndexedPage`/`IndexedController`
- Produces: 路由 `RoutePath.kShell = "/shell"`；`RoomShellPage`

- [ ] **Step 1: 路由常量与路由表**

`route_path.dart` 加：

```dart
  /// Windows 标签壳（首页 + 直播间标签）
  static const kShell = "/shell";
```

`app_pages.dart` 加 import 与路由（routes 列表最前）：

```dart
import 'package:simple_live_app/app/multiwindow/shell/getx_room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_shell_page.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
```

```dart
    // Windows 标签壳
    GetPage(
      name: RoutePath.kShell,
      page: () => const RoomShellPage(),
      binding: BindingsBuilder(() {
        Get.put<RoomControllerRegistry>(GetxRoomControllerRegistry());
        Get.put(IndexedController());
        Get.put(TabStore(registry: Get.find<RoomControllerRegistry>()));
      }),
    ),
```

- [ ] **Step 2: 标签栏组件**

`tab_strip.dart`：

```dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

import 'room_controller_registry.dart';
import 'tab_descriptor.dart';
import 'tab_store.dart';

class TabStrip extends StatelessWidget {
  const TabStrip({super.key});

  static const double height = 38;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final theme = Theme.of(context);
    return Material(
      color: theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface,
      child: SizedBox(
        height: height,
        child: Obx(() {
          return Row(
            children: [
              if (store.hasHome)
                _HomeButton(active: store.isHomeActive),
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: store.tabs.length,
                  itemBuilder: (_, i) =>
                      _TabItem(descriptor: store.tabs[i]),
                ),
              ),
              if (store.hasHome)
                IconButton(
                  tooltip: "首页",
                  icon: const Icon(Icons.add, size: 18),
                  onPressed: store.activateHome,
                ),
            ],
          );
        }),
      ),
    );
  }
}

class _HomeButton extends StatelessWidget {
  const _HomeButton({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final theme = Theme.of(context);
    return InkWell(
      onTap: store.activateHome,
      child: Container(
        padding: AppStyle.edgeInsetsH12,
        color: active ? theme.colorScheme.primary.withAlpha(30) : null,
        alignment: Alignment.center,
        child: Icon(Icons.home,
            size: 18, color: active ? theme.colorScheme.primary : null),
      ),
    );
  }
}

class _TabItem extends StatelessWidget {
  const _TabItem({required this.descriptor});
  final TabDescriptor descriptor;

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    final registry = Get.find<RoomControllerRegistry>();
    final theme = Theme.of(context);
    final tabId = descriptor.tabId;
    // 中键关闭：Listener 比 GestureDetector 更直接
    return Listener(
      onPointerDown: (event) {
        if (event.kind == PointerDeviceKind.mouse &&
            event.buttons == kMiddleMouseButton) {
          store.close(tabId);
        }
      },
      child: GestureDetector(
        onTap: () => store.activate(tabId),
        onSecondaryTapUp: (details) =>
            _showMenu(context, details.globalPosition),
        child: Obx(() {
          final active = store.activeTabId.value == tabId;
          LiveRoomController? c;
          if (registry.isRegistered(tabId)) {
            c = Get.find<LiveRoomController>(tag: tabId);
          }
          final title = c?.detail.value?.title ?? descriptor.title.value;
          final error = c?.loadError.value ?? false;
          return Container(
            width: 180,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: active
                  ? theme.colorScheme.primary.withAlpha(30)
                  : Colors.transparent,
              border: Border(
                bottom: BorderSide(
                  color:
                      active ? theme.colorScheme.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(error ? Icons.error_outline : Icons.live_tv,
                    size: 14,
                    color: error ? theme.colorScheme.error : null),
                AppStyle.hGap4,
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          active ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                ),
                InkWell(
                  onTap: () => store.close(tabId),
                  child: const Icon(Icons.close, size: 15),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Future<void> _showMenu(BuildContext context, Offset position) async {
    final store = Get.find<TabStore>();
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final rel = RelativeRect.fromRect(
      Rect.fromPoints(position, position),
      Offset.zero & overlay.size,
    );
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
    if (value == null) return;
    switch (value) {
      case 'close':
        store.close(descriptor.tabId);
      case 'others':
        store.closeOthers(descriptor.tabId);
      case 'right':
        store.closeRight(descriptor.tabId);
      case 'copy':
        final r = descriptor.request;
        Utils.copyToClipboard(r.shareUrl.isNotEmpty ? r.shareUrl : r.roomId);
    }
  }
}
```

「移到新窗口」菜单项在计划 3（M4）加入；标签条内排序也在 M4 的统一拖拽状态机中一并实现（spec 6.2）。

- [ ] **Step 3: RoomShellPage**

`room_shell_page.dart`：

```dart
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';
import 'package:simple_live_app/modules/indexed/indexed_page.dart';
import 'package:simple_live_app/modules/live_room/live_room_page.dart';

import 'tab_store.dart';
import 'tab_strip.dart';

class RoomShellPage extends StatefulWidget {
  const RoomShellPage({super.key});

  @override
  State<RoomShellPage> createState() => _RoomShellPageState();
}

class _RoomShellPageState extends State<RoomShellPage> with WindowListener {
  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    windowManager.setPreventClose(true);
  }

  @override
  void onWindowClose() async {
    final store = Get.find<TabStore>();
    if (store.tabs.isNotEmpty) {
      final ok = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('关闭窗口'),
          content: Text('还有 ${store.tabs.length} 个直播间标签正在播放，确定关闭吗？'),
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
      if (ok != true) return;
    }
    await store.closeAll();
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    final store = Get.find<TabStore>();
    return Column(
      children: [
        const TabStrip(),
        Expanded(
          child: Obx(() {
            // 首页 + 所有标签全部常驻：后台标签持续播放
            final children = <Widget>[
              const IndexedPage(),
              for (final t in store.tabs)
                LiveRoomPage(
                  key: ValueKey(t.tabId),
                  tag: t.tabId,
                ),
            ];
            final index = store.activeTabId.value == null
                ? 0
                : store.tabs.indexWhere((t) => t.tabId == store.activeTabId.value) + 1;
            return IndexedStack(index: index < 0 ? 0 : index, children: children);
          }),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Windows 初始路由切到 kShell**

`main.dart` 的 `GetMaterialApp`：

```dart
        initialRoute:
            Platform.isWindows ? RoutePath.kShell : RoutePath.kIndex,
```

- [ ] **Step 5: 手工验证（必须运行）**

`flutter run -d windows`：

1. 启动即看到标签栏 + 首页，首页四个 tab 与导航正常；
2. 从首页点进任意房间：出现标签、房间正常加载播放有声音；
3. 回首页再进第二个房间：两个标签都在，切回第一个标签播放未中断（声音仍在）；
4. 标签 × / 中键 / 右键菜单关闭：控制器释放（控制台有「播放器关闭」日志）；
5. 关窗时控制台对每个未关标签都打印「播放器关闭」（onWindowClose 走 closeAll）；
6. 标题/错误态显示正常。

- [ ] **Step 6: analyze 与提交**

`flutter analyze` 零告警后：

```bash
git add simple_live_app/lib/app/multiwindow simple_live_app/lib/routes simple_live_app/lib/main.dart
git commit -m "feat(windows): 标签壳 RoomShell：首页底页 + 直播间多标签常驻播放"
```

### Task 9: 入口分发、侧键返回与跨标签状态检查

**Files:**
- Modify: `simple_live_app/lib/routes/app_navigation.dart:53-56`
- Modify: `simple_live_app/lib/main.dart`（鼠标侧键/返回处理）
- Modify: `simple_live_app/lib/app/multiwindow/shell/tab_strip.dart`（标签实时标题/错误刷新，若 Task 8 未充分订阅）

**Interfaces:**
- Consumes: Task 6 `TabStore.open`、Task 8 kShell

- [ ] **Step 1: AppNavigator Windows 分发**

`app_navigation.dart` 在 bilibili 登录提示逻辑之后、现有 `Get.toNamed(...)` 之前加：

```dart
    if (Platform.isWindows) {
      Get.find<TabStore>().open(
        TabOpenRequest(siteId: site.id, roomId: roomId, shareUrl: shareUrl),
      );
      return;
    }
```

加 import：

```dart
import 'dart:io';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
```

`Platform` 在该文件已有 import（`dart:io` 已用于 toBiliBiliLogin）。

- [ ] **Step 2: 鼠标侧键 4 在标签壳内改为关闭当前标签**

main.dart 现有侧键回调（`FourthButtonTapGestureRecognizer` 的 onTapDown，约 282 行）中，在 `Get.back()` 之前加：

```dart
                          if (Platform.isWindows &&
                              Get.isRegistered<TabStore>()) {
                            final store = Get.find<TabStore>();
                            final active = store.activeTabId.value;
                            if (active != null) {
                              store.close(active);
                              return;
                            }
                          }
```

import tab_store。注意保持全屏退出逻辑在前（先退全屏，下次侧键才关标签——把这段插在全屏判断 `return` 之后）。

- [ ] **Step 3: 手工验证全部入口与返回**

`flutter run -d windows`，覆盖 7 个入口：首页房间卡片、关注列表、历史列表、搜索结果、抖音搜索、工具箱解析、分类详情内房间（若有）；每个都新开标签；同房间重复点击只激活不新增；侧键在房间标签 = 关标签，在首页 = 无路由可退（无异常、不退出 App）。

- [ ] **Step 4: analyze + 提交**

```bash
flutter analyze
git add simple_live_app/lib/routes/app_navigation.dart simple_live_app/lib/main.dart
git commit -m "feat(windows): 直播间入口分发到标签，侧键返回关闭当前标签"
```

### Task 10: 定时关闭适配多标签

**Files:**
- Modify: `simple_live_app/lib/modules/live_room/live_room_controller.dart`（`initAutoExit` 约 230-253 行的 3 处 `exit(0)`）

**Interfaces:**
- Consumes: Task 5 的 `tabId` 字段、Task 6 `TabStore`

- [ ] **Step 1: 替换 exit(0)**

`initAutoExit` 中倒计时归零分支与未延迟分支现在直接 `exit(0)`（共 2 处，外加 10 秒宽限 Timer 内 2 处共 3 处调用点）。新增方法：

```dart
  /// 定时关闭到时：Windows 标签模式关闭本标签（停止播放即满足入睡场景），
  /// 无标签壳（Android / 路由模式）保持退出进程
  Future<void> _handleAutoExit() async {
    await WakelockPlus.disable();
    if (Platform.isWindows &&
        tabId != null &&
        Get.isRegistered<TabStore>()) {
      final store = Get.find<TabStore>();
      if (store.tabs.any((t) => t.tabId == tabId)) {
        store.close(tabId!);
        return;
      }
    }
    exit(0);
  }
```

把三处 `await WakelockPlus.disable(); exit(0);` 替换为 `await _handleAutoExit();`（10 秒 Timer 回调与"关闭"分支共用）。`Get`/`Platform` 已在该文件导入；加 `import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';`。

用户点"延迟"的分支不动。

- [ ] **Step 2: 手工验证**

`flutter run -d windows`：房间内把定时关闭设为最短可测值（若最小粒度为分钟，可临时把 60s 倒计时断言用 debug 修改，测完还原），到时标签关闭、回到首页或相邻标签、进程不退出；多标签时只关当前标签。`flutter analyze` 零告警。

- [ ] **Step 3: 提交**

```bash
git add simple_live_app/lib/modules/live_room/live_room_controller.dart
git commit -m "feat(windows): 定时关闭到时改为关闭当前直播间标签"
```

### Task 11: 全量门禁与手工验收

**Files:** 无新增

- [ ] **Step 1: 自动化门禁**

```bash
flutter analyze
flutter test
```

两者必须全绿（含既有 presence/danmaku/guard 测试，确认 tag 化与注册表改动无回归）。

- [ ] **Step 2: Windows 手工验收清单**

`flutter run -d windows`，逐项打勾：

- [ ] 首页功能（站点切换、关注、历史、搜索、我的、设置）全部可从标签壳进入，返回侧键/返回按钮回首页正常；
- [ ] 开 4 个不同平台房间标签：全部出画面、全部有声音、各自控制条静音独立生效、音量独立持久化（重开标签记住音量）；
- [ ] 后台标签弹幕持续接收、看门狗不误杀（10 分钟无卡死误报）；
- [ ] 标签切换瞬时无加载；标签排序入口本期不做（计划 3 拖拽）；
- [ ] 右键菜单四项工作；中键关闭工作；
- [ ] 同房间去重；关闭标签后心跳/历史/关注状态正确（抖音账号态进房→关标签→guard 退房日志；看后历史出现）；
- [ ] 关主窗：有标签时弹确认，取消不关；确认后所有标签播放器释放（控制台日志数 = 标签数）；无标签时直接关；
- [ ] 定时关闭到时只关标签；
- [ ] 侧键关标签、全屏时侧键先退全屏；
- [ ] 桌面小窗 / 全屏作用于当前标签所在窗口，无串台；画中画按钮在 Windows 不出现在异常位置（floating 仅 Android 包裹，现状保持）；
- [ ] 连续开关 20 个标签无内存持续上涨（任务管理器粗查）。

- [ ] **Step 3: Android 回归（必须实测）**

`flutter run -d android`（或设备）：开房间整页跳转、返回退房、登录提示、定时关闭退出 App、全屏/小窗/画中画、音量——与改动前一致。

- [ ] **Step 4: 最终提交（如有验收修复）**

```bash
git add -A
# 仅 stage 本功能相关文件，排除 .idea/.opencode 等既有改动
git commit -m "fix(windows): 多标签验收问题修复"
```

---

## 后续（不在本计划）

- **计划 2（M3）**：DouyinPresenceGateway + PresenceClient，单引擎意图栈，多抖音标签唯一心跳与关闭回退接管。
- **计划 3（M1+M4+M5+M6）**：存储后端抽口（M1）、子窗/IPC/快照写穿/跨窗拖拽（M4）、NativeEditHost 自宿主化与插件回调正式落地（M5）、打磨发布（M6）；是否含「后台仅音频」由 M0 结论决定。

---

## M0 探针结论（2026-10-15 填写）

### 1. 四项核心验证总览

| # | 验证点 | 结果 | 证据 |
|---|---|---|---|
| 1 | desktop_multi_window 0.3.1 多引擎创建与生命周期 | **PASS**（经修复后） | 补丁后连开 3 子窗、视频子窗播放 HLS 出画面 `playing:true` |
| 2 | window_manager 关窗语义 | **PASS** | `close()` 单独关子窗主窗正常；主窗 X → 子窗全部联动消失，tasklist 无残留进程 |
| 3 | NativeEditHost 子窗 IME | **PASS（功能）/ 已知缺陷（g_instance）** | 搜狗拼音组字/选词/英文/提交中文正常；进程级单例污染实测复现 |
| 4 | 4 路同时播放 10 分钟性能 | **PASS** | CPU 1.5–8%（16 逻辑核归一化）、WS 1.55–1.76GB、无卡顿爆音、GPU 很低 |

### 2. window_manager 版本裁决：用 pub 0.5.2，不换 fork

spec 9.3 的换 fork 条件**不触发**。首轮"关子窗全进程退出"根因是探针误用 `destroy()`——pub 0.5.2 的 `Destroy()` 实现就是 `PostQuitMessage(0)`（window_manager.cpp:232-234）；该版本已按引擎绑定各自根窗（注册时 `GetAncestor(view, GA_ROOT)`，window_manager_plugin.cpp:348）。正确关窗路径：

- 子窗收尾后一律 **`close()`**（SC_CLOSE→本窗销毁→插件析构 `RemoveWindow`，windows_ 非空不退出，multi_window_manager.cc:141-152）；
- `destroy()`/PostQuitMessage 仅保留给主窗退出路径；
- 播放器子窗需先 `setPreventClose(true)`，`onWindowClose` 内 dispose → setPreventClose(false) → close()，消除 native 释放竞争。

### 3. 重大发现：media_kit_video 2.0.1 多引擎窗口过程错路由（计划外，阻塞级）

**现象**：子引擎注册 media_kit_video 后，第一个子窗一出来主窗即永久无响应（能拖动、CPU 0%），第二窗永远不创建；lifecycle 空窗（不碰 Player）同样致死，与播放无关。

**根因**（插件 windows/media_kit_video_plugin.cc）：

1. 插件有进程级静态 `instance_`，构造时对本引擎根 HWND `SetWindowLongPtr(GWLP_WNDPROC, WindowProcDelegate)` 做窗口子类化；
2. 静态 `WindowProcDelegate` 对**所有**被其子类化的窗口一律经 `instance_->original_window_proc_` 转发；
3. 子引擎插件实例 B 构造后覆盖 `instance_`，主窗 HWND 的消息被 `CallWindowProc` 到**子窗**的原窗口过程 → 主窗平台/UI 消息全部被吞；第二次 SPAWN 的 Dart 点击回调因此根本不触发（打点日志：第二引擎回调从未开始）。

**二分证据**：子引擎注册插件 0 个活（白屏）/ 前 3 活 / 前 5 活 / 前 6（加入 MediaKitVideo）死；去掉该插件多窗正常。

**修复**：窗口过程改为按 HWND 分派——新增 `static std::unordered_map<HWND, MediaKitVideoPlugin*> hwnd_instances_`（配 mutex），构造注册、析构注销，delegate 按 hwnd 查表取实例。补丁全文（83 行）存档于 `.superpowers/sdd/2026-10-15-multi-window-tabs-plan1-m0-m2/media-kit-video-2.0.1-hwnd-dispatch.patch`。补丁后全量 13 插件：3 窗开关、播放、主窗联动关闭全部正常。

**正式化（计划 3 M4 新增前置任务）**：pub 上 2.0.1 已是 media_kit_video 当前最新线（依赖仅 `media_kit: ^1.2.3`，与本项目 1.2.6 兼容），不能靠升级解决。M4 首次多窗联调前必须完成：把补丁版整包（1.5MB）vendor 进仓（建议 `third_party/media_kit_video/`），`pubspec.yaml` 改 path 依赖并注释指向本结论；Android 端 path 包内各平台目录完整不影响其他端。M2（Task 5-11）只在主引擎内做单窗多标签，不创建第二引擎，因此不被此补丁阻塞。

> 编码注意：MSVC 在中文系统按 GBK 解码无 BOM 的 UTF-8 源文件，补丁里的中文注释尾字节会吞掉下一行（实测致 C2065/C2039 假错误），vendor 时注释一律英文或存为 UTF-8 BOM。

### 4. NativeEditHost 结论（M5 必做，无延期理由）

- **方向成立**：不改 dmw 插件源码，子窗 created 回调内 `new NativeEditHost(::GetParent(child), child, messenger)` 即可获得完整中文 IME 能力。
- **g_instance 进程级污染实测确认**：native_edit_host.cpp 的静态 `g_instance`（:97 无条件赋值）被每个新开子窗覆盖，多窗时 ESC/消息只路由到最后创建的 host——先开子窗的原生 popup 残留无法关闭、hint 文本悬停主窗区域。主窗普通 TextField 不受影响，但主窗与子窗的弹幕原生输入会串台。M5 必须按 spec 9.1 做 `SetWindowSubclass`（按 HWND 取 this）自宿主化。
- **popup 跟随缺口**：dmw 子窗走插件自带 FlutterWindow（windows/flutter_window.cc OnCreate 无 runner 的 WM_MOVE/WM_SIZE 钩子），runner 侧 OnOwnerMoved 跟随对子窗不生效；M5 子类化时一并承担位置跟随。
- 探针中"popup 不在子窗内"是探针按钮坐标算错（960 宽窗内铅笔按钮 x≈864+16，300 宽框大部分落出窗外），非架构问题。

### 5. 性能数据与「后台仅音频」判定

4 路 HLS 同时播放 10 分钟（2026-10-15 21:42–21:52，机器 16 逻辑核，debug 构建，单进程多引擎）：

- CPU 全程 1.5–8%，绝大多数时间 4–6%；
- 工作集 ~1.55GB 平稳约 9 分钟，尾段波动至 1.68–1.76GB（HLS 码率切换/窗口操作所致，随后回落）；
- 句柄 ~1940、线程 ~245 平稳，尾段两次短时跃升后均回落，无单调增长；
- 无崩溃、无可感知卡顿、无爆音；GPU 占用用户观察"很低"。

**判定：远优于阈值（持续 >70%/单核满载/卡顿爆音），V1 全量后台渲染成立，计划 3 不做「后台仅音频」开关。** 若未来低端机实测不达标，再按 spec 作为 V1.1 优化项单独立项。

### 6. 环境与复现

- Flutter 3.47.5 / Dart 3.13.4（`C:/tools/flutter347/flutter`，R1）；desktop_multi_window 0.3.1；media_kit_video 2.0.1 + media_kit 1.2.6。
- 探针分支 spike/multi-window-m0（be70319..1991285，throwaway，结论写完即删）。
- GUI 验证由用户在本机完成（R3）；性能脚本 `spike-perf-sample.ps1`（仓根临时文件，随探针清理）。

