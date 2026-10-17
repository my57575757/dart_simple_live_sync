# M4-2 数据面收尾 Minor 补丁 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 收口 M4-2 数据面 park 的 6 条 Minor（D1–D6）：回调异常隔离、落盘失败 false 语义、volume 畸形值对称、client dispose、真实 Hive put/delete 回归。

**Architecture:** 纯错误路径加固，不改协议/载荷/注册点：主端 `MainDataPlaneService` 注入回调包 try/catch、六个落盘 case 统一走 `_guardedWrite`；子端 `SubDataPlaneClient` 引入 `_safeReload`、volume 三分支显式化、补 `dispose()`；真实 Hive 测试复用既有 temp-dir 夹具并修正其临时目录卫生。

**Tech Stack:** Dart 3.13 / Flutter（固定 `C:/tools/flutter347/flutter/bin/flutter.bat`，3.47.5）、flutter_test、fake_async、Hive 2.2.3。全部测试在 `simple_live_app/` 下执行。

**Spec:** `docs/10_ai_workflows/superpowers/specs/2026-10-17-multiwindow-m4-2-dataplane-minors-design.md`（计划与 spec 同行，执行者两份都读；冲突以 spec 为准）。

## Global Constraints

- 分支 `feat/m4-2-dataplane-minors`（从 my_dev 切出，已含 spec commit c7cabfc）；就地工作，不用 worktree。
- 所有 flutter 命令用固定路径并在 `simple_live_app/` 目录执行：
  `C:/tools/flutter347/flutter/bin/flutter.bat`（analyze / test / build）。
- 只改本计划列出的 2 个生产文件与 2 个测试文件；不改协议、载荷、bootstrap/app_pages 注册点、Android/TV 任何文件。
- 基线：`flutter analyze` 存量 22 条（2 warning + 20 info），必须零新增；全量测试基线 227 全绿，完成后 234。
- git add 只加精确文件路径，严禁 `git add -A` / `git add .`；约 40 个存量脏文件（.idea/.opencode/generated_plugin_registrant 等）一律不碰不还原。
- commit message 简体中文，结尾空行后加
  `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`。
- 敏感键 17 具名 + `GuardAccountId_` 前缀；cookie/token 不进日志、不进数据面通道（本补丁不改凭据面，测试载荷只用 DanmuSize/普通词）。
- TDD：每任务先写失败测试、跑红、再实现、跑绿、提交。不得声称 GUI 已过（本补丁无 GUI 新项）。
- 每任务测试命令统一：
  `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/<file>`
  （单文件，快）；Task 6 跑全量与 build。

---

## File Structure

生产（2）：

- `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`
  - Task 1：`_scheduleReload` 回调 try/catch。
  - Task 2：新增 `_guardedWrite`；六个写 case 改返回 false 语义。
- `simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart`
  - Task 1：新增 `_safeReload`，`_scheduleReload`/`reconcile` 改用它。
  - Task 3：kindVolume 三分支显式化（畸形忽略）。
  - Task 4：新增 `dispose()`。

测试（2）：

- `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`
  - Task 1 +1 例；Task 2 +1 例（含 `_ThrowingKvBox`）；Task 5 +1 例真实 Hive，并把既有第 12 例 tempDir 创建挪进 try。
- `simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`
  - Task 1 +2 例；Task 3 +1 例；Task 4 +1 例。

---

### Task 1: D1 外部 onSettingsChanged 回调异常隔离

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`（`_scheduleReload`，约 L102-107）
- Modify: `simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart`（`_scheduleReload` 约 L57-60、`reconcile` 约 L49-50）
- Test: `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`
- Test: `simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`

**Interfaces:**
- Consumes: 现有 `onSettingsChanged`（main 为 `void Function()?`，sub 为 `void Function()`）、`Log.d`（两文件均已 import `package:simple_live_app/app/log.dart`）。
- Produces: 子端新增私有 `void _safeReload()`（Task 4 的 dispose 不依赖它，仅本文件内用）；无公开签名变化。

- [ ] **Step 1: 写失败测试（主端）**

在 `main_data_plane_service_test.dart` 的 `main()` 内、最后一个 test 之后追加：

```dart
  test('远程写 reload 回调抛异常被吞：不阻断后续防抖调度', () async {
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
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'});
    var reloadCalls = 0;
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () {
        reloadCalls++;
        if (reloadCalls == 1) throw StateError('reload boom');
      },
    );
    svc.onInit();

    await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuSize', 1));
    await flushReloadTimer();
    expect(reloadCalls, 1, reason: '第一次回调抛错已被吞');

    await call(
        DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(
            DataPlaneProtocol.boxSettings, 'DanmuOpacity', 2));
    await flushReloadTimer();
    expect(reloadCalls, 2, reason: '后续远程写仍能调度 reload');
  });
