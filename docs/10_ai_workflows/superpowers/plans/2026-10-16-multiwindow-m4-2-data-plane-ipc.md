# M4-2 数据面 IPC 写穿 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 子引擎的设置/屏蔽词/音量/关注/历史五类写入经 IPC 收口主引擎落 Hive，并广播回全部子窗，跨窗数据最终一致。

**Architecture:** 主引擎 `MainDataPlaneService` 挂主窗 method handler 落盘并订阅 4 个真实 box 的变更流统一扇出 `dp_changed`；子引擎 `RemoteKvBox` 乐观内存写 + fire-and-forget IPC，`SubDataPlaneClient` 接收广播分流、防抖 reload、定向刷关注按钮；开窗时 `dp_ready` 请求-响应对账消除启动竞态。业务调用点零改动（后端在装配层替换）。

**Tech Stack:** Flutter 3.47.5 / Dart 3.13.4、GetX 4.7.3、Hive 2.2.3、desktop_multi_window 0.3.1（MethodCall 通道）、fake_async 1.3.1（已在 dev_dependencies，无需新增依赖）。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-16-multiwindow-m4-2-data-plane-ipc-design.md`（计划从 spec 论证，执行时 spec 与任务简报一起读）

## Global Constraints

- Flutter 一律 `C:/tools/flutter347/flutter/bin/flutter.bat`（3.47.5/Dart 3.13.4；AGENTS.md 写的 3.38 本机没有）；flutter 命令在 `D:/project/dart_simple_live/simple_live_app` 执行，git 操作在仓根 `D:/project/dart_simple_live`（git 根在 simple_live_app 上一级）。
- 分支：自当前 `my_dev`（@00c4287）切 `feat/m4-2-data-plane-ipc`，就地分支不用 worktree（工作区有约 40 个无关存量脏文件）。SDD 工作区：`docs/10_ai_workflows/superpowers/sdd/2026-10-16-multiwindow-m4-2-data-plane-ipc/`。
- 仅 Windows 启用：主引擎新服务注册条件沿用 `Platform.isWindows && !MultiWindowRole.isSubWindow && DmwSubWindowPort.mainWindowId != null`；Android/iOS/TV 路径零变化。
- **不 push、不发版**。`git add` 只加精确路径，严禁 `-A`/`.`。每个 commit message 结尾空行 + `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`。不触碰约 40 个无关脏文件（.idea/.opencode/tv gradle 等）。
- 门禁每个任务自证：`flutter analyze lib test` 相对基线**零新增**（基线 22 条存量：2 warning + 20 info）；`flutter test` 全绿（基线 189）；接线任务额外 `flutter build windows --debug`。
- 敏感键清单迁移到 `DataPlaneProtocol` 后必须保持 17 个具名键 + `GuardAccountId_` 前缀，测试锚点 `length == 17` 不得删。
- 子引擎仍不接触 Hive、不获得任何账号凭据；M4-2 不传 cookie/token/GuardServer 配置（账号面是 M4-3）。
- 执行者不得声称 GUI 已通过；GUI 9 项只能由用户本机桌面会话验收。
- **安全补网（pre-flight Ruling，超出 spec §8 字面但服务其安全意图）**：spec §8 只要求 handler 写入侧拒绝敏感键；watch **扇出侧**必须同样过滤——主窗本地登录写 cookie 也过 watch，不滤则凭据经 `dp_changed` 进入子引擎，击穿 M4-1 凭据隔离。故 `dp_kv_delete` 对敏感键也拒绝（游客子窗连删除凭据都不允许）。此裁决在 SDD pre-flight ledger 复记。
- Hive 2.2.3 时序（已对 pub cache 源码取证，实现依赖此事实）：`box.put` 的 watch 通知在 `keystore.beginTransaction` 内、`await backend.writeFrames` 之前**同步**派发（keystore.dart:176-178）；`box.clear()` 在 `await backend.clear()` 完成后的同步段逐 key 通知（box_base_impl.dart:137-142、keystore.dart:254-269）。故 remoteWrite/suppressed 标志用同步 try/finally 包裹 await 即可可靠覆盖。
- Dart/项目事实（M2-M4-1 已踩坑，禁止重犯）：不支持参数列表条件命名参数，用三元；get 4.7.3 `Get.reset()` 返回 void 不可 await，仓内先例裸调或包块体；`firstWhereOrNull` 由 get 再导出，不引 package:collection；`onInit()`/`onClose()` 在本仓测试可直调（window_open_service_test.dart:71/75 先例，不触发 lint）；analyze 零新增优先于逐字照抄简报（简报代码若触发 lint，删冗余 import/加 const 是合法偏离，必须在报告中记录）。
- **测试 Timer 卫生**：主服务远程写路径会挂 100ms 防抖 Timer；普通 test（非 fakeAsync）结束前必须 `await Future<void>.delayed(120ms)` 等触发，否则 package:test 报 pending timer；fakeAsync 测试结束前也 elapse 排空。
- 站点 id 字面值：bilibili/douyin/douyu/huya/twitch（`Constant.kBiliBili == "bilibili"`，不是 "bili"）；跨窗房间键格式 `siteId_roomId`。
- import 约定：本计划新文件一律用 `package:simple_live_app/...` 绝对 import；同目录既有文件沿用其现有相对 import 风格，不强行改动无关行。

---

### Task 1: KvBox 变更流与静默种子入口

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/kv_box.dart`
- Test: `simple_live_app/test/multiwindow/kv_box_test.dart`

**Interfaces:**
- Produces: `KvChange<T>{Object key, T? value, bool deleted}`；`KvBox<T>.changes()` → `Stream<KvChange<T>>`；新抽象 `SeedableKvBox<T> implements KvBox<T>`，方法 `void seedPut(Object key, T value)` / `void seedDelete(Object key)` / `Future<void> seedClear()` / `void seedReplaceAll(Map<Object, T> entries)`（全部不触发 changes）。
- Consumes: 无。
- 事件语义对齐 Hive 2.2.3（已取证）：put 总发一条非删除事件（同值也发）；delete 仅 key 存在时发 deleted 且 **value 恒为 null**（Hive BoxEvent 删除位不传旧值，T5 `_onFollowChange` 依赖此语义）；clear 对每个现存 key 发 deleted（value=null）；putAll 逐 key 发。

- [ ] **Step 1: 写失败测试**

在 `test/multiwindow/kv_box_test.dart` 的 `main()` 内最后一个 test 之后追加：

```dart
  test('MemoryKvBox changes：put/delete 缺失/clear 事件序列对齐 Hive',
      () async {
    final box = MemoryKvBox<String>();
    final events = <List<Object?>>[];
    box.changes().listen((e) => events.add([e.key, e.value, e.deleted]));

    await box.put('a', '1');
    await box.put('a', '2'); // 同值覆盖也发
    await box.delete('missing'); // 不存在不发
    await box.put('b', 'x');
    await box.clear();

    expect(events, [
      ['a', '1', false],
      ['a', '2', false],
      ['b', 'x', false],
      ['a', null, true],
      ['b', null, true],
    ]);
  });

  test('MemoryKvBox putAll 逐键发事件', () async {
    final box = MemoryKvBox<String>();
    final keys = <Object>[];
    box.changes().listen((e) => keys.add(e.key));
    await box.putAll({1: '一', 2: '二'});
    expect(keys, [1, 2]);
  });

  test('SeedableKvBox seed* 静默：不发事件但读可见、可整体替换',
      () async {
    final SeedableKvBox<String> box = MemoryKvBox<String>();
    final events = <KvChange<String>>[];
    box.changes().listen(events.add);

    box.seedPut('a', '1');
    expect(box.get('a'), '1');
    box.seedDelete('a');
    expect(box.containsKey('a'), isFalse);
    box.seedReplaceAll({'x': 'X', 'y': 'Y'});
    expect(box.toMap(), {'x': 'X', 'y': 'Y'});
    await box.seedClear();
    expect(box.values, isEmpty);
    expect(events, isEmpty, reason: '种子路径不得发事件');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd simple_live_app && C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/kv_box_test.dart`
Expected: 编译失败（`changes`/`seedPut`/`SeedableKvBox` 未定义）。

- [ ] **Step 3: 实现**

整文件替换 `lib/app/multiwindow/bootstrap/kv_box.dart` 为：

```dart
import 'dart:async';

import 'package:hive/hive.dart';

/// 一次 KV 变更（对齐 Hive BoxEvent：deleted 时 value 为 null）
class KvChange<T> {
  const KvChange(this.key, this.value, {this.deleted = false});

  final Object key;
  final T? value;
  final bool deleted;
}

/// 同构 KV 存储接缝：生产走 Hive，房间子引擎走纯内存/远端写穿。
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

  /// 变更流。事件语义与 Hive box.watch 对齐（put 总发、delete 缺失不发、
  /// clear 逐 key 发 deleted）。
  Stream<KvChange<T>> changes();
}

/// 可静默播种的 KV：远端广播/启动快照走 seed*，不触发 changes、不发 IPC。
abstract class SeedableKvBox<T> implements KvBox<T> {
  void seedPut(Object key, T value);
  void seedDelete(Object key);
  Future<void> seedClear();
  void seedReplaceAll(Map<Object, T> entries);
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

  @override
  Stream<KvChange<T>> changes() => box.watch().map(
      (e) => KvChange<T>(e.key as Object, e.value as T?, deleted: e.deleted));
}

class MemoryKvBox<T> implements SeedableKvBox<T> {
  final Map<Object, T> _map = {};
  final StreamController<KvChange<T>> _changes =
      StreamController<KvChange<T>>.broadcast();

  @override
  T? get(Object key, {T? defaultValue}) =>
      _map.containsKey(key) ? _map[key] : defaultValue;

  @override
  Future<void> put(Object key, T value) async {
    _map[key] = value;
    _changes.add(KvChange<T>(key, value));
  }

  @override
  Future<void> delete(Object key) async {
    if (!_map.containsKey(key)) return;
    _map.remove(key);
    // 与 Hive BoxEvent 对齐：删除事件 value 恒为 null
    _changes.add(KvChange<T>(key, null, deleted: true));
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
    final removedKeys = List<Object>.of(_map.keys);
    _map.clear();
    for (final key in removedKeys) {
      // 与 Hive BoxEvent 对齐：删除事件 value 恒为 null
      _changes.add(KvChange<T>(key, null, deleted: true));
    }
    return count;
  }

  @override
  Map<Object, T> toMap() => Map<Object, T>.of(_map);

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Stream<KvChange<T>> changes() => _changes.stream;

  @override
  void seedPut(Object key, T value) {
    _map[key] = value;
  }

  @override
  void seedDelete(Object key) {
    _map.remove(key);
  }

  @override
  Future<void> seedClear() async {
    _map.clear();
  }

  @override
  void seedReplaceAll(Map<Object, T> entries) {
    _map
      ..clear()
      ..addAll(entries);
  }
}
```

- [ ] **Step 4: 跑测试确认通过 + 全量门禁**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/kv_box_test.dart`
Expected: 5 个 test 全过。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 与基线一致（22 条存量，零新增）。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（189 + 3 新增 = 192）。

- [ ] **Step 5: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/bootstrap/kv_box.dart simple_live_app/test/multiwindow/kv_box_test.dart
git commit -m "feat(multiwindow): KvBox 变更流与静默种子入口，为数据面写穿做接缝

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: 启动参数携带主窗 id 与数据快照构建器抽取

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/window/window_args.dart`
- Modify: `simple_live_app/lib/app/multiwindow/window/window_open_service.dart`
- Test: `simple_live_app/test/multiwindow/window_args_test.dart`
- Test: `simple_live_app/test/multiwindow/window_open_service_test.dart`

