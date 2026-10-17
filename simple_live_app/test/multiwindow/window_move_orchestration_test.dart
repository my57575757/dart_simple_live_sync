import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/presence/handoff_controller.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

TabOpenRequest req(String site, String room, [String share = '']) =>
    TabOpenRequest(siteId: site, roomId: room, shareUrl: share);

class _Registry implements RoomControllerRegistry {
  @override
  void register(String tabId, TabOpenRequest request) {}
  @override
  void unregister(String tabId) {}
  @override
  bool isRegistered(String tabId) => false;
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _FakePort implements SubWindowPort {
  final created = <String, String>{};
  final invocations = <(String, String, Object?)>[];
  final StreamController<void> changedController =
      StreamController<void>.broadcast();
  Object? createError;
  Object? Function(String windowId, String method, Object? args)? onInvoke;
  int _seq = 0;

  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async {
    if (createError != null) throw createError!;
    final id = 'new${++_seq}';
    created[id] = argumentsJson;
    return SubWindowHandle(id);
  }

  @override
  Future<Object?> invoke(
      String windowId, String method, Object? arguments) async {
    invocations.add((windowId, method, arguments));
    return onInvoke?.call(windowId, method, arguments);
  }

  @override
  Future<List<String>> listWindowIds() async => const ['main'];

  @override
  Stream<void> get windowsChanged => changedController.stream;
}

/// mode：'immediate'（跟踪、rehome 立即成功）、'none'（非跟踪 null）、
/// 'timeout'（10s 定时器以异常失败）
///
/// prepares 记录「实际建立的 handoff」而非 prepareHandoff 调用次数：
/// mode=none（未跟踪）返回 null 时不记，与用例断言
/// 「非跟踪不建 handoff」一致（brief 测试锁定行为，见报告偏离项）。
class _FakeHandoff implements PresenceHandoffController {
  String mode = 'immediate';
  final prepares = <(String, String)>[];
  int rehomeLocalCount = 0;
  Completer<void>? hang;

  @override
  Future<void>? prepareHandoff(String tabId, String destWindowId) {
    if (mode == 'none') return null;
    prepares.add((tabId, destWindowId));
    if (mode == 'timeout') {
      final completer = Completer<void>();
      Timer(const Duration(seconds: 10),
          () => completer.completeError(StateError('timeout')));
      return completer.future;
    }
    if (mode == 'hang') {
      hang = Completer<void>();
      return hang!.future;
    }
    return Future.value();
  }