```

- [ ] **Step 2: 写失败测试（子端 Timer 路径 + reconcile 路径）**

在 `sub_data_plane_client_test.dart` 的 `main()` 内追加两条：

```dart
  test('handleChanged 防抖 reload 回调抛异常不成为未捕获错误', () {
    fakeAsync((async) {
      final port = _FakePort();
      final client = SubDataPlaneClient(
        port: port,
        settings:
            RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
        shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
        db: InMemoryDBService(),
        registry: _FakeRegistry(),
        onSettingsChanged: () => throw StateError('reload boom'),
      );

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv,
          key: 'DanmuSize',
          value: 18.0));
      expect(() => async.elapse(const Duration(milliseconds: 120)),
          returnsNormally);
    });
  });

  test('reconcile：reload 回调抛异常不影响快照播种', () {
    fakeAsync((async) {
      final port = _FakePort()
        ..readyResult = {
          'settings': {'DanmuSize': 22.0},
          'shield': <String>[],
          'volumes': <String, double>{},
          'followShareUrls': <String, String>{},
        };
      final settings =
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
      final client = SubDataPlaneClient(
        port: port,
        settings: settings,
        shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
        db: InMemoryDBService(),
        registry: _FakeRegistry(),
        onSettingsChanged: () => throw StateError('reload boom'),
      );

      expect(client.reconcile(), completes);
      async.flushMicrotasks();
      expect(settings.get('DanmuSize'), 22.0, reason: '播种已完成');
      expect(() => async.elapse(const Duration(milliseconds: 120)),
          returnsNormally);
    });
  });
```

注意此例是**回归锚点而非红测**：`reconcile()` 现状外层已有 try/catch，
回调抛错在修复前后都不会逃逸；它钉死的是"回调抛错不影响已完成的播种"，
并防止日后缩窄外层 catch。真正的红绿在上面 Timer 用例。

- [ ] **Step 3: 跑测试确认失败**

Run（在 `simple_live_app/`）：
`C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart test/multiwindow/sub_data_plane_client_test.dart`
Expected: FAIL——主端用例与子端 Timer 用例报 `StateError: reload boom` 未捕获
（flutter_test test zone / fakeAsync 在 elapse 时重抛 Timer 错误）；
reconcile 锚点用例可能直接通过，属上一步已说明的预期。

- [ ] **Step 4: 主端实现**

将 `main_data_plane_service.dart` 的 `_scheduleReload` 整体替换为：

```dart
  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, () {
      if (_closed) return;
      final callback = onSettingsChanged;
      if (callback == null) return;
      try {
        callback();
      } catch (e) {
        Log.d('数据面设置 reload 回调异常：$e');
      }
    });
  }
```

- [ ] **Step 5: 子端实现**

在 `sub_data_plane_client.dart` 中将 `_scheduleReload` 整体替换，并在其下方新增 `_safeReload`：

```dart
  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, _safeReload);
  }

  /// 外部注入回调（生产为 AppSettingsController.reloadFromStorage）：
  /// 异常不得穿透 Timer/reconcile 成为未捕获 async 错误
  void _safeReload() {
    try {
      onSettingsChanged();
    } catch (e) {
      Log.d('子窗设置 reload 回调异常：$e');
    }
  }
```

将 `reconcile` 末尾两行：

```dart
      _reloadTimer?.cancel();
      onSettingsChanged();
```

替换为：

```dart
      _reloadTimer?.cancel();
      _safeReload();
```

- [ ] **Step 6: 跑测试确认通过**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart test/multiwindow/sub_data_plane_client_test.dart`
Expected: PASS（两文件全绿，新 3 例在内）。

- [ ] **Step 7: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart simple_live_app/test/multiwindow/main_data_plane_service_test.dart simple_live_app/test/multiwindow/sub_data_plane_client_test.dart
git commit -m "fix(multiwindow): 数据面外部 reload 回调异常隔离