**Interfaces:**
- Produces: `RoomWindowArgs.mainWindowId`（String，缺省 `''`）；`WindowSnapshotBuilder.buildDataSnapshot()` 静态（返回 `WindowSnapshot`，敏感键过滤/白名单规则不变）；`WindowSnapshotBuilder.build(List<TabOpenRequest>, {String mainWindowId = ''})`。
- Consumes: 无（本任务独立于 Task 1，按序执行即可）。

- [ ] **Step 1: 写失败测试**

`test/multiwindow/window_args_test.dart` 末尾 `main()` 内追加：

```dart
  test('mainWindowId：缺省空串、编解码往返、旧参数缺字段兼容', () {
    const withId = RoomWindowArgs(
      tabs: [RoomTabArg(siteId: 'bilibili', roomId: '1')],
      mainWindowId: '7',
    );
    final decoded = RoomWindowArgs.decode(withId.encode());
    expect(decoded.mainWindowId, '7');

    const legacy = RoomWindowArgs(
      tabs: [RoomTabArg(siteId: 'bilibili', roomId: '1')],
    );
    expect(legacy.mainWindowId, '');
    final legacyJson = legacy.toJson()..remove('mainWindowId');
    final decodedLegacy =
        RoomWindowArgs.fromJson(Map<String, dynamic>.from(legacyJson));
    expect(decodedLegacy.mainWindowId, '');
  });
```

`test/multiwindow/window_open_service_test.dart` 的 `main()` 内末尾追加（复用文件顶部已有的 `req` helper 与 setUp 注册的 InMemory 服务）：

```dart
  test('build：mainWindowId 透传；buildDataSnapshot 与 build 同源', () {
    final storage =
        Get.find<LocalStorageService>() as InMemoryLocalStorageService;
    storage.settingsBox.put('ThemeMode', 2);
    storage.shieldBox.put('垃圾词', '垃圾词');

    final args = WindowSnapshotBuilder.build(
      [req('douyin', 'r1')],
      mainWindowId: '42',
    );
    expect(args.mainWindowId, '42');
    expect(args.snapshot.settings['ThemeMode'], 2);
    expect(args.snapshot.shield, contains('垃圾词'));

    final snap = WindowSnapshotBuilder.buildDataSnapshot();
    expect(snap.settings['ThemeMode'], 2);
    expect(snap.shield, contains('垃圾词'));
    expect(snap.volumes, args.snapshot.volumes);
    expect(snap.followShareUrls, args.snapshot.followShareUrls);
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart test/multiwindow/window_open_service_test.dart`
Expected: 编译失败（`mainWindowId`/`buildDataSnapshot` 未定义）。

- [ ] **Step 3: 改 window_args.dart**

`RoomWindowArgs` 构造与字段改为（替换现有 :65-77 构造/toJson 段）：

```dart
class RoomWindowArgs {
  const RoomWindowArgs({
    required this.tabs,
    this.snapshot = const WindowSnapshot(),
    this.mainWindowId = '',
  });

  static const String type = 'room_shell';

  final List<RoomTabArg> tabs;
  final WindowSnapshot snapshot;

  /// 创建该窗的主引擎 windowId（dmw String id）；子窗数据面 IPC 据此回连。
  /// M4-2 前的旧参数无此字段，缺省空串表示不启用写穿（纯快照模式）。
  final String mainWindowId;

  Map<String, dynamic> toJson() => {
        'type': type,
        'tabs': tabs.map((e) => e.toJson()).toList(),
        'snapshot': snapshot.toJson(),
        'mainWindowId': mainWindowId,
      };
```

`fromJson` 的 return（:87-92）改为：

```dart
    return RoomWindowArgs(
      tabs: ((json['tabs'] as List?) ?? const [])
          .map((e) => RoomTabArg.fromJson(e as Map<String, dynamic>))
          .toList(),
      snapshot: WindowSnapshot.fromJson(snapshotJson),
      mainWindowId: (json['mainWindowId'] as String?) ?? '',
    );
```

- [ ] **Step 4: 改 window_open_service.dart**

把 `WindowSnapshotBuilder` 整类替换为下面版本（敏感键常量/方法本任务**原样保留**，Task 3 再迁移）：

```dart
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

  /// 当前主引擎数据面全量快照（开窗参数与 dp_ready 对账共用同一来源）
  static WindowSnapshot buildDataSnapshot() {
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

    return WindowSnapshot(
      settings: settings,
      shield: storage.shieldBox.values.toList(),
      volumes: db.exportVolumes(),
      followShareUrls: db.exportFollowShareUrls(),
    );
  }

  static RoomWindowArgs build(
    List<TabOpenRequest> requests, {
    String mainWindowId = '',
  }) {
    return RoomWindowArgs(
      mainWindowId: mainWindowId,
      tabs: [
        for (final request in requests)
          RoomTabArg(
            siteId: request.siteId,
            roomId: request.roomId,
            shareUrl: request.shareUrl,
          ),
      ],
      snapshot: buildDataSnapshot(),
    );
  }
}
```

`WindowOpenService` 内两处 `WindowSnapshotBuilder.build([request]).encode()`（`openInNewWindow` :129 与 `moveTabToNewWindow` :158）改为：

```dart
WindowSnapshotBuilder.build(
  [request],
  mainWindowId: DmwSubWindowPort.mainWindowId ?? '',
).encode()
```

同目录相对 import 区（:9 `import 'sub_window_port.dart';` 之前按字母序）加：

```dart
import 'dmw_sub_window_port.dart';
```

- [ ] **Step 5: 跑测试 + analyze + 全量**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/window_args_test.dart test/multiwindow/window_open_service_test.dart`
Expected: 全过（现有 16 个 + 新增 2 个）。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 条存量零新增。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（192 + 2 = 194）。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/window/window_args.dart simple_live_app/lib/app/multiwindow/window/window_open_service.dart simple_live_app/test/multiwindow/window_args_test.dart simple_live_app/test/multiwindow/window_open_service_test.dart
git commit -m "feat(multiwindow): 启动参数携带主窗 id，抽 buildDataSnapshot 供开窗与对账共用

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: 数据面 IPC 协议（方法名、载荷编解码、敏感键单一真相）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/data/data_plane_protocol.dart`
- Modify: `simple_live_app/lib/app/multiwindow/window/window_open_service.dart`
- Test: `simple_live_app/test/multiwindow/data_plane_protocol_test.dart`
- Modify: `simple_live_app/test/multiwindow/window_open_service_test.dart`（敏感键断言改引用新位置）

**Interfaces:**
- Produces: `DataPlaneProtocol` 全部方法名/kind/box 常量、`isAllowedValue`、`isSensitiveKey`（17 键+前缀，自 WindowSnapshotBuilder 迁入，单一真相）、`decodeKvSet/decodeKvDelete/kvBoxOf/decodeChanged`、各载荷构造函数；`KvWrite{box,key,value}`、`ChangeEvent{kind,key,value,deleted,clear}`。
- Consumes: 无（纯 Dart，不依赖 dmw）。
- 引用面已 grep 核实（2026-10-16）：`WindowSnapshotBuilder.sensitiveKeys/sensitivePrefix/isSensitiveKey` 全仓仅 window_open_service.dart 自身与 window_open_service_test.dart :230/:231/:247 共 4 处；implementer 动手前必须再 grep 一次确认无新增引用。

- [ ] **Step 1: 写失败测试**

创建 `test/multiwindow/data_plane_protocol_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';

void main() {
  group('载荷构造与解析往返', () {
    test('kvSet/kvDelete/kvClear', () {
      final set = DataPlaneProtocol.kvSet(
          DataPlaneProtocol.boxSettings, 'DanmuSize', 18.0);
      final w = DataPlaneProtocol.decodeKvSet(set);
      expect(w?.box, DataPlaneProtocol.boxSettings);
      expect(w?.key, 'DanmuSize');
      expect(w?.value, 18.0);

      expect(
          DataPlaneProtocol.decodeKvSet(DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxShield, 'w', '词')),
          isNotNull,
          reason: 'shield 的 String 值合法');

      final del =
          DataPlaneProtocol.kvDelete(DataPlaneProtocol.boxShield, 'w');
      final d = DataPlaneProtocol.decodeKvDelete(del);
      expect(d?.box, DataPlaneProtocol.boxShield);
      expect(d?.key, 'w');

      expect(
          DataPlaneProtocol.kvBoxOf(
              DataPlaneProtocol.kvClear(DataPlaneProtocol.boxSettings)),
          DataPlaneProtocol.boxSettings);
    });

    test('changed 构造/解析：普通、删除、清空', () {
      final e = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindVolume, key: 'douyin_1', value: 80.0),
      );
      expect(e?.kind, DataPlaneProtocol.kindVolume);
      expect(e?.key, 'douyin_1');
      expect(e?.value, 80.0);
      expect(e?.deleted, isFalse);
      expect(e?.clear, isFalse);

      final removed = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindFollow,
            key: 'bilibili_2',
            deleted: true),
      );
      expect(removed?.deleted, isTrue);
      expect(removed?.value, isNull);

      final cleared = DataPlaneProtocol.decodeChanged(
        DataPlaneProtocol.changed(
            kind: DataPlaneProtocol.kindShield, key: '', clear: true),
      );
      expect(cleared?.clear, isTrue);
    });
  });

  group('非法载荷拒绝', () {
    test('box 白名单', () {
      expect(DataPlaneProtocol.kvBoxOf({'box': 'history'}), isNull);
      expect(DataPlaneProtocol.kvBoxOf('x'), isNull);
      expect(DataPlaneProtocol.kvBoxOf(null), isNull);
    });

    test('kvSet 值类型白名单', () {
      expect(
          DataPlaneProtocol.decodeKvSet({'box': 'settings', 'key': 'k'}),
          isNull,
          reason: '缺 value');
      expect(
          DataPlaneProtocol.decodeKvSet({
            'box': 'settings',
            'key': 'k',
            'value': ['a']
          }),
          isNull,
          reason: 'List 拒绝');
      expect(
          DataPlaneProtocol.decodeKvSet({
            'box': 'settings',
            'key': 'k',
            'value': {'a': 1}
          }),
          isNull,
          reason: 'Map 拒绝');
      expect(
          DataPlaneProtocol.decodeKvSet(
              {'box': 'shield', 'key': 'k', 'value': 1}),
          isNull,
          reason: 'shield 只接受 String');
      expect(DataPlaneProtocol.decodeKvSet('x'), isNull);
      expect(
          DataPlaneProtocol.decodeKvSet({'box': 'settings', 'key': 1}), isNull,
          reason: 'key 必须是 String');
    });

    test('decodeChanged kind 白名单与 key 类型', () {
      expect(
          DataPlaneProtocol.decodeChanged({'kind': 'history', 'key': 'a'}),
          isNull);
      expect(DataPlaneProtocol.decodeChanged({'kind': 'kv', 'key': 1}), isNull);
      expect(DataPlaneProtocol.decodeChanged(null), isNull);
    });

    test('白名单接受 null/num/String/bool', () {
      for (final v in [null, 0, 1.5, 's', true, false]) {
        expect(
            DataPlaneProtocol.decodeKvSet(DataPlaneProtocol.kvSet(
                DataPlaneProtocol.boxSettings, 'k', v)),
            isNotNull,
            reason: '$v 应合法');
      }
    });
  });

  group('敏感键', () {
    test('17 个具名键全部被识别且数量锚定', () {
      expect(DataPlaneProtocol.sensitiveKeys.length, 17);
      for (final key in DataPlaneProtocol.sensitiveKeys) {
        expect(DataPlaneProtocol.isSensitiveKey(key), isTrue, reason: key);
      }
    });

    test('GuardAccountId_ 前缀与普通键', () {
      expect(DataPlaneProtocol.isSensitiveKey('GuardAccountId_douyin'),
          isTrue);
      expect(DataPlaneProtocol.isSensitiveKey('DanmuSize'), isFalse);
    });
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/data_plane_protocol_test.dart`
Expected: 编译失败（data_plane_protocol.dart 不存在）。