  @override
  Future<void> rehomeLocal(String tabId) async {
    rehomeLocalCount++;
  }
}

void main() {
  late _FakePort port;
  late TabStore store;
  late WindowRegistry registry;
  late _FakeHandoff handoff;
  late WindowOpenService service;
  final toasts = <String>[];
  var focusMainCount = 0;

  WindowOpenService build() => WindowOpenService(
        port: port,
        store: store,
        registry: registry,
        presenceService: handoff,
        showToast: toasts.add,
        showAndFocusMain: () async => focusMainCount++,
      );

  setUp(() {
    Get.put<LocalStorageService>(InMemoryLocalStorageService(),
        permanent: true);
    Get.put<DBService>(InMemoryDBService(), permanent: true);
    port = _FakePort();
    store = TabStore(registry: _Registry());
    registry = WindowRegistry(mainWindowId: 'main');
    handoff = _FakeHandoff();
    service = build();
    service.onInit();
    toasts.clear();
    focusMainCount = 0;
  });

  tearDown(() async {
    service.onClose();
    await port.changedController.close();
    Get.reset();
  });

  List<(String, String, Object?)> calls(String windowId, String method) =>
      port.invocations.where((i) => i.$1 == windowId && i.$2 == method).toList();

  test('主→新窗：预定 tabId 建窗、登记 registry、关主窗源标签；不发 focus/close',
      () async {
    handoff.mode = 'none';
    final tab = store.open(req('douyin', 'a', 'http://a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );
    expect(message, isNull);

    expect(port.created.length, 1);
    final args =
        RoomWindowArgs.decode(port.created.values.single);
    expect(args.tabs.single.tabId, tab.tabId);
    expect(args.tabs.single.roomId, 'a');
    expect(registry.tabsOf(port.created.keys.single), {'douyin_a'});
    expect(store.tabs, isEmpty);
    expect(port.invocations, isEmpty, reason: '新窗 bootstrap 自 show，无 IPC');
    expect(handoff.prepares, isEmpty, reason: '非跟踪不建 handoff');
    expect(toasts, isEmpty);
  });

  test('主→新窗（抖音跟踪）：prepareHandoff 目标为新窗 id', () async {
    final tab = store.open(req('douyin', 'a'));

    await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );

    expect(handoff.prepares.single.$1, tab.tabId);
    expect(handoff.prepares.single.$2, port.created.keys.single);
  });

  test('主→已存在子窗：mw_open_tab(activate:true) 后登记并 focus_tab',
      () async {
    handoff.mode = 'none';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_old'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, isNull);

    final openCalls = calls('w1', WindowControlProtocol.mOpenTab);
    expect(openCalls, hasLength(1));
    final open =
        WindowControlProtocol.decodeOpenTab(openCalls.single.$3)!;
    expect(open.tabId, tab.tabId);
    expect(open.activate, isTrue);
    expect(registry.tabsOf('w1'), {'douyin_old', 'douyin_a'});
    final focus = calls('w1', 'focus_tab').single;
    expect(focus.$3, 'douyin_a');
    expect(store.tabs, isEmpty);
  });

  test('子→已存在子窗：落目标、关源、moveChildTab、focus 目标', () async {
    handoff.mode = 'none';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_a'});
    registry.registerChild('w2', {'douyin_b'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: 'w2',
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    final close = calls('w1', WindowControlProtocol.mCloseTab).single;
    expect(WindowControlProtocol.decodeCloseTab(close.$3)!.tabId, 'ta');
    expect(registry.tabsOf('w1'), isEmpty, reason: '空窗保留待 reconcile/自关');
    expect(registry.tabsOf('w2'), {'douyin_a', 'douyin_b'});
    expect(calls('w2', 'focus_tab').single.$3, 'douyin_a');
    expect(toasts, isEmpty, reason: '子源成功不在主端 toast');
  });

  test('子→主窗：主窗预定 tabId 落标签、rehomeLocal、摘源登记、主窗置前',
      () async {
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetMain,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    expect(store.tabs.single.tabId, 'ta');
    expect(handoff.rehomeLocalCount, 1);
    expect(registry.tabsOf('w1'), isEmpty);
    expect(focusMainCount, 1, reason: '源是子窗才置前主窗');
    final close = calls('w1', WindowControlProtocol.mCloseTab).single;
    expect(WindowControlProtocol.decodeCloseTab(close.$3)!.tabId, 'ta');
  });

  test('子→新窗：建窗（预定 tabId）、关源、挪动登记；无 focus、不置前主窗',
      () async {
    handoff.mode = 'none';
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetNew,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);

    final newId = port.created.keys.single;
    expect(RoomWindowArgs.decode(port.created[newId]!).tabs.single.tabId,
        'ta');
    expect(registry.tabsOf('w1'), isEmpty);
    expect(registry.tabsOf(newId), {'douyin_a'});
    expect(calls(newId, 'focus_tab'), isEmpty);
    expect(focusMainCount, 0);
    expect(calls('w1', WindowControlProtocol.mCloseTab), hasLength(1));
  });

  test('失败：主源 descriptor 不存在', () async {
    final message = await service.moveTabToWindow(
      tabId: 'nope',
      target: 'w1',
    );
    expect(message, '未找到要移动的标签');
    expect(toasts, ['未找到要移动的标签'], reason: '主源失败在主端 toast');
    expect(port.invocations, isEmpty);
  });

  test('失败：子源缺 siteId/roomId 四元组', () async {
    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: 'w2',
    );
    expect(message, '未找到要移动的标签');
    expect(toasts, isEmpty, reason: '子源失败不主端 toast，文案随回执回子端');
  });

  test('失败：目标子窗未注册', () async {
    final tab = store.open(req('douyin', 'a'));
    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'wx',
    );
    expect(message, '目标窗口不存在');
    expect(toasts, ['目标窗口不存在']);
  });

  test('失败：createRoomWindow 抛错——toast 新建失败、不建 handoff、源不动',
      () async {
    port.createError = StateError('native');
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: WindowControlProtocol.targetNew,
    );
    expect(message, '新建窗口失败');
    expect(toasts, ['新建窗口失败']);
    expect(handoff.prepares, isEmpty, reason: '建窗先于 prepareHandoff');
    expect(store.tabs.single.tabId, tab.tabId);
    expect(registry.childCount, 0);
  });