主端防抖 Timer 与子端 Timer/reconcile 调用注入回调时包 try/catch，
回调抛错不再成为未捕获异常，也不阻断后续防抖调度（M4-2 D1）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: D2 主端落盘失败统一返回 false

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart`（新增 `_guardedWrite`；mKvSet/mKvDelete/mKvClear/mVolumeSet/mFollowSet/mFollowRemove 六分支，约 L140-224）
- Test: `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`

**Interfaces:**
- Consumes: 现有 `_withRemoteFlag`（其 finally 在异常路径仍复位 `_remoteWrite`，不得破坏）；`Log.d`。
- Produces: 私有 `Future<bool> _guardedWrite(Future<void> Function() action)`；仅本文件使用。后续任务无人依赖。

- [ ] **Step 1: 写失败测试与抛错箱**

在 `main_data_plane_service_test.dart` 的 `_FakePort` 类定义之后、`main()` 之前新增：

```dart
class _ThrowingKvBox<T> extends MemoryKvBox<T> {
  @override
  Future<void> put(Object key, T value) async =>
      throw StateError('disk full');

  @override
  Future<void> delete(Object key) async =>
      throw StateError('disk full');

  @override
  Future<int> clear() async => throw StateError('disk full');
}
```

在 `main()` 内最后一个 test 之后追加：

```dart
  test('落盘异常：六个写方法返回 false 不抛、不扇出、不发关注事件', () async {
    storage = LocalStorageService()
      ..settingsBox = _ThrowingKvBox<dynamic>()
      ..shieldBox = _ThrowingKvBox<String>();
    Get.put<LocalStorageService>(storage, permanent: true);
    db = DBService()
      ..historyBox = MemoryKvBox<History>()
      ..followBox = _ThrowingKvBox<FollowUser>()
      ..tagBox = MemoryKvBox<FollowUserTag>()
      ..volumeBox = _ThrowingKvBox<double>();
    Get.put<DBService>(db, permanent: true);
    port = _FakePort();
    registry = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w1', {'a'});
    final events = <Object?>[];
    final sub = EventBus.instance
        .listen(Constant.kUpdateFollow, (p0) => events.add(p0));
    addTearDown(sub.cancel);
    svc = MainDataPlaneService(
      port: port,
      registry: registry,
      storage: storage,
      db: db,
      onSettingsChanged: () {},
    );
    svc.onInit();

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
        await call(
            DataPlaneProtocol.mKvSet,
            DataPlaneProtocol.kvSet(
                DataPlaneProtocol.boxSettings, 'DanmuSize', 1)),
        isFalse);
    expect(
        await call(
            DataPlaneProtocol.mKvDelete,
            DataPlaneProtocol.kvDelete(
                DataPlaneProtocol.boxSettings, 'DanmuSize')),
        isFalse);
    expect(
        await call(
            DataPlaneProtocol.mKvClear,
            DataPlaneProtocol.kvClear(DataPlaneProtocol.boxShield)),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mVolumeSet,
            DataPlaneProtocol.volumeSet('huya_9', 42)),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mFollowSet,
            DataPlaneProtocol.followSet(follow.toJson())),
        isFalse);
    expect(
        await call(DataPlaneProtocol.mFollowRemove,
            DataPlaneProtocol.followRemove('bilibili_3')),
        isFalse);
    expect(changedCalls(), isEmpty, reason: '落盘失败不扇出');
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty, reason: '落盘失败不发关注更新事件');
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: FAIL——首个调用即抛 `StateError: disk full` 穿透 handleCall。

- [ ] **Step 3: 新增 _guardedWrite**

在 `main_data_plane_service.dart` 的 `_withRemoteFlag` 方法之后新增：

```dart
  /// 落盘失败统一回执 false：Hive 写异常不得经 method channel 逸出，
  /// 否则子端乐观态与主端不一致且收不到失败回执。
  Future<bool> _guardedWrite(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (e) {
      Log.d('数据面落盘失败：$e');
      return false;
    }
  }
```

- [ ] **Step 4: 改六个 case**

mKvSet 分支中，把：