- [ ] **Step 3: 创建协议文件**

`lib/app/multiwindow/data/data_plane_protocol.dart`：

```dart
/// 多窗口数据面 IPC 协议（desktop_multi_window 单通道自定义方法名）。
///
/// 见 spec：docs/10_ai_workflows/superpowers/specs/
/// 2026-10-16-multiwindow-m4-2-data-plane-ipc-design.md §5。
/// 载荷全部为 JSON 兼容类型（Map/List/num/String/bool/null）。
class DataPlaneProtocol {
  DataPlaneProtocol._();

  // —— 子 → 主 方法名 ——
  static const String mReady = 'dp_ready';
  static const String mKvSet = 'dp_kv_set';
  static const String mKvDelete = 'dp_kv_delete';
  static const String mKvClear = 'dp_kv_clear';
  static const String mVolumeSet = 'dp_volume_set';
  static const String mFollowSet = 'dp_follow_set';
  static const String mFollowRemove = 'dp_follow_remove';
  static const String mHistoryAdd = 'dp_history_add';

  // —— 主 → 子 方法名 ——
  static const String mChanged = 'dp_changed';

  // —— KV box 名 ——
  static const String boxSettings = 'settings';
  static const String boxShield = 'shield';
  static const Set<String> boxes = {boxSettings, boxShield};

  // —— 广播 kind ——
  static const String kindKv = 'kv';
  static const String kindShield = 'shield';
  static const String kindVolume = 'volume';
  static const String kindFollow = 'follow';
  static const Set<String> kinds = {
    kindKv,
    kindShield,
    kindVolume,
    kindFollow
  };

  /// 禁止跨窗传播的键：各平台登录凭据、guard 配置/账号、WebDAV、同步信息。
  /// 账号类数据唯一合法通道是 M4-3 的账号面协议。
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

  static const String sensitivePrefix = 'GuardAccountId_';

  static bool isSensitiveKey(String key) =>
      sensitiveKeys.contains(key) || key.startsWith(sensitivePrefix);

  /// JSON 载荷只接受基础类型（List/Map/实体拒绝；显式 null 合法）
  static bool isAllowedValue(Object? value) =>
      value == null || value is num || value is String || value is bool;

  // —— 解析 ——

  static String? kvBoxOf(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    return box is String && boxes.contains(box) ? box : null;
  }

  static KvWrite? decodeKvSet(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    final key = arguments['key'];
    final value = arguments['value'];
    if (box is! String || !boxes.contains(box)) return null;
    if (key is! String) return null;
    if (!isAllowedValue(value)) return null;
    // shield 只接受非空 String（null 也拒：handler 需原样写回屏蔽词）
    if (box == boxShield && value is! String) return null;
    return KvWrite(box, key, value);
  }

  static KvWrite? decodeKvDelete(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    final key = arguments['key'];
    if (box is! String || !boxes.contains(box)) return null;
    if (key is! String) return null;
    return KvWrite(box, key, null);
  }

  static ChangeEvent? decodeChanged(Object? arguments) {
    if (arguments is! Map) return null;
    final kind = arguments['kind'];
    final key = arguments['key'];
    if (kind is! String || !kinds.contains(kind)) return null;
    if (key is! String) return null;
    return ChangeEvent(
      kind: kind,
      key: key,
      value: arguments['value'],
      deleted: arguments['deleted'] == true,
      clear: arguments['clear'] == true,
    );
  }

  // —— 构造 ——

  static Map<String, Object?> kvSet(String box, String key, Object? value) =>
      {'box': box, 'key': key, 'value': value};

  static Map<String, Object?> kvDelete(String box, String key) =>
      {'box': box, 'key': key};

  static Map<String, Object?> kvClear(String box) => {'box': box};

  static Map<String, Object?> volumeSet(String key, double value) =>
      {'key': key, 'value': value};

  static Map<String, Object?> followSet(Map<String, dynamic> followJson) =>
      {'follow': followJson};

  static Map<String, Object?> followRemove(String key) => {'key': key};

  static Map<String, Object?> historyAdd(Map<String, dynamic> historyJson) =>
      {'history': historyJson};

  static Map<String, Object?> changed({
    required String kind,
    required String key,
    Object? value,
    bool deleted = false,
    bool clear = false,
  }) =>
      {
        'kind': kind,
        'key': key,
        if (value != null) 'value': value,
        if (deleted) 'deleted': true,
        if (clear) 'clear': true,
      };
}

/// dp_kv_set / dp_kv_delete 解析结果
class KvWrite {
  const KvWrite(this.box, this.key, this.value);

  final String box;
  final String key;
  final Object? value;
}

/// dp_changed 解析结果
class ChangeEvent {
  const ChangeEvent({
    required this.kind,
    required this.key,
    this.value,
    this.deleted = false,
    this.clear = false,
  });

  final String kind;
  final String key;
  final Object? value;
  final bool deleted;
  final bool clear;
}
```

注意 `volumeSet` 形参为 double；测试传 int 时由调用方 `.toDouble()`（Task 5 handler 统一转）。

- [ ] **Step 4: 迁移敏感键单一真相**

`window_open_service.dart`：
1. 删除 `WindowSnapshotBuilder` 中的 `sensitiveKeys` 常量、`sensitivePrefix` 常量、`isSensitiveKey` 静态方法；`buildDataSnapshot` 中的调用改为 `DataPlaneProtocol.isSensitiveKey(key)`。
2. import 区加（与该文件现有 package: import 同组）：

```dart
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
```

`window_open_service_test.dart`：
- :230、:231、:247 三处 `WindowSnapshotBuilder.sensitiveKeys` 改为 `DataPlaneProtocol.sensitiveKeys`；
- import 区加：

```dart
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
```

- [ ] **Step 5: 门禁**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/data_plane_protocol_test.dart test/multiwindow/window_open_service_test.dart`
Expected: 全过。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（194 + 新文件 8 用例 = 202）。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/data/data_plane_protocol.dart simple_live_app/lib/app/multiwindow/window/window_open_service.dart simple_live_app/test/multiwindow/data_plane_protocol_test.dart simple_live_app/test/multiwindow/window_open_service_test.dart
git commit -m "feat(multiwindow): 数据面 IPC 协议层，敏感键清单迁移为单一真相

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: 子引擎数据面端口与 RemoteKvBox

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/data/sub_data_plane_port.dart`
- Create: `simple_live_app/lib/app/multiwindow/data/remote_kv_box.dart`
- Test: `simple_live_app/test/multiwindow/remote_kv_box_test.dart`

**Interfaces:**
- Produces: `SubDataPlanePort`（抽象，单方法 `Future<Object?> invokeMain(String method, [Object? arguments])`）；同文件 `DmwSubDataPlanePort(String mainWindowId)` 生产实现；`RemoteKvBox<T> implements SeedableKvBox<T>`（构造 `(String boxName, SubDataPlanePort port)`）。
- Consumes: Task 1 `SeedableKvBox`/`MemoryKvBox`、Task 3 `DataPlaneProtocol`。
- 命名注意：本端口在 `app/multiwindow/data/` 目录，与 M4-1 的 `app/multiwindow/window/SubWindowPort`（createRoomWindow/invoke/listWindowIds/windowsChanged）是两个抽象，不要混。

- [ ] **Step 1: 写失败测试**

创建 `test/multiwindow/remote_kv_box_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';

class _RecordingPort implements SubDataPlanePort {
  final List<(String, Object?)> calls = [];
  bool throwOnInvoke = false;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (throwOnInvoke) throw StateError('ipc down');
    return null;
  }
}

void main() {
  test('put 乐观更新立即可见并按协议发 IPC', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);

    await box.put('词', '词');
    expect(box.get('词'), '词');
    expect(port.calls.single.$1, DataPlaneProtocol.mKvSet);
    final payload = port.calls.single.$2! as Map;
    expect(payload['box'], DataPlaneProtocol.boxShield);
    expect(payload['key'], '词');
    expect(payload['value'], '词');
  });

  test('delete 已存在键发 mKvDelete；删不存在键不发', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);

    await box.delete('missing');
    expect(port.calls, isEmpty);

    await box.put('k', 1);
    await box.delete('k');
    expect(port.calls.last.$1, DataPlaneProtocol.mKvDelete);
    expect((port.calls.last.$2! as Map)['key'], 'k');
    expect(box.containsKey('k'), isFalse);
  });

  test('clear 静默清空本地并发单条 mKvClear', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
    await box.put('a', 'a');
    port.calls.clear();
    final n = await box.clear();
    expect(n, 1);
    expect(port.calls.single.$1, DataPlaneProtocol.mKvClear);
    expect(box.values, isEmpty);
  });

  test('seed* 静默：不发任何 IPC', () async {
    final port = _RecordingPort();
    final SeedableKvBox<dynamic> box =
        RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
    box.seedPut('a', 1);
    box.seedReplaceAll({'b': 2});
    await box.seedClear();
    box.seedDelete('b');
    expect(port.calls, isEmpty);
  });

  test('IPC 失败不向调用方抛出，本地乐观值保留', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
    port.throwOnInvoke = true;
    await box.put('a', 1); // 不抛
    expect(box.get('a'), 1, reason: '本地乐观值保留');
  });
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/remote_kv_box_test.dart`
Expected: 编译失败（两个新文件不存在）。

- [ ] **Step 3: 创建端口抽象与 dmw 实现**

`lib/app/multiwindow/data/sub_data_plane_port.dart`：

```dart
import 'package:desktop_multi_window/desktop_multi_window.dart';

/// 子引擎 → 主引擎数据面调用的单一出口。生产走 dmw，测试用内存 fake。
abstract class SubDataPlanePort {
  Future<Object?> invokeMain(String method, [Object? arguments]);
}

class DmwSubDataPlanePort implements SubDataPlanePort {
  DmwSubDataPlanePort(this.mainWindowId);

  final String mainWindowId;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) {
    return WindowController.fromWindowId(mainWindowId)
        .invokeMethod(method, arguments);
  }
}
```

- [ ] **Step 4: 创建 RemoteKvBox**

`lib/app/multiwindow/data/remote_kv_box.dart`：