  test('失败：mw_open_tab 回执 false——目标无响应、不登记、源不动', () async {
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab ? false : null;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '目标窗口无响应');
    expect(toasts, ['目标窗口无响应']);
    expect(registry.tabsOf('w1'), {'douyin_b'});
    expect(store.tabs.single.tabId, tab.tabId);
    expect(calls('w1', 'focus_tab'), isEmpty);
  });

  test('失败：mw_open_tab invoke 抛错（目标窗已死）同样收口', () async {
    port.onInvoke = (w, m, a) =>
        m == WindowControlProtocol.mOpenTab ? throw StateError('gone') : null;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '目标窗口无响应');
    expect(registry.tabsOf('w1'), {'douyin_b'});
    expect(store.tabs, hasLength(1));
  });

  test('源关闭 best-effort 失败不阻断：子→主仍成功、登记已挪、主窗置前',
      () async {
    port.onInvoke = (w, m, a) =>
        m == WindowControlProtocol.mCloseTab ? throw StateError('dead') : null;
    registry.registerChild('w1', {'douyin_a'});

    final message = await service.moveTabToWindow(
      tabId: 'ta',
      sourceWindowId: 'w1',
      target: WindowControlProtocol.targetMain,
      siteId: 'douyin',
      roomId: 'a',
    );
    expect(message, isNull);
    expect(registry.tabsOf('w1'), isEmpty);
    expect(focusMainCount, 1);
  });

  test('handoff 超时（新窗）：best-effort close_window、源标签保留、超时文案',
      () {
    fakeAsync((async) {
      handoff.mode = 'timeout';
      final tab = store.open(req('douyin', 'a'));
      final future = service.moveTabToWindow(
        tabId: tab.tabId,
        target: WindowControlProtocol.targetNew,
      );
      async.flushMicrotasks();
      final newId = port.created.keys.single;
      expect(calls(newId, 'close_window'), isEmpty, reason: '超时前不关');

      async.elapse(const Duration(seconds: 10));
      async.flushMicrotasks();

      expect(calls(newId, 'close_window'), hasLength(1));
      expect(store.tabs.single.tabId, tab.tabId, reason: '源不动继续播放');
      expect(toasts.single, '移动超时，标签可能已在目标窗口');
      // future 已以失败文案完成（排空验证无悬挂）
      unawaited(future.then((message) {
        expect(message, '移动超时，标签可能已在目标窗口');
      }));
      async.flushMicrotasks();
    });
  });

  test('listMoveTargets：仅子窗、按开窗序编号、exclude 过滤', () {
    registry.registerChild('w1', {'a_1'});
    registry.registerChild('w2', {'a_2'});

    final all = service.listMoveTargets(excludeWindowId: null);
    expect(all.map((e) => e.id), ['w1', 'w2']);
    expect(all.map((e) => e.label), ['直播间窗口 1', '直播间窗口 2']);

    final filtered = service.listMoveTargets(excludeWindowId: 'w1');
    expect(filtered.single.id, 'w2');
  });

  test('handleWindowCall：mListWindows 主窗口固定符号项在前', () async {
    registry.registerChild('w1', {'a_1'});
    final raw = await service.handleWindowCall(
        WindowControlProtocol.mListWindows, null);
    final list = WindowControlProtocol.decodeWindowList(raw)!;
    expect(list.first.id, WindowControlProtocol.targetMain);
    expect(list.first.label, '主窗口');
    expect(list.last.id, 'w1');
    expect(list.last.label, '直播间窗口 1');
  });

  test('handleWindowCall：mRequestMove 子→主端到端回执 true', () async {
    registry.registerChild('w1', {'douyin_a'});
    final raw = await service.handleWindowCall(
      WindowControlProtocol.mRequestMove,
      WindowControlProtocol.encodeRequestMove(
        const WindowMoveCall(
          sourceWindowId: 'w1',
          tabId: 'ta',
          siteId: 'douyin',
          roomId: 'a',
          shareUrl: '',
          target: WindowControlProtocol.targetMain,
        ),
      ),
    );
    final result = WindowControlProtocol.decodeMoveResult(raw)!;
    expect(result.ok, isTrue);
    expect(store.tabs.single.tabId, 'ta');
  });

  test('handleWindowCall：非法载荷与未知方法', () async {
    final bad = await service.handleWindowCall(
        WindowControlProtocol.mRequestMove, null);
    expect(WindowControlProtocol.decodeMoveResult(bad)!.ok, isFalse);
    expect(WindowControlProtocol.decodeMoveResult(bad)!.message, '移动失败，请重试');
    expect(
      await service.handleWindowCall('mw_unknown', null),
      isNull,
    );
  });

  test('在途重入被拒：同一 tabId 并发第二次立即失败且不重发 mw_open_tab',
      () async {
    handoff.mode = 'hang';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final first = service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    // 第一次已建立 handoff 并挂起在 await 点
    expect(handoff.prepares, hasLength(1));

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '移动失败，请重试');
    expect(toasts, ['移动失败，请重试'], reason: '主源重入失败在主端 toast');
    expect(calls('w1', WindowControlProtocol.mOpenTab), hasLength(1),
        reason: '重入不再发第二次 mw_open_tab');

    // 收尾：放行第一次迁移以免悬挂
    handoff.hang!.complete();
    expect(await first, isNull);
  });

  test('失败：closeForMove 抛错（源标签被手关）收口移动失败请重试，主源有 toast',
      () async {
    handoff.mode = 'none';
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));
    port.onInvoke = (w, m, a) {
      if (m == WindowControlProtocol.mOpenTab) {
        // 迁移途中源标签被用户手关 → step5 closeForMove 抛 ArgumentError
        store.close(tab.tabId);
        return true;
      }
      return null;
    };

    final message = await service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(message, '移动失败，请重试');
    expect(toasts, ['移动失败，请重试'], reason: '主源失败在主端 toast');
    expect(store.tabs, isEmpty);
  });

  test('目标窗死亡：handoff 失败结算走超时文案，异常不逃逸、源不动', () async {
    handoff.mode = 'hang';
    port.onInvoke = (w, m, a) => m == WindowControlProtocol.mOpenTab;
    registry.registerChild('w1', {'douyin_b'});
    final tab = store.open(req('douyin', 'a'));

    final future = service.moveTabToWindow(
      tabId: tab.tabId,
      target: 'w1',
    );
    expect(handoff.prepares, hasLength(1), reason: 'handoff 已建立');

    // 目标窗在 handoff 结算前死亡 → future 以异常结算
    handoff.hang!.completeError(StateError('dest gone'));

    final message = await future;
    expect(message, '移动超时，标签可能已在目标窗口');
    expect(toasts, ['移动超时，标签可能已在目标窗口']);
    expect(store.tabs.single.tabId, tab.tabId, reason: '源不动继续播放');
  });
}