```dart
        await _withRemoteFlag(() async {
          if (w.box == DataPlaneProtocol.boxShield) {
            await storage.shieldBox.put(w.key, w.value as String);
          } else {
            await storage.settingsBox.put(w.key, w.value);
          }
        });
        return true;
```

替换为：

```dart
        return _guardedWrite(() => _withRemoteFlag(() async {
              if (w.box == DataPlaneProtocol.boxShield) {
                await storage.shieldBox.put(w.key, w.value as String);
              } else {
                await storage.settingsBox.put(w.key, w.value);
              }
            }));
```

mKvDelete 分支中，把：

```dart
        await _withRemoteFlag(() => _kvBox(w.box).delete(w.key));
        return true;
```

替换为：

```dart
        return _guardedWrite(
            () => _withRemoteFlag(() => _kvBox(w.box).delete(w.key)));
```

mKvClear 的 shield 执行段，把：

```dart
        const kind = DataPlaneProtocol.kindShield;
        _suppressed.add(kind);
        try {
          await _kvBox(boxName).clear();
          // Hive BoxBaseImpl.clear 先 await backend 后同步 keystore.notify，
          // 逐 key 事件经 async broadcast 以 microtask 链式重排，而 await 链
          // 同步坍缩会使 finally 早于它们执行；排空一个事件轮次再解除抑制。
          // MemoryKvBox 为 sync 广播，此处空等。
          await Future<void>.delayed(Duration.zero);
        } finally {
          _suppressed.remove(kind);
        }
        _fanout(DataPlaneProtocol.changed(kind: kind, key: '', clear: true));
        _scheduleReload();
        return true;
```

替换为：

```dart
        const kind = DataPlaneProtocol.kindShield;
        final ok = await _guardedWrite(() async {
          _suppressed.add(kind);
          try {
            await _kvBox(boxName).clear();
            // Hive BoxBaseImpl.clear 先 await backend 后同步 keystore.notify，
            // 逐 key 事件经 async broadcast 以 microtask 链式重排，而 await 链
            // 同步坍缩会使 finally 早于它们执行；排空一个事件轮次再解除抑制。
            // MemoryKvBox 为 sync 广播，此处空等。
            await Future<void>.delayed(Duration.zero);
          } finally {
            _suppressed.remove(kind);
          }
        });
        if (!ok) return false;
        _fanout(DataPlaneProtocol.changed(kind: kind, key: '', clear: true));
        _scheduleReload();
        return true;
```

mVolumeSet 分支中，把：

```dart
        await _withRemoteFlag(
            () => db.addOrUpdateVolume(key, value.toDouble()));
        return true;
```

替换为：

```dart
        return _guardedWrite(() => _withRemoteFlag(
            () => db.addOrUpdateVolume(key, value.toDouble())));
```

mFollowSet 分支中，把：

```dart
        await _withRemoteFlag(() => db.addFollow(follow));
        EventBus.instance.emit(Constant.kUpdateFollow, follow.id);
        return true;
```

替换为（switch 各 case 共享块作用域，两分支变量名区分，勿同名）：

```dart
        final setOk = await _guardedWrite(
            () => _withRemoteFlag(() => db.addFollow(follow)));
        if (!setOk) return false;
        EventBus.instance.emit(Constant.kUpdateFollow, follow.id);
        return true;
```

mFollowRemove 分支中，把：

```dart
        await _withRemoteFlag(() => db.deleteFollow(key));
        EventBus.instance.emit(Constant.kUpdateFollow, key);
        return true;
```

替换为：

```dart
        final removeOk = await _guardedWrite(
            () => _withRemoteFlag(() => db.deleteFollow(key)));
        if (!removeOk) return false;
        EventBus.instance.emit(Constant.kUpdateFollow, key);
        return true;
```

- [ ] **Step 5: 跑测试确认通过**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: PASS（含真实 Hive clear 既有用例——抑制/扇出语义未变）。

- [ ] **Step 6: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/data/main_data_plane_service.dart simple_live_app/test/multiwindow/main_data_plane_service_test.dart
git commit -m "fix(multiwindow): 数据面主端落盘失败回执 false 不穿透