```dart
import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';

/// 子引擎 KV：读走内存；写先乐观落本地（UI 零延迟、读己之写立即可见），
/// 再 fire-and-forget 写穿主引擎。远端广播只走 seed*（见 SubDataPlaneClient），
/// 不经过这里的 put/delete/clear，故不会回环发 IPC。
class RemoteKvBox<T> implements SeedableKvBox<T> {
  RemoteKvBox(this.boxName, this.port);

  final String boxName;
  final SubDataPlanePort port;
  final MemoryKvBox<T> _local = MemoryKvBox<T>();

  void _fire(String method, Object? arguments) {
    try {
      unawaited(
        port.invokeMain(method, arguments).catchError((Object e) {
          Log.d('数据面写穿失败（已保留本地值）：$boxName - $e');
          return null;
        }),
      );
    } catch (e) {
      Log.d('数据面写穿同步异常：$boxName - $e');
    }
  }

  @override
  T? get(Object key, {T? defaultValue}) =>
      _local.get(key, defaultValue: defaultValue);

  @override
  bool containsKey(Object key) => _local.containsKey(key);

  @override
  Iterable<T> get values => _local.values;

  @override
  Iterable<Object> get keys => _local.keys;

  @override
  Map<Object, T> toMap() => _local.toMap();

  @override
  Future<void> put(Object key, T value) async {
    _local.seedPut(key, value);
    _fire(DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(boxName, key.toString(), value));
  }

  @override
  Future<void> delete(Object key) async {
    // 与 Hive 语义对齐：本地没有的键不产生写穿（子窗内存经 ready 对账是全量）
    if (!_local.containsKey(key)) return;
    _local.seedDelete(key);
    _fire(DataPlaneProtocol.mKvDelete,
        DataPlaneProtocol.kvDelete(boxName, key.toString()));
  }

  @override
  Future<int> clear() async {
    final count = _local.toMap().length;
    await _local.seedClear();
    _fire(DataPlaneProtocol.mKvClear, DataPlaneProtocol.kvClear(boxName));
    return count;
  }

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Stream<KvChange<T>> changes() => _local.changes();

  @override
  void seedPut(Object key, T value) => _local.seedPut(key, value);

  @override
  void seedDelete(Object key) => _local.seedDelete(key);

  @override
  Future<void> seedClear() => _local.seedClear();

  @override
  void seedReplaceAll(Map<Object, T> entries) =>
      _local.seedReplaceAll(entries);
}
```

put/delete/clear 本地侧全部走 seed*（静默）——子窗没有监听 RemoteKvBox.changes 的组件（UI 刷新由 setter 先改 Rx 与 client 防抖 reload 负责），静默可保证「接收广播」与「本地写」两条路径不可区分、无重复事件。

- [ ] **Step 5: 门禁**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/remote_kv_box_test.dart`
Expected: 5 用例全过。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（202 + 5 = 207）。

- [ ] **Step 6: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/data/sub_data_plane_port.dart simple_live_app/lib/app/multiwindow/data/remote_kv_box.dart simple_live_app/test/multiwindow/remote_kv_box_test.dart
git commit -m "feat(multiwindow): 子引擎数据面端口与 RemoteKvBox 乐观写穿

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: 主引擎数据面服务（落盘、watch 扇出、双重敏感守卫、ready 对账）

**Files:**
- Create: `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`
- Test: `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`

**Interfaces:**
- Produces: `MainDataPlaneService extends GetxService`，构造 `{required SubWindowPort port, required WindowRegistry registry, required LocalStorageService storage, required DBService db, void Function()? onSettingsChanged, WindowController? mainController}`；公开 `Future<Object?> handleCall(String method, Object? arguments)`（onInit 挂到 mainController，测试直调）。
- Consumes: Task 1 KvBox.changes；Task 2 `WindowSnapshotBuilder.buildDataSnapshot()`；Task 3 协议；M4-1 的 `SubWindowPort`/`WindowRegistry`。
- 关键语义（spec §6 + Global Constraints 安全补网）：watch 是扇出唯一出口；`_remoteWrite` 标志仅在远程写期间为 true（同步 try/finally 覆盖通知），此时段事件额外调度主窗防抖 reload；远程 clear 用 `_suppressed` 抑制逐 key 扇出、改发单条 clear:true 并调度一次 reload；history 不订阅不广播；follow 写 handler 显式 EventBus.emit；扇出逐窗 try/catch；**kv 扇出侧过滤敏感键与非白名单值；set/delete 写入侧均拒绝敏感键**。

- [ ] **Step 1: 写失败测试**

创建 `test/multiwindow/main_data_plane_service_test.dart`：

```dart
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/main_data_plane_service.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

class _FakePort implements SubWindowPort {
  _FakePort({this.throwingWindow});
  final String? throwingWindow;
  final List<(String windowId, String method, Object? args)> calls = [];

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async =>
      const SubWindowHandle('x');

  @override
  Future<void> invoke(String windowId, String method, Object? arguments) async {
    calls.add((windowId, method, arguments));
    if (windowId == throwingWindow) throw StateError('window gone');
  }

  @override
  Future<List<String>> listWindowIds() async => const [];

  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();
}

void main() {
  late LocalStorageService storage;
  late DBService db;
  late _FakePort port;
  late WindowRegistry registry;
  late int reloadCount;
  late MainDataPlaneService svc;

  void bootstrap() {
    storage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort();
    registry = WindowRegistry(mainWindowId: 'main');
    registry.registerChild('w1', {'douyin_r1'});
    reloadCount = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () => reloadCount++,
    );
    svc.onInit();
  }

  tearDown(() {
    svc.onClose();
    Get.reset();
  });

  Future<Object?> call(String method, Object? args) =>
      svc.handleCall(method, args);

  /// 远程写会挂 100ms 防抖 Timer，用例末尾排空避免 pending timer
  Future<void> flushReloadTimer() =>
      Future<void>.delayed(const Duration(milliseconds: 120));

  List<(String, Object?)> changedCalls() => port.calls
      .where((c) => c.$2 == DataPlaneProtocol.mChanged)
      .map((c) => (c.$1, c.$3))
      .toList();

  test('dp_ready 返回当前数据面快照（敏感键已过滤）', () async {
    bootstrap();
    await storage.setValue('ThemeMode', 2);
    await storage.setValue('DouyinLoginCookie', 'secret');
    await db.addOrUpdateVolume('douyin_r1', 66.0);

    final raw = (await call(DataPlaneProtocol.mReady, null)) as Map;
    expect(raw['settings']['ThemeMode'], 2);
    expect(raw['settings'].containsKey('DouyinLoginCookie'), isFalse);
    expect((raw['volumes'] as Map)['douyin_r1'], 66.0);
  });

  test('dp_kv_set 落盘并扇出 changed；敏感键与非法载荷拒绝', () async {
    bootstrap();
    final ok = await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 20.0));
    expect(ok, isTrue);
    expect(storage.getValue('DanmuSize', 0.0), 20.0);

    final denied = await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DouyinCookie', 'x'));
    expect(denied, isFalse);
    expect(storage.settingsBox.containsKey('DouyinCookie'), isFalse);

    final bad = await call(DataPlaneProtocol.mKvSet, {'box': 'settings'});
    expect(bad, isFalse);

    final changed = changedCalls();
    expect(changed.length, 1, reason: '仅合法写入扇出一条');
    final payload = changed.single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindKv);
    expect(payload['key'], 'DanmuSize');
    expect(payload['value'], 20.0);
    await flushReloadTimer();
  });

  test('dp_kv_delete 敏感键拒绝；主窗本地写敏感键不扇出（双侧守卫）',
      () async {
    bootstrap();
    await storage.settingsBox.put('DouyinLoginCookie', 'secret');
    port.calls.clear();

    final denied = await call(
        DataPlaneProtocol.mKvDelete,
        DataPlaneProtocol.kvDelete(
            DataPlaneProtocol.boxSettings, 'DouyinLoginCookie'));
    expect(denied, isFalse);
    expect(storage.settingsBox.containsKey('DouyinLoginCookie'), isTrue);

    await storage.settingsBox.put('GuardAccountId_douyin', 'acct');
    expect(changedCalls(), isEmpty);
    expect(reloadCount, 0, reason: '本地写不触发 owner reload');
  });

  test('dp_kv_clear 抑制逐 key 扇出，只发一条 clear 并落盘', () async {
    bootstrap();
    await storage.shieldBox.put('a', 'a');
    await storage.shieldBox.put('b', 'b');
    port.calls.clear();

    final r = await call(
        DataPlaneProtocol.mKvClear,
        DataPlaneProtocol.kvClear(DataPlaneProtocol.boxShield));
    expect(r, isTrue);
    expect(storage.shieldBox.values, isEmpty);

    final changed = changedCalls();
    expect(changed.length, 1);
    final payload = changed.single.$2! as Map;
    expect(payload['clear'], isTrue);
    expect(payload['kind'], DataPlaneProtocol.kindShield);
    await flushReloadTimer();
  });

  test('dp_kv_clear settings 被拒：主窗凭据与普通键都不动、不扇出',
      () async {
    bootstrap();
    await storage.settingsBox.put('DouyinLoginCookie', 'secret');
    await storage.settingsBox.put('DanmuSize', 18.0);
    port.calls.clear();

    final r = await call(
        DataPlaneProtocol.mKvClear,
        DataPlaneProtocol.kvClear(DataPlaneProtocol.boxSettings));
    expect(r, isFalse);
    expect(storage.settingsBox.containsKey('DouyinLoginCookie'), isTrue);
    expect(storage.settingsBox.containsKey('DanmuSize'), isTrue);
    expect(changedCalls(), isEmpty, reason: '拒绝不落盘不扇出');
  });

  test('dp_volume_set 落每房音量并广播 double', () async {
    bootstrap();
    final r = await call(
        DataPlaneProtocol.mVolumeSet,
        DataPlaneProtocol.volumeSet('huya_9', 42));
    expect(r, isTrue);
    expect(db.getVolume('huya_9'), 42.0);
    final payload = changedCalls().single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindVolume);
    expect(payload['value'], 42.0);
    await flushReloadTimer();
  });

  test('dp_follow_set/remove：落盘、广播 shareUrl、发关注更新事件', () async {
    bootstrap();
    final events = <Object?>[];
    final sub = EventBus.instance
        .listen(Constant.kUpdateFollow, (p0) => events.add(p0));
    addTearDown(sub.cancel);

    final follow = FollowUser(
      id: 'bilibili_3',
      roomId: '3',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://3',
    );
    expect(
        await call(DataPlaneProtocol.mFollowSet,
            DataPlaneProtocol.followSet(follow.toJson())),
        isTrue);
    expect(db.getFollowExist('bilibili_3'), isTrue);
    expect(events, contains('bilibili_3'));

    var payload = changedCalls().single.$2! as Map;
    expect(payload['kind'], DataPlaneProtocol.kindFollow);
    expect(payload['key'], 'bilibili_3');
    expect(payload['value'], 'http://3');

    port.calls.clear();
    expect(
        await call(DataPlaneProtocol.mFollowRemove,
            DataPlaneProtocol.followRemove('bilibili_3')),
        isTrue);
    expect(db.getFollowExist('bilibili_3'), isFalse);
    payload = changedCalls().single.$2! as Map;
    expect(payload['deleted'], isTrue);
    await flushReloadTimer();
  });

  test('dp_follow_set 坏 JSON 返回 false 不抛', () async {
    bootstrap();
    final r =
        await call(DataPlaneProtocol.mFollowSet, {'follow': {'id': 1}});
    expect(r, isFalse);
  });

  test('dp_history_add 落盘但不广播', () async {
    bootstrap();
    final r = await call(
        DataPlaneProtocol.mHistoryAdd,
        DataPlaneProtocol.historyAdd(History(
          id: 'douyin_8',
          roomId: '8',
          siteId: 'douyin',
          userName: 'u',
          face: '',
          updateTime: DateTime(2026),
        ).toJson()));
    expect(r, isTrue);
    expect(db.getHistory('douyin_8'), isNotNull);
    expect(changedCalls(), isEmpty);
  });

  test('远程写防抖合并触发一次主窗 reload；本地写不触发', () {
    fakeAsync((async) {
      bootstrap();
      unawaited(svc.handleCall(
          DataPlaneProtocol.mKvSet,
          DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxSettings, 'a', 1)));
      unawaited(svc.handleCall(
          DataPlaneProtocol.mKvSet,
          DataPlaneProtocol.kvSet(
              DataPlaneProtocol.boxSettings, 'b', 2)));
      async.elapse(const Duration(milliseconds: 50));
      expect(reloadCount, 0);
      async.elapse(const Duration(milliseconds: 80));
      expect(reloadCount, 1, reason: '100ms 防抖合并为一次');

      // 本地写：扇出但不 reload
      storage.settingsBox.put('c', 3);
      async.elapse(const Duration(milliseconds: 200));
      expect(reloadCount, 1);
    });
  });

  test('扇出途中某窗失败不阻断其余窗', () async {
    storage = LocalStorageService()
      ..settingsBox = MemoryKvBox<dynamic>()
      ..shieldBox = MemoryKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = MemoryKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = MemoryKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort(throwingWindow: 'w1');
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'})
      ..registerChild('w2', {'b'});
    reloadCount = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () => reloadCount++,
    );
    svc.onInit();

    await svc.handleCall(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 1.0));
    await flushReloadTimer();
    final windows = changedCalls().map((c) => c.$1).toSet();
    expect(windows, containsAll({'w1', 'w2'}));
  });
}
```

注意 `changedCalls()` 用 `(String, Object?)` 记录，windowId 在元组第 1 位。

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: 编译失败（MainDataPlaneService 不存在）。

- [ ] **Step 3: 实现**

`lib/app/multiwindow/data/main_data_plane_service.dart`：

```dart
import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:get/get.dart';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 主引擎数据面：收子窗写请求落真实 Hive，订阅真实 box 变更流统一扇出广播。
/// watch 是扇出唯一出口（主窗本地写与子窗写穿落盘都经过它），handler 不另发广播。
class MainDataPlaneService extends GetxService {
  MainDataPlaneService({
    required this.port,
    required this.registry,
    required this.storage,
    required this.db,
    this.onSettingsChanged,
    this.mainController,
  });

  final SubWindowPort port;
  final WindowRegistry registry;
  final LocalStorageService storage;
  final DBService db;
  final void Function()? onSettingsChanged;
  final WindowController? mainController;

  final List<StreamSubscription<dynamic>> _subs = [];
  final Set<String> _suppressed = <String>{};
  bool _remoteWrite = false;
  Timer? _reloadTimer;
  bool _closed = false;

  static const Duration _reloadDebounce = Duration(milliseconds: 100);

  @override
  void onInit() {
    super.onInit();
    _subs.add(storage.settingsBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindKv, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(storage.shieldBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindShield, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(db.volumeBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindVolume, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(db.followBox.changes().listen(_onFollowChange));
    mainController?.setWindowMethodHandler(
        (call) => handleCall(call.method, call.arguments));
  }

  @override
  void onClose() {
    _closed = true;
    _reloadTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.onClose();
  }

  void _onFollowChange(KvChange<FollowUser> c) {
    final follow = c.value;
    _onBoxChange(
      DataPlaneProtocol.kindFollow,
      c.key.toString(),
      follow?.shareUrl,
      deleted: c.deleted || follow == null,
    );
  }

  void _onBoxChange(String kind, String key, Object? value,
      {required bool deleted}) {
    if (_suppressed.contains(kind)) return;
    if (kind == DataPlaneProtocol.kindKv) {
      // 扇出侧守卫：主窗本地登录等敏感写入也不得进入子引擎
      if (DataPlaneProtocol.isSensitiveKey(key)) return;
      if (!DataPlaneProtocol.isAllowedValue(value)) return;
    }
    _fanout(DataPlaneProtocol.changed(
        kind: kind, key: key, value: value, deleted: deleted));
    if (_remoteWrite) _scheduleReload();
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, () {
      if (!_closed) onSettingsChanged?.call();
    });
  }

  void _fanout(Map<String, Object?> payload) {
    for (final windowId in registry.childWindowIds) {
      try {
        unawaited(port
            .invoke(windowId, DataPlaneProtocol.mChanged, payload)
            .catchError((Object e) => null));
      } catch (e) {
        Log.d('数据面广播失败：$windowId - $e');
      }
    }
  }

  KvBox<dynamic> _kvBox(String name) => name == DataPlaneProtocol.boxShield
      ? storage.shieldBox
      : storage.settingsBox;

  Future<void> _withRemoteFlag(Future<void> Function() action) async {
    _remoteWrite = true;
    try {
      await action();
    } finally {
      _remoteWrite = false;
    }
  }

  /// 主窗 method handler 入口（onInit 挂到 mainController；测试直接调）
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case DataPlaneProtocol.mReady:
        return WindowSnapshotBuilder.buildDataSnapshot().toJson();

      case DataPlaneProtocol.mKvSet:
        final w = DataPlaneProtocol.decodeKvSet(arguments);
        if (w == null) return false;
        // 写入侧守卫：敏感键不落盘、不扇出
        if (w.box == DataPlaneProtocol.boxSettings &&
            DataPlaneProtocol.isSensitiveKey(w.key)) {
          Log.d('数据面拒绝敏感键写穿：${w.key}');
          return false;
        }
        await _withRemoteFlag(() async {
          if (w.box == DataPlaneProtocol.boxShield) {
            await storage.shieldBox.put(w.key, w.value as String);
          } else {
            await storage.settingsBox.put(w.key, w.value);
          }
        });
        return true;

      case DataPlaneProtocol.mKvDelete:
        final w = DataPlaneProtocol.decodeKvDelete(arguments);
        if (w == null) return false;
        // 删除侧同样守敏感键：游客子窗不得删除主窗凭据
        if (w.box == DataPlaneProtocol.boxSettings &&
            DataPlaneProtocol.isSensitiveKey(w.key)) {
          Log.d('数据面拒绝敏感键删除：${w.key}');
          return false;
        }
        await _withRemoteFlag(() => _kvBox(w.box).delete(w.key));
        return true;

      case DataPlaneProtocol.mKvClear:
        final boxName = DataPlaneProtocol.kvBoxOf(arguments);
        if (boxName == null) return false;
        // settings 投影箱无差别 clear 会删掉主窗凭据：子箱从不持有敏感键，
        // 子窗也没有 settingsBox.clear 业务入口（仅主窗 WebDAV 恢复/重置深
        // 路由可达，M4-3 收口），故整箱清空一律拒绝；shield 无敏感键放行。
        if (boxName == DataPlaneProtocol.boxSettings) {
          Log.d('数据面拒绝 settings 整箱清空（凭据安全）');
          return false;
        }
        const kind = DataPlaneProtocol.kindShield;
        _suppressed.add(kind);
        try {
          await _kvBox(boxName).clear();
          // R-10：Hive BoxBaseImpl.clear 先 await backend 后同步 keystore.notify，
          // 逐 key 事件经 async broadcast 以 microtask 链式重排，而 await 链同步
          // 坍缩会使 finally 早于它们执行；排空一个事件轮次再解除抑制。
          // MemoryKvBox 为 sync 广播，此处空等。
          await Future<void>.delayed(Duration.zero);
        } finally {
          _suppressed.remove(kind);
        }
        _fanout(DataPlaneProtocol.changed(kind: kind, key: '', clear: true));
        _scheduleReload();
        return true;

      case DataPlaneProtocol.mVolumeSet:
        if (arguments is! Map) return false;
        final key = arguments['key'];
        final value = arguments['value'];
        if (key is! String || value is! num) return false;
        await _withRemoteFlag(
            () => db.addOrUpdateVolume(key, value.toDouble()));
        return true;

      case DataPlaneProtocol.mFollowSet:
        final FollowUser follow;
        try {
          if (arguments is! Map || arguments['follow'] is! Map) return false;
          follow = FollowUser.fromJson(
              Map<String, dynamic>.from(arguments['follow'] as Map));
        } catch (e) {
          Log.d('dp_follow_set 载荷解析失败：$e');
          return false;
        }
        await _withRemoteFlag(() => db.addFollow(follow));
        EventBus.instance.emit(Constant.kUpdateFollow, follow.id);
        return true;

      case DataPlaneProtocol.mFollowRemove:
        if (arguments is! Map || arguments['key'] is! String) return false;
        final key = arguments['key'] as String;
        await _withRemoteFlag(() => db.deleteFollow(key));
        EventBus.instance.emit(Constant.kUpdateFollow, key);
        return true;

      case DataPlaneProtocol.mHistoryAdd:
        try {
          if (arguments is! Map || arguments['history'] is! Map) return false;
          final history = History.fromJson(
              Map<String, dynamic>.from(arguments['history'] as Map));
          await db.addOrUpdateHistory(history);
        } catch (e) {
          Log.d('dp_history_add 载荷解析失败：$e');
          return false;
        }
        return true;

      default:
        return null;
    }
  }
}
```

- [ ] **Step 4: 跑测试 + 门禁**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: 12 用例全过（修复轮 R-10：评审真实 Hive 取证发现 clear 风暴抑制在异步后端失效，新增 1 个真实 Hive temp dir 回归用例；原简报 11 个）。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（207 + 12 = 219）。

- [ ] **Step 5: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart simple_live_app/test/multiwindow/main_data_plane_service_test.dart
git commit -m "feat(multiwindow): 主引擎数据面服务——落盘/watch 扇出/双重敏感守卫/ready 对账

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: registry 房间键查询 + 子引擎接收侧（InMemory 写穿、SubDataPlaneClient）

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/shell/room_controller_registry.dart`
- Modify: `simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart`
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/in_memory_services.dart`
- Create: `simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart`
- Test: `simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`
- Modify: `simple_live_app/test/multiwindow/in_memory_services_test.dart`（第 3 个 test 改为写穿断言）
- Modify: `simple_live_app/test/multiwindow/window_open_service_test.dart`（FakeRegistry 补接口方法）
- Modify: `simple_live_app/test/tab_store_test.dart`（FakeRegistry、ThrowingRegistry 补接口方法）

**Interfaces:**
- Produces: `RoomControllerRegistry.controllerForRoomKey(String roomKey)` → `LiveRoomController?`；`InMemoryDBService({SubDataPlanePort? dataPort})` + 静默种子 `seedVolume/seedVolumesClear/seedFollowShare/seedFollowRemove/seedDataSnapshot`；`SubDataPlaneClient({required port, required SeedableKvBox<dynamic> settings, required SeedableKvBox<String> shield, required InMemoryDBService db, required RoomControllerRegistry registry, required void Function() onSettingsChanged})`，方法 `Future<void> reconcile()`、`void handleChanged(Object?)`。
- Consumes: Task 1-5 全部产物。
- 顺序要求：先做 Step 1（接口扩展 + 3 处既有 fake 补方法）恢复全量编译，再做后续。

- [ ] **Step 1: 扩展 registry 接口、实现与全部既有 fake**

`lib/app/multiwindow/shell/room_controller_registry.dart` 整文件替换：

```dart
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