六个写 case 统一 _guardedWrite：Hive 写异常经 method channel 返回
false，不扇出、不发关注事件；mKvClear 失败时抑制位仍由 finally 复位（M4-2 D2）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: D3+D4 kindVolume 畸形值忽略与三分支表驱动测试

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart`（kindVolume case，约 L89-96）
- Test: `simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`

**Interfaces:**
- Consumes: `InMemoryDBService.seedVolume(String, double?, {bool deleted})`、`seedVolumesClear()`、`DBService.exportVolumes()`。
- Produces: 无新签名。

- [ ] **Step 1: 写失败测试**

在 `sub_data_plane_client_test.dart` 的 `main()` 内最后追加：

```dart
  test('handleChanged：kindVolume 数值/删除/null 表驱动；clear 与畸形忽略',
      () {
    final port = _FakePort();
    final db = InMemoryDBService();
    final client = SubDataPlaneClient(
      port: port,
      settings:
          RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
      shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
      db: db,
      registry: _FakeRegistry(),
      onSettingsChanged: () {},
    );

    final cases = <(String, Object?, bool, Map<String, double>)>[
      // key, value, deleted, 期望 exportVolumes
      ('douyin_1', 33.0, false, {'douyin_1': 33.0}),
      ('douyin_2', 42, false, {'douyin_1': 33.0, 'douyin_2': 42.0}),
      ('douyin_1', 1.0, true, {'douyin_2': 42.0}),
      ('douyin_2', null, false, <String, double>{}),
    ];
    for (final (key, value, deleted, expected) in cases) {
      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindVolume,
          key: key,
          value: value,
          deleted: deleted));
      expect(db.exportVolumes(), expected,
          reason: 'key=$key value=$value deleted=$deleted');
    }

    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindVolume, key: '', clear: true));
    expect(db.exportVolumes(), isEmpty);

    // 非 null 非 num 畸形值：忽略（不按删除处理），既有值不动
    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindVolume,
        key: 'douyin_9',
        value: 9.0));
    client.handleChanged(DataPlaneProtocol.changed(
        kind: DataPlaneProtocol.kindVolume,
        key: 'douyin_9',
        value: 'junk'));
    expect(db.exportVolumes(), {'douyin_9': 9.0});
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart`
Expected: FAIL——最后一段 `'junk'` 被现状代码当作删除，`exportVolumes()` 为空。

- [ ] **Step 3: 实现三分支**

将 `sub_data_plane_client.dart` 的 kindVolume case：

```dart
      case DataPlaneProtocol.kindVolume:
        if (e.clear) {
          db.seedVolumesClear();
        } else {
          final value = e.value;
          db.seedVolume(e.key, value is num ? value.toDouble() : null,
              deleted: e.deleted || value == null);
        }
```

替换为：

```dart
      case DataPlaneProtocol.kindVolume:
        if (e.clear) {
          db.seedVolumesClear();
        } else if (e.deleted || e.value == null) {
          db.seedVolume(e.key, null, deleted: true);
        } else if (e.value is num) {
          db.seedVolume(e.key, (e.value as num).toDouble());
        }
        // 非 null 非 num 畸形值忽略（与 shield 非 String 忽略对称；
        // 输入只来自受信主端，正常不可达）
```

- [ ] **Step 4: 跑测试确认通过**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart simple_live_app/test/multiwindow/sub_data_plane_client_test.dart
git commit -m "fix(multiwindow): 子端 volume 畸形非 num 值改为忽略

与 shield 非 String 忽略语义对称，String 等坏值不再被误当删除；
补 clear/deleted/null/int/畸形五输入表驱动回归（M4-2 D3/D4）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: D5 SubDataPlaneClient.dispose

**Files:**
- Modify: `simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart`（类内新增 dispose，紧挨 `_scheduleReload`/`_safeReload`）
- Test: `simple_live_app/test/multiwindow/sub_data_plane_client_test.dart`

**Interfaces:**
- Consumes: 现有 `_reloadTimer`。
- Produces: 公开 `void dispose()`；本期**无生产调用点**（子引擎进程级生命周期），仅供测试与未来窗口级销毁使用——不要在 bootstrap 里接线。

- [ ] **Step 1: 写失败测试**

在 `sub_data_plane_client_test.dart` 的 `main()` 内最后追加：

```dart
  test('dispose 取消待触发 reload；dispose 后再收事件不抛', () {
    fakeAsync((async) {
      final port = _FakePort();
      var reloads = 0;
      final client = SubDataPlaneClient(
        port: port,
        settings:
            RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port),
        shield: RemoteKvBox<String>(DataPlaneProtocol.boxShield, port),
        db: InMemoryDBService(),
        registry: _FakeRegistry(),
        onSettingsChanged: () => reloads++,
      );

      client.handleChanged(DataPlaneProtocol.changed(
          kind: DataPlaneProtocol.kindKv, key: 'DanmuSize', value: 18.0));
      client.dispose();
      async.elapse(const Duration(milliseconds: 120));
      expect(reloads, 0, reason: '防抖 Timer 已取消');

      expect(
          () => client.handleChanged(DataPlaneProtocol.changed(
              kind: DataPlaneProtocol.kindKv,
              key: 'DanmuSize',
              value: 19.0)),
          returnsNormally);
      client.dispose(); // 收尾：取消新挂 Timer，避免 fakeAsync 挂起计时器
    });
  });