import 'tab_open_request.dart';

/// 标签 tabId → LiveRoomController 实例的注册抽象，
/// 生产实现用 GetX tag 容器，测试用内存假实现
abstract class RoomControllerRegistry {
  void register(String tabId, TabOpenRequest request);
  void unregister(String tabId);
  bool isRegistered(String tabId);

  /// 按跨窗去重键（siteId_roomId）找本引擎现存房间控制器，无则 null
  LiveRoomController? controllerForRoomKey(String roomKey);
}
```

`lib/app/multiwindow/shell/getx_room_controller_registry.dart` 整文件替换：

```dart
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class GetxRoomControllerRegistry implements RoomControllerRegistry {
  final Map<String, String> _roomKeyToTab = {};

  @override
  void register(String tabId, TabOpenRequest request) {
    final site = Sites.allSites[request.siteId];
    if (site == null) {
      throw ArgumentError('unknown site: ${request.siteId}');
    }
    // permanent: true——标签生命周期独立于任一路由。否则在搜索/历史/工具箱/
    // 分类详情等压栈路由内打开的标签，其控制器会被 GetX 绑定到该路由，
    // 用户侧键退出入口页时被连带 Get.delete（真退房/停心跳/销毁播放器），
    // 而标签描述符与 IndexedStack 中的页面仍在，形成死标签。
    Get.put(
      LiveRoomController(
        pSite: site,
        pRoomId: request.roomId,
        pShareUrl: request.shareUrl,
        tabId: tabId,
      ),
      tag: tabId,
      permanent: true,
    );
    _roomKeyToTab[request.key] = tabId;
  }

  @override
  void unregister(String tabId) {
    // permanent 实例必须 force 才能删除，否则关标签/closeAll 会永久泄漏
    Get.delete<LiveRoomController>(tag: tabId, force: true);
    _roomKeyToTab.removeWhere((key, value) => value == tabId);
  }

  @override
  bool isRegistered(String tabId) {
    return Get.isRegistered<LiveRoomController>(tag: tabId);
  }

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) {
    final tabId = _roomKeyToTab[roomKey];
    if (tabId == null ||
        !Get.isRegistered<LiveRoomController>(tag: tabId)) {
      return null;
    }
    return Get.find<LiveRoomController>(tag: tabId);
  }
}
```

三处既有 fake 补实现（只加方法，不动其他代码）：

`test/multiwindow/window_open_service_test.dart` 的 `FakeRegistry`（:19-28）内加：

```dart
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
```

并加 import：

```dart
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
```

`test/tab_store_test.dart` 的 `FakeRegistry`（:9-18）与 `ThrowingRegistry`（:21-29）各加同一方法：

```dart
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
```

（`FakeThenThrowRegistry` 继承 FakeRegistry，无需改。）并加 import：

```dart
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
```

Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增（此时无新测试，只验证接口扩展不破坏既有编译）。

- [ ] **Step 2: 写失败测试**

创建 `test/multiwindow/sub_data_plane_client_test.dart`：

```dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_client.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';

class _FakePort implements SubDataPlanePort {
  Object? readyResult;
  bool throwOnReady = false;
  final List<(String, Object?)> calls = [];

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (method == DataPlaneProtocol.mReady) {
      if (throwOnReady) throw StateError('main gone');
      return readyResult;
    }
    return null;
  }
}

class _FakeRegistry implements RoomControllerRegistry {
  LiveRoomController? controller;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => controller;
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
}

void main() {
  tearDown(() {
    Get.reset();
  });

  test('reconcile：dp_ready 快照全量替换并防抖 reload 一次', () {
    fakeAsync((async) {
      final port = _FakePort()
        ..readyResult = {
          'settings': {'DanmuSize': 22.0},
          'shield': ['词'],
          'volumes': {'douyin_1': 11.0},
          'followShareUrls': {'douyin_1': 'http://x'},
        };
      final db = InMemoryDBService();
      final settings =
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
      final shield = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
      var reloads = 0;
      final client = SubDataPlaneClient(
        port: port,
        settings: settings,
        shield: shield,
        db: db,
        registry: _FakeRegistry(),
        onSettingsChanged: () => reloads++,
      );

      client.reconcile();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 120));

      expect(settings.get('DanmuSize'), 22.0);
      expect(shield.values, contains('词'));
      expect(db.getVolume('douyin_1'), 11.0);
      expect(db.getFollowShareUrl('douyin_1'), 'http://x');
      expect(reloads, 1);
      // 播种不产生写穿回环
      expect(port.calls.map((c) => c.$1), [DataPlaneProtocol.mReady]);
    });
  });

  test('reconcile 失败不抛、沿用启动快照', () async {
    final port = _FakePort()..throwOnReady = true;
    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: InMemoryDBService(),
      registry: _FakeRegistry(),
      onSettingsChanged: () {},
    );
    await client.reconcile(); // 不抛
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });

  test('handleChanged：kv/shield 静默落本地、防抖合并 reload、不回发 IPC', () {
    fakeAsync((async) {
      final port = _FakePort();
      final settings =
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
      final shield = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
      var reloads = 0;
      final client = SubDataPlaneClient(
        port: port,
        settings: settings,
        shield: shield,
        db: InMemoryDBService(),
        registry: _FakeRegistry(),
        onSettingsChanged: () => reloads++,
      );

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv, key: 'DanmuSize', value: 18.0));
      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindShield, key: '词', value: '词'));
      expect(settings.get('DanmuSize'), 18.0);
      expect(shield.get('词'), '词');
      async.elapse(const Duration(milliseconds: 120));
      expect(reloads, 1, reason: '两事件防抖合并');

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv, key: 'DanmuSize', deleted: true));
      expect(settings.containsKey('DanmuSize'), isFalse);

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindShield, key: '', clear: true));
      expect(shield.values, isEmpty);
      async.elapse(const Duration(milliseconds: 120));

      expect(port.calls, isEmpty, reason: '接收侧绝不回发 IPC');
    });
  });

  test('handleChanged：volume/follow 分流；follow 定向刷当前房间按钮',
      () {
    final port = _FakePort();
    final db = InMemoryDBService();
    Get.put<DBService>(db, permanent: true);
    final registry = _FakeRegistry();
    // LiveRoomController 构造体会调 DBService.instance 回填 shareUrl，
    // 故必须先注册 DBService；不调 onInit（不进房、不播流、无 Timer）
    final controller = LiveRoomController(
      pSite: Sites.allSites['bilibili']!,
      pRoomId: '5',
      pShareUrl: '',
      tabId: 't1',
    );
    registry.controller = controller;

    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: db,
      registry: registry,
      onSettingsChanged: () {},
    );

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindVolume,
        key: 'bilibili_5',
        value: 33.0));
    expect(db.getVolume('bilibili_5'), 33.0);

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindFollow,
        key: 'bilibili_5',
        value: 'http://5'));
    expect(db.getFollowExist('bilibili_5'), isTrue);
    expect(controller.followed.value, isTrue);

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindFollow,
        key: 'bilibili_5',
        deleted: true));
    expect(db.getFollowExist('bilibili_5'), isFalse);
    expect(controller.followed.value, isFalse);
  });

  test('handleChanged：坏载荷忽略', () {
    final port = _FakePort();
    final client = SubDataPlaneClient(
      port: port,
      settings: RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: InMemoryDBService(),
      registry: _FakeRegistry(),
      onSettingsChanged: () {},
    );
    client.handleChanged(null);
    client.handleChanged({'kind': 'nope'});
    expect(port.calls, isEmpty);
  });
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart`
Expected: 编译失败（SubDataPlaneClient 不存在、InMemoryDBService 无新构造/种子方法）。

- [ ] **Step 4: InMemory 写穿改造（整文件替换）**

整文件替换 `lib/app/multiwindow/bootstrap/in_memory_services.dart` 为：

```dart
import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 子引擎专用：纯内存 LocalStorage，按启动快照播种，init() 不打开 Hive。
/// settings/shield box 由装配层注入 RemoteKvBox（写穿）；缺省回退纯内存。
class InMemoryLocalStorageService extends LocalStorageService {
  InMemoryLocalStorageService({
    KvBox<dynamic>? settingsBox,
    KvBox<String>? shieldBox,
  }) {
    this.settingsBox = settingsBox ?? MemoryKvBox<dynamic>();
    this.shieldBox = shieldBox ?? MemoryKvBox<String>();
  }

  @override
  Future<void> init() async {}

  /// 无主窗 id 的回退路径（纯快照模式）；写穿路径由装配层直接 seedReplaceAll
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
/// 音量/标签/历史走内存 box；装配 dataPort 后 follow/volume/history 写穿主引擎。
class InMemoryDBService extends DBService {
  InMemoryDBService({SubDataPlanePort? dataPort}) : _dataPort = dataPort {
    historyBox = _history;
    followBox = _follow;
    tagBox = _tag;
    volumeBox = _volume;
  }

  final SubDataPlanePort? _dataPort;

  final MemoryKvBox<History> _history = MemoryKvBox<History>();
  final MemoryKvBox<FollowUser> _follow = MemoryKvBox<FollowUser>();
  final MemoryKvBox<FollowUserTag> _tag = MemoryKvBox<FollowUserTag>();
  final MemoryKvBox<double> _volume = MemoryKvBox<double>();

  final Map<String, String> _followShareUrls = {};

  @override
  Future<void> init() async {}

  void applySnapshot(WindowSnapshot snapshot) {
    seedDataSnapshot(snapshot);
  }

  /// dp_ready 对账/启动快照：静默全量替换（不发 IPC、不依赖广播）
  void seedDataSnapshot(WindowSnapshot snapshot) {
    _volume.seedReplaceAll(Map<Object, double>.of(snapshot.volumes));
    _followShareUrls
      ..clear()
      ..addAll(snapshot.followShareUrls);
  }

  // —— 广播种子（SubDataPlaneClient 调用，静默）——

  void seedVolume(String key, double? value, {bool deleted = false}) {
    if (deleted) {
      _volume.seedDelete(key);
    } else if (value != null) {
      _volume.seedPut(key, value);
    }
  }

  void seedVolumesClear() {
    unawaited(_volume.seedClear());
  }

  void seedFollowShare(String key, String shareUrl) {
    _followShareUrls[key] = shareUrl;
  }

  void seedFollowRemove(String key) {
    _followShareUrls.remove(key);
  }

  void _fire(String method, Object? arguments) {
    final port = _dataPort;
    if (port == null) return;
    try {
      unawaited(port.invokeMain(method, arguments).catchError((Object e) {
        Log.d('数据面写穿失败（本地已生效）：$method - $e');
        return null;
      }));
    } catch (e) {
      Log.d('数据面写穿同步异常：$method - $e');
    }
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
    follow.shareUrl = share;
    _fire(DataPlaneProtocol.mFollowSet,
        DataPlaneProtocol.followSet(follow.toJson()));
  }

  @override
  Future<void> updateFollow(FollowUser follow) => addFollow(follow);

  @override
  Future<void> deleteFollow(String id) async {
    _followShareUrls.remove(id);
    _fire(DataPlaneProtocol.mFollowRemove,
        DataPlaneProtocol.followRemove(id));
  }

  @override
  Future<void> addOrUpdateVolume(String id, double volume) async {
    _volume.seedPut(id, volume);
    _fire(DataPlaneProtocol.mVolumeSet,
        DataPlaneProtocol.volumeSet(id, volume));
  }

  @override
  Future<void> addOrUpdateHistory(History history) async {
    _history.seedPut(history.id, history);
    _fire(DataPlaneProtocol.mHistoryAdd,
        DataPlaneProtocol.historyAdd(history.toJson()));
  }
}
```

- [ ] **Step 5: 创建 SubDataPlaneClient**

`lib/app/multiwindow/data/sub_data_plane_client.dart`：

```dart
import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';

/// 子引擎数据面客户端：dp_ready 对账、dp_changed 分流、设置防抖 reload、
/// 关注按钮定向刷新。所有写入都先在本地乐观生效（RemoteKvBox/InMemoryDB），
/// 本类只接收，绝不向主窗回发 changed，无回环。
class SubDataPlaneClient {
  SubDataPlaneClient({
    required this.port,
    required this.settings,
    required this.shield,
    required this.db,
    required this.registry,
    required this.onSettingsChanged,
  });

  final SubDataPlanePort port;
  final SeedableKvBox<dynamic> settings;
  final SeedableKvBox<String> shield;
  final InMemoryDBService db;
  final RoomControllerRegistry registry;
  final void Function() onSettingsChanged;

  Timer? _reloadTimer;

  static const Duration _reloadDebounce = Duration(milliseconds: 100);

  /// 开窗后一次性对账：拉主窗当前全量数据，全量替换本地数据面
  Future<void> reconcile() async {
    try {
      final raw = await port.invokeMain(DataPlaneProtocol.mReady);
      if (raw is! Map) return;
      final snapshot =
          WindowSnapshot.fromJson(Map<String, dynamic>.from(raw));
      settings.seedReplaceAll(Map<Object, dynamic>.of(snapshot.settings));
      shield.seedReplaceAll(
          <Object, String>{for (final word in snapshot.shield) word: word});
      db.seedDataSnapshot(snapshot);
      // R-11：spec §6.4 要求对账在 open tabs 前完成 reload（非防抖）——
      // 播放器后端/硬解/弹幕开关/自动退出等在控制器与播放器构建期一次性捕获，
      // 防抖 100ms 会晚于首批房间构建，使这些设置整房陈旧。
      _reloadTimer?.cancel();
      onSettingsChanged();
    } catch (e) {
      // 主窗不可达时沿用启动快照（主窗关闭=整个应用退出，此路径实际不可达）
      Log.d('dp_ready 对账失败，沿用启动快照：$e');
    }
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, onSettingsChanged);
  }

  void _applySeed(SeedableKvBox<dynamic> box, ChangeEvent e) {
    if (e.clear) {
      unawaited(box.seedClear());
    } else if (e.deleted) {
      box.seedDelete(e.key);
    } else {
      box.seedPut(e.key, e.value);
    }
  }

  /// 总 handler 的 dp_changed 分支调用
  void handleChanged(Object? arguments) {
    final e = DataPlaneProtocol.decodeChanged(arguments);
    if (e == null) return;
    switch (e.kind) {
      case DataPlaneProtocol.kindKv:
        _applySeed(settings, e);
        _scheduleReload();
      case DataPlaneProtocol.kindShield:
        if (e.clear) {
          unawaited(shield.seedClear());
        } else if (e.deleted) {
          shield.seedDelete(e.key);
        } else if (e.value is String) {
          shield.seedPut(e.key, e.value as String);
        }
        _scheduleReload();
      case DataPlaneProtocol.kindVolume:
        if (e.clear) {
          db.seedVolumesClear();
        } else {
          final value = e.value;
          db.seedVolume(e.key, value is num ? value.toDouble() : null,
              deleted: e.deleted || value == null);
        }
      case DataPlaneProtocol.kindFollow:
        if (e.deleted) {
          db.seedFollowRemove(e.key);
        } else {
          db.seedFollowShare(e.key, e.value?.toString() ?? '');
        }
        registry.controllerForRoomKey(e.key)?.followed.value = !e.deleted;
    }
  }
}
```

- [ ] **Step 6: 更新既有 in_memory 测试第 3 个 test**

`test/multiwindow/in_memory_services_test.dart`：
- import 区加 3 条：

```dart
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/models/db/history.dart';
```

- `main()` 上方加 fake：

```dart
class _RecordingDataPort implements SubDataPlanePort {
  final List<(String, Object?)> calls = [];
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    return null;
  }
}
```

- 把第 3 个 test（:38-55 `InMemoryDBService：子窗内关注写操作只在本窗生效，不触碰 Hive`）整段替换为：

```dart
  test('InMemoryDBService：关注/音量/历史写本地且写穿主窗；无 port 纯内存',
      () async {
    final port = _RecordingDataPort();
    final db = InMemoryDBService(dataPort: port);
    await db.addFollow(FollowUser(
      id: 'bilibili_9',
      roomId: '9',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
      shareUrl: 'http://9',
    ));
    expect(db.getFollowExist('bilibili_9'), isTrue);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mFollowSet), isTrue);

    await db.deleteFollow('bilibili_9');
    expect(db.getFollowExist('bilibili_9'), isFalse);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mFollowRemove), isTrue);

    await db.addOrUpdateVolume('huya_r', 12.5);
    expect(db.getVolume('huya_r'), 12.5);
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mVolumeSet), isTrue);

    await db.addOrUpdateHistory(History(
      id: 'huya_r',
      roomId: 'r',
      siteId: 'huya',
      userName: 'u',
      face: '',
      updateTime: DateTime(2026),
    ));
    expect(
        port.calls.any((c) => c.$1 == DataPlaneProtocol.mHistoryAdd), isTrue);

    // 无 port 时纯内存不报错
    final dbOffline = InMemoryDBService();
    await dbOffline.addFollow(FollowUser(
      id: 'bilibili_1',
      roomId: '1',
      siteId: 'bilibili',
      userName: 'u',
      face: '',
      addTime: DateTime(2026),
    ));
    expect(dbOffline.getFollowExist('bilibili_1'), isTrue);
  });
```

- [ ] **Step 7: 门禁**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart test/multiwindow/in_memory_services_test.dart test/multiwindow/window_open_service_test.dart test/tab_store_test.dart`
Expected: 全过。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（219 + 5 = 224）。

- [ ] **Step 8: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/multiwindow/shell/room_controller_registry.dart simple_live_app/lib/app/multiwindow/shell/getx_room_controller_registry.dart simple_live_app/lib/app/multiwindow/bootstrap/in_memory_services.dart simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart simple_live_app/test/multiwindow/sub_data_plane_client_test.dart simple_live_app/test/multiwindow/in_memory_services_test.dart simple_live_app/test/multiwindow/window_open_service_test.dart simple_live_app/test/tab_store_test.dart
git commit -m "feat(multiwindow): registry 房间键查询与子引擎接收侧——对账/分流/关注写穿

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: 总装接线（reloadFromStorage 抽取、bootstrap 对账、binding 注册）

**Files:**
- Modify: `simple_live_app/lib/app/controller/app_settings_controller.dart`
- Modify: `simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart`
- Modify: `simple_live_app/lib/routes/app_pages.dart`
- Test: `simple_live_app/test/multiwindow/app_settings_reload_test.dart`

**Interfaces:**
- Produces: `AppSettingsController.reloadFromStorage()`。
- Consumes: Tasks 1-6 全部产物。

- [ ] **Step 1: 写 reload 抽取的失败测试**

创建 `test/multiwindow/app_settings_reload_test.dart`：

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

void main() {
  test('reloadFromStorage：改 KV 后重读刷新 Rx；可重复调用', () {
    final storage = InMemoryLocalStorageService();
    storage.applySnapshot(const WindowSnapshot(
      settings: {'DanmuSize': 16.0},
    ));
    Get.put<LocalStorageService>(storage, permanent: true);
    final settings = AppSettingsController();
    settings.onInit();

    expect(settings.danmuSize.value, 16.0);
    storage.setValue(LocalStorageService.kDanmuSize, 24.0);
    expect(settings.danmuSize.value, 16.0, reason: 'KV 变更本身不刷 Rx');

    settings.reloadFromStorage();
    expect(settings.danmuSize.value, 24.0);
    settings.reloadFromStorage(); // 重复调用安全
    expect(settings.danmuSize.value, 24.0);

    Get.reset();
  });
}
```

先例：window_open_service_test.dart:71 直调 onInit；Sites.allSites / Constant.allHomePages 为静态初始化，无插件依赖；logEnable 缺省 false 不会触发 Log.initWriter。

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/app_settings_reload_test.dart`
Expected: 编译失败（`reloadFromStorage` 不存在）。

- [ ] **Step 3: AppSettingsController 抽 reloadFromStorage（机械剪切）**

当前 `onInit`（app_settings_controller.dart:23-167）：:24-121 与 :126-164 为存储加载（含 :163-164 `initSiteSort()`/`initHomeSort()`，二者只读 KV + 写 Rx，幂等安全），:122-124 是唯一一次性副作用。

机械搬迁规则（逐行剪切粘贴，**不改写任何表达式、不调整顺序、不合并格式**）：

1. 在 `onInit` 之前新建方法，把 :24-121 与 :126-164 的全部行原样搬入：

```dart
  /// 从 LocalStorage 重新加载全部设置型 Rx。onInit 调一次；跨窗数据面
  /// 广播后由 MainDataPlaneService / SubDataPlaneClient 防抖再调。
  /// 不含一次性副作用（Log.initWriter 只在 onInit）。
  void reloadFromStorage() {
    // 原 :24-121 与 :126-164 的全部行原样落入此处
  }
```

2. 明确**排除**、留在 onInit 的只有 3 行（原 :122-124）：

```dart
    if (logEnable.value) {
      Log.initWriter();
    }
```

注意 `logEnable.value = getValue(...)` 赋值本身（:120-121）要搬走，只留 if 块。

3. `onInit` 改为：

```dart
  @override
  void onInit() {
    reloadFromStorage();
    if (logEnable.value) {
      Log.initWriter();
    }
    super.onInit();
  }
```

4. `// ignore: invalid_use_of_protected_member`（原 :93，服务于 :94 `shieldList.value = ...`）随该行一起搬入 reloadFromStorage，位置不变。

搬后自查（评审以逐行 diff 把关，必须逐条核对）：
- 原 onInit 每个 getValue 赋值目标（themeMode/firstRun/danmuSize/danmuOpacity/danmuArea/danmuSpeed/danmuEnable/danmuStrokeWidth/danmuTopMargin/danmuBottomMargin/danmuFontWeight/userName/syncUrl/hardwareDecode/chatTextSize/chatTextGap/chatBubbleStyle/qualityLevel/qualityLevelCellular/autoExitEnable/autoExitDuration/roomAutoExitDuration/playerCompatMode/playerAutoPause/playerForceHttps/backgroundAudioPlay/autoFullScreen/shieldList/scaleMode/playerVolume/pipHideDanmu/styleColor/isDynamic/bilibiliLoginTip/playerBufferSize/logEnable/customPlayerOutput/videoOutputDriver/audioOutputDriver/videoHardwareDecoder/autoUpdateFollowEnable/autoUpdateFollowDuration/updateFollowThreadCount）在 reloadFromStorage 中出现且仅一次；
- `initSiteSort()`/`initHomeSort()` 在 reloadFromStorage 末尾；
- `Log.initWriter()` 只在 onInit，不在 reloadFromStorage（spec §12 风险项：重复初始化文件 writer）；
- `super.onInit()` 只在 onInit 末尾。