```

- [ ] **Step 2: 跑测试确认失败**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart`
Expected: FAIL——`dispose` 方法不存在，编译错误。

- [ ] **Step 3: 实现**

在 `sub_data_plane_client.dart` 的 `_safeReload` 方法之后新增：

```dart
  /// 取消待触发的防抖 reload。子引擎为进程级生命周期，本期生产无调用点；
  /// 供未来引擎/窗口级销毁出现时直接可用。
  void dispose() {
    _reloadTimer?.cancel();
    _reloadTimer = null;
  }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/sub_data_plane_client_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add simple_live_app/lib/app/multiwindow/data/sub_data_plane_client.dart simple_live_app/test/multiwindow/sub_data_plane_client_test.dart
git commit -m "feat(multiwindow): SubDataPlaneClient.dispose 取消防抖 Timer

补窗口级销毁接缝与 fakeAsync 回归；本期子引擎进程级生命周期，无生产调用点（M4-2 D5）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: D6 真实 Hive put/delete temp-dir 回归 + 夹具卫生

**Files:**
- Test only: `simple_live_app/test/multiwindow/main_data_plane_service_test.dart`

**Interfaces:**
- Consumes: 既有真实 Hive clear 用例的 temp-dir 模式（`Hive.openBox` + `HiveKvBox` + finally `Hive.close()`/`deleteSync`）；`_remoteWrite` owner-reload 行为。
- Produces: 无生产变化。

- [ ] **Step 1: 先修既有第 12 例夹具（tempDir 创建挪进 try）**

在 `main_data_plane_service_test.dart` 中找到真实 Hive clear 用例开头：

```dart
    final tempDir = await Directory.systemTemp.createTemp('m42_hive_clear');
    Box<String>? hiveBox;
    MainDataPlaneService? hiveSvc;
    try {
      final boxName =
          'shield_${DateTime.now().microsecondsSinceEpoch}';
      hiveBox =
          await Hive.openBox<String>(boxName, path: tempDir.path);
```

替换为：

```dart
    Directory? tempDir;
    Box<String>? hiveBox;
    MainDataPlaneService? hiveSvc;
    try {
      tempDir = await Directory.systemTemp.createTemp('m42_hive_clear');
      final boxName =
          'shield_${DateTime.now().microsecondsSinceEpoch}';
      hiveBox =
          await Hive.openBox<String>(boxName, path: tempDir.path);
```

同用例 finally 中的：

```dart
      tempDir.deleteSync(recursive: true);
```

替换为：

```dart
      tempDir?.deleteSync(recursive: true);
```

- [ ] **Step 2: 写新用例（先红：语义已在代码中，此步应直接绿——作为回归锚点）**

在该文件 `main()` 内最后一个 test 之后追加：

```dart
  test('真实 Hive：dp_kv_set/delete 落盘、watch 扇出且各触发一次 owner reload',
      () async {
    // MemoryKvBox 为同步广播，测不到真实 Hive watch 的 async 派发与
    // _remoteWrite 标志下的 owner reload；put/delete 路径此前无自动化。
    Directory? tempDir;
    Box<dynamic>? hiveBox;
    MainDataPlaneService? hiveSvc;
    try {
      tempDir = await Directory.systemTemp.createTemp('m42_hive_write');
      final boxName =
          'localstorage_${DateTime.now().microsecondsSinceEpoch}';
      hiveBox =
          await Hive.openBox<dynamic>(boxName, path: tempDir.path);

      storage = LocalStorageService()
        ..settingsBox = HiveKvBox<dynamic>(hiveBox)
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
      hiveSvc = svc;
      svc.onInit();
      port.calls.clear();

      expect(
          await call(
              DataPlaneProtocol.mKvSet,
              DataPlaneProtocol.kvSet(
                  DataPlaneProtocol.boxSettings, 'DanmuSize', 20.0)),
          isTrue);
      expect(storage.getValue('DanmuSize', 0.0), 20.0);
      // Hive watch 为 async broadcast：排空一轮事件后再冲防抖 Timer
      await Future<void>.delayed(Duration.zero);
      await flushReloadTimer();
      expect(reloadCount, 1, reason: '远程写触发一次 owner reload');
      expect(changedCalls().length, 1);

      expect(
          await call(
              DataPlaneProtocol.mKvDelete,
              DataPlaneProtocol.kvDelete(
                  DataPlaneProtocol.boxSettings, 'DanmuSize')),
          isTrue);
      expect(storage.settingsBox.containsKey('DanmuSize'), isFalse);
      await Future<void>.delayed(Duration.zero);
      await flushReloadTimer();
      expect(reloadCount, 2, reason: '两次远程写各调度一次');
      final changed = changedCalls();
      expect(changed.length, 2);
      expect((changed[1].$2! as Map)['deleted'], isTrue);
    } finally {
      hiveSvc?.onClose();
      await Hive.close();
      tempDir?.deleteSync(recursive: true);
    }
  });
```

说明：此用例不是 TDD 红绿（生产行为 M4-2 已正确），它是缺失的回归锚点；
若首次运行即失败，说明 _remoteWrite/watch 接线存在真实缺陷，停下来报告，
不得修改生产代码以求绿。

- [ ] **Step 3: 跑测试**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test test/multiwindow/main_data_plane_service_test.dart`
Expected: PASS（含修正夹具后的 clear 用例与新用例；临时目录用后即删）。

- [ ] **Step 4: 提交**

```bash
git add simple_live_app/test/multiwindow/main_data_plane_service_test.dart
git commit -m "test(multiwindow): 真实 Hive put/delete 端到端回归

补 dp_kv_set/delete 穿 handler 落真实箱、watch 扇出与 owner reload
各一次的自动化；顺手把 clear 例 tempDir 创建挪进 try，openBox 失败不泄漏目录（M4-2 D6）。

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: 全量门禁与实施记录

**Files:**
- Modify（文档，最后单独提交）: 本计划文件末尾「实施记录」节

**Interfaces:** 无。

- [ ] **Step 1: 静态分析零新增**

Run（在 `simple_live_app/`）：
`C:/tools/flutter347/flutter/bin/flutter.bat analyze`
Expected: 与基线一致的 22 条（2 warning + 20 info 全存量）；若有新增，
回对应任务修复后重跑。

- [ ] **Step 2: 全量测试**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat test`
Expected: 全绿，总数 234（基线 227 + 本补丁 7 例：T1×3、T2×1、T3×1、T4×1、T5×1）。

- [ ] **Step 3: Windows debug 构建**

Run: `C:/tools/flutter347/flutter/bin/flutter.bat build windows --debug`
Expected: 成功（落盘错误路径改动，跑一次构建门禁）。

- [ ] **Step 4: 核对改动面**

Run: `git diff --stat my_dev...HEAD`
Expected: 仅 2 生产文件 + 2 测试文件 + 2 docs（spec 与本计划）；无 Android/TV、
无协议/注册点文件。核对后把输出贴进实施记录。

- [ ] **Step 5: 回填实施记录并提交**

在本文件末尾追加「## 实施记录」节：任务 commit SHA、测试总数、analyze 结果、
build 结果、diff --stat、遗留项（无）。然后：

```bash
git add docs/10_ai_workflows/superpowers/plans/2026-10-17-multiwindow-m4-2-dataplane-minors.md
git commit -m "docs: M4-2 数据面 Minor 计划回填实施记录

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

- [ ] **Step 6: 交控制器终审**

不自行合分支、不 push。通知控制器（人）进入 whole-branch 终审；
合并方式（本地 ff 合回 my_dev）与后续 M4-3 分支 rebase 由用户决定后执行。

---

## 实施记录

（执行结束后回填）