- [ ] **Step 4: 子引擎 bootstrap 接线**

`sub_engine_bootstrap.dart` import 区（现有 package: import 组内，app_settings_controller 已在 :8 不重复）加 4 条：

```dart
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_client.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
```

**Edit A** —— 把现 :62-68「内存后端」段：

```dart
  // —— 内存后端（必须先于一切服务）——
  final storage = InMemoryLocalStorageService();
  storage.applySnapshot(args.snapshot);
  Get.put<LocalStorageService>(storage, permanent: true);
  final db = InMemoryDBService();
  db.applySnapshot(args.snapshot);
  Get.put<DBService>(db, permanent: true);
```

替换为：

```dart
  // —— 内存后端（必须先于一切服务）。带主窗 id 时启用数据面写穿 ——
  final SubDataPlanePort? dataPort = args.mainWindowId.isEmpty
      ? null
      : DmwSubDataPlanePort(args.mainWindowId);

  RemoteKvBox<dynamic>? settingsKv;
  RemoteKvBox<String>? shieldKv;
  final InMemoryLocalStorageService storage;
  if (dataPort != null) {
    settingsKv =
        RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, dataPort);
    shieldKv = RemoteKvBox<String>(DataPlaneProtocol.boxShield, dataPort);
    settingsKv.seedReplaceAll(
        Map<Object, dynamic>.of(args.snapshot.settings));
    shieldKv.seedReplaceAll(
        <Object, String>{for (final w in args.snapshot.shield) w: w});
    storage = InMemoryLocalStorageService(
        settingsBox: settingsKv, shieldBox: shieldKv);
  } else {
    storage = InMemoryLocalStorageService()..applySnapshot(args.snapshot);
  }
  Get.put<LocalStorageService>(storage, permanent: true);

  final db = InMemoryDBService(dataPort: dataPort)
    ..applySnapshot(args.snapshot);
  Get.put<DBService>(db, permanent: true);
```

**Edit B** —— 在 TabStore 注册（现 :90-96）之后、open tabs `for` 循环（现 :98）之前，插入 client 创建与总 handler 注册：

```dart
  // —— 数据面客户端 + 总 handler：handler 先就位，再 await 对账（spec §6.4）——
  final SubDataPlaneClient? dataClient = dataPort == null
      ? null
      : SubDataPlaneClient(
          port: dataPort,
          settings: settingsKv!,
          shield: shieldKv!,
          db: db,
          registry: Get.find<RoomControllerRegistry>(),
          onSettingsChanged: () =>
              AppSettingsController.instance.reloadFromStorage(),
        );

  self.setWindowMethodHandler((call) async {
    switch (call.method) {
      case DataPlaneProtocol.mChanged:
        dataClient?.handleChanged(call.arguments);
        return true;
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

  await dataClient?.reconcile();

```

**Edit C** —— 删除现 :118-135 旧 handler 块（从 `// —— 跨窗 IPC` 注释到 `});` 整段；其内容已并入 Edit B，含 `SubWindowCommands.closeRequested` 引用，window_role.dart import 保持不变）。

最终顺序必须是：存储/db 装配 → 最小服务集 → registry/TabStore → **client → setWindowMethodHandler → await reconcile** → open tabs 循环 → tabs 空 close 退出（现 :113-116 保留）→ runApp。

- [ ] **Step 5: 主引擎 binding 注册**

`app_pages.dart` kShell binding 中现 :83-97 的 Windows 条件块整段替换为：

```dart
        // 仅主引擎 Windows 壳需要开窗协调者与数据面服务（main() 已挂主窗 controller）
        if (Platform.isWindows &&
            !MultiWindowRole.isSubWindow &&
            DmwSubWindowPort.mainWindowId != null) {
          final subWindowPort = DmwSubWindowPort();
          final windowRegistry = WindowRegistry(
            mainWindowId: DmwSubWindowPort.mainWindowId!,
          );
          Get.put(
            WindowOpenService(
              port: subWindowPort,
              store: Get.find<TabStore>(),
              registry: windowRegistry,
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
            ),
            permanent: true,
          );
        }
```

要点：`subWindowPort` 与 `windowRegistry` 必须提为局部变量供两个服务**共用同一实例**（各自 new 会使数据面扇出窗口列表为空）。

import 区加 4 条（文件当前均无，已核实；dart:io 已在 :3）：

```dart
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/multiwindow/data/main_data_plane_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
```

- [ ] **Step 6: 全量门禁 + Windows 构建**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/app_settings_reload_test.dart`
Expected: 过。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test`
Expected: 22 存量零新增；若 sub_engine_bootstrap.dart 出现 unused import 立即删除。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿（224 + 1 = 225）。
Run: `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`
Expected: 成功（多引擎符号、GetX 注册、import 循环全部由编译捕获）。

- [ ] **Step 7: Commit**

```bash
cd /d/project/dart_simple_live
git add simple_live_app/lib/app/controller/app_settings_controller.dart simple_live_app/lib/app/multiwindow/bootstrap/sub_engine_bootstrap.dart simple_live_app/lib/routes/app_pages.dart simple_live_app/test/multiwindow/app_settings_reload_test.dart
git commit -m "feat(multiwindow): 数据面总装——reload 抽取、子窗对账分流、主窗服务注册

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: 最终门禁与 GUI 手工验收清单

**Files:**
- 无新代码；仅验证。GUI 步骤只能由用户在 Windows 桌面会话执行，执行者不得声称 GUI 已通过——跑完自动门禁后把清单原样交回。

- [ ] **Step 1: 全量静态检查**

```bash
cd /d/project/dart_simple_live/simple_live_app
C:/tools/flutter347/flutter/bin/flutter.bat analyze lib test
```
Expected: 22 条存量（2 warning + 20 info），零新增。

- [ ] **Step 2: 全量单测**

```bash
C:/tools/flutter347/flutter/bin/flutter.bat test
```
Expected: 全绿（189 + 本计划新增 36 + 评审 Minor 增强 2 = 227）。

- [ ] **Step 3: Windows debug 构建**

```bash
C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug
```
Expected: 成功。

- [ ] **Step 4: 输出 GUI 手工验收清单给用户（不自动执行）**

桌面运行 `build/windows/x64/runner/Debug/simple_live_app.exe`（或 `flutter run -d windows`）：

1. M2/M3/M4-1 行为无回归（多标签、心跳让位文案、多窗播放与关窗联动、各窗独立静音、子窗弹幕栏置灰）。
2. 子窗房间控制条改弹幕大小/透明度/开关：本窗即时生效；主窗与另一子窗约 100ms 后跟随；重启应用设置保留。
3. 子窗加/删屏蔽词：本窗立即屏蔽；主窗与另一子窗随后生效；主窗加词反向同步；重启后仍在；清空屏蔽词只触发一次跨窗刷新。
4. 子窗点关注/取关：本窗按钮即时翻转；主窗关注列表/首页状态刷新；另一子窗开同一房间按钮状态正确；重启后关注保留。
5. 子窗拖动音量条：主窗退出后重启，该房间音量为子窗设定值；子窗 A 调音量不改变正在播放的子窗 B 的音量（各窗独立播放保持）。
6. 子窗观看房间后，主窗「我的-观看历史」出现该房间。
7. 开窗竞态：主窗在新窗创建过程中连续改设置/关注，子窗打开后持最终值（dp_ready 对账 + 广播）。
8. 主窗 X 联动退出在高频写穿后仍无残留进程（回归 M4-1 第 7 项）；子窗 X 确认框与单关行为不变。
9. 安全项（本计划新增）：子窗期间在主窗登录/退出抖音或配置 GuardServer，子窗不获得 cookie/token——行为上子窗仍稳定游客态（主窗登录后子窗关注/弹幕登录态无变化、无 GuardServer 入口复活）。

注：spec §11 原第 9 条「Android 零改动」不在本里程碑本机执行；push/发版前门禁仍是 Android 真机回归 6 项 + M3 Windows GUI 9 项 + M4 GUI 11 项 + 本清单 9 项。

- [ ] **Step 5: 计划实施记录回填**

在用户确认 GUI 验收结果后，由控制器（非 implementer）把：commit 清单、测试数、GUI 验收结果、遗留事项（M4-3/4、M5）追加到本计划文件末尾「实施记录」一节，并按仓库惯例单独提交文档（只 add 本计划路径）。

---

## 实施记录

- 执行：2026-10-16 ~ 2026-10-17，Subagent-Driven（8 任务，implementer/reviewer 均 sonnet，整支分支终审 opus）。
- commit 链（基线 00c4287，已 ff 合入本地 `my_dev`，特性分支已删）：
  6a21855 T1 KvBox 变更流/种子接缝 → 60f4614 T2 启动参数主窗 id + buildDataSnapshot → 401550d T3 数据面协议层（敏感键单一真相）→ 1829016 T3 修复（游客态注释 + shield null 测试）→ 953ec88 T4 SubDataPlanePort + RemoteKvBox 乐观写 → 7aae112 T5 MainDataPlaneService 落盘/watch 扇出/双侧守卫 → cf1ba62 T5 R-10 修复（Hive 异步 clear 排空 + 真实 Hive temp dir 回归）→ 936b16c T6 registry 房间键查询 + 子引擎接收侧（对账/分流/关注写穿）→ 0834065 T7 总装（reloadFromStorage 抽取、对账分流、主窗服务注册）→ 7c8decd T7 R-11 修复（对账后立即 reload）→ 9fb39a9 评审 Minor 测试/注释增强。24 文件 +2011/-103。
- 门禁（最终树 9fb39a9 控制器亲跑）：`flutter analyze lib test` 22 条全存量零新增；`flutter test` **227/227**（基线 189 + 新增 38）；`flutter build windows --debug` 成功。
- 终审：opus 整支分支 APPROVED FOR MERGE，零 Critical/Important，R-9/R-10/R-11/R-12 全部 CONFIRM；新增 park 两条（FW-1 真实 Hive put/delete temp-dir 回归；FW-2 子窗账号登录路由可达的 UX 策略），连同任务评审 5 条 Minor 一并转 M4-3，开工时统一编号。
- GUI 验收：2026-10-17 用户本机桌面验收，用户确认 9 项通过（其中第 8 项进程模型由控制器实测佐证：3 子窗单进程 PID 62156、关窗释放约 223MB 无残留）。
- 未执行的门禁（用户 2026-10-17 明确豁免、按现状发布 1.12.60）：Android 真机回归 6 项、M3 Windows GUI 9 项与 M4-1 11 项在 M4-2 合入后的回归。本里程碑 Android 代码路径零变化（静态核验 + 227 全量测试）。
- 遗留：M4-3 账号面 presence IPC（M3 记账 9 条 + 本里程碑 7 条 park）、M4-4 跨窗拖拽、M5 多窗 NativeEditHost/IME（子窗弹幕发送恢复）、M6 发布收口。全部裁决与对撞表见同 slug sdd/progress.md（R-1~R-12）。
