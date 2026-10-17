import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_descriptor.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class _FakeRegistry implements RoomControllerRegistry {
  final registered = <String, TabOpenRequest>{};
  int unregisterCount = 0;
  @override
  void register(String tabId, TabOpenRequest request) =>
      registered[tabId] = request;
  @override
  void unregister(String tabId) {
    registered.remove(tabId);
    unregisterCount++;
  }
  @override
  bool isRegistered(String tabId) => registered.containsKey(tabId);
  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;
  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

class _ThrowingRegistry extends _FakeRegistry {
  @override
  void register(String tabId, TabOpenRequest request) =>
      throw ArgumentError('unknown site: ${request.siteId}');
}

class _FakeControlPort implements SubWindowControlPort {
  final calls = <(String, Object?)>[];
  Object? result;
  Object? error;
  @override
  Future<Object?> invokeMain(String method, [Object? args]) async {
    calls.add((method, args));
    if (error != null) throw error!;
    return result;
  }
}

void main() {
  late _FakeControlPort port;
  late TabStore store;
  final toasts = <String>[];

  SubWindowControlService buildService({TabStore? givenStore}) {
    return SubWindowControlService(
      windowId: 'w1',
      port: port,
      store: givenStore ?? store,
      showToast: toasts.add,
    );
  }

  setUp(() {
    port = _FakeControlPort();
    store = TabStore(registry: _FakeRegistry(), hasHome: false);
    toasts.clear();
  });

  group('requestWindowList', () {
    test('解码主端窗口列表', () async {
      port.result = WindowControlProtocol.encodeWindowList(const [
        WindowListEntry(id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
      final list = await buildService().requestWindowList();
      expect(port.calls.single.$1, WindowControlProtocol.mListWindows);
      expect(list.map((e) => e.id), ['__main__', 'w2']);
      expect(list.map((e) => e.label), ['主窗口', '直播间窗口 2']);
    });

    test('非法/空回执返回空列表', () async {
      port.result = 'nope';
      expect(await buildService().requestWindowList(), isEmpty);
      port.result = null;
      expect(await buildService().requestWindowList(), isEmpty);
    });
  });

  group('requestMove', () {
    TabDescriptor tab() => TabDescriptor(
          tabId: 'tab-1',
          request: TabOpenRequest(
            siteId: 'douyin',
            roomId: 'r1',
            shareUrl: 'https://live.douyin.com/r1',
          ),
        );

    test('成功：载荷带 sourceWindowId/预定 tabId/四元组/target，无 toast',
        () async {
      port.result =
          WindowControlProtocol.encodeMoveResult(true);
      final ok = await buildService()
          .requestMove(tab: tab(), target: 'w2');
      expect(ok, isTrue);
      expect(toasts, isEmpty);

      final call = WindowControlProtocol.decodeRequestMove(
          port.calls.single.$2)!;
      expect(call.sourceWindowId, 'w1');
      expect(call.tabId, 'tab-1');
      expect(call.siteId, 'douyin');
      expect(call.roomId, 'r1');
      expect(call.shareUrl, 'https://live.douyin.com/r1');
      expect(call.target, 'w2');
    });

    test('主端回执 ok:false：显示主端 message 并返回 false', () async {
      port.result = WindowControlProtocol.encodeMoveResult(
          false,
          message: '目标窗口无响应');
      final ok = await buildService()
          .requestMove(tab: tab(), target: 'w2');
      expect(ok, isFalse);
      expect(toasts, ['目标窗口无响应']);
    });

    test('回执非法/null：兜底文案 toast，不抛错', () async {
      port.result = {'ok': 'x'};
      expect(
          await buildService().requestMove(tab: tab(), target: 'w2'), isFalse);
      expect(toasts, ['移动失败，请重试']);

      port.result = null;
      expect(
          await buildService().requestMove(tab: tab(), target: 'w2'), isFalse);
      expect(toasts, ['移动失败，请重试', '移动失败，请重试']);
    });

    test('invokeMain 抛错：兜底文案 toast，不 rethrow', () async {
      port.error = StateError('channel gone');
      expect(
          await buildService().requestMove(tab: tab(), target: '__main__'),
          isFalse);
      expect(toasts, ['移动失败，请重试']);
    });
  });

  group('handleCall', () {
    test('mw_open_tab：以预定 tabId 落标签；activate 透传', () async {
      final svc = buildService();
      final result = await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'fixed-id',
            siteId: 'douyin',
            roomId: 'r9',
            shareUrl: '',
            activate: false,
          ),
        ),
      );
      expect(result, isTrue);
      expect(store.tabs.single.tabId, 'fixed-id');
      expect(store.activeTabId.value, isNull, reason: 'activate:false 不切换');

      await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'fixed-id-2',
            siteId: 'douyu',
            roomId: 'r10',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(store.activeTabId.value, 'fixed-id-2');
    });

    test('mw_open_tab：载荷非法返回 false', () async {
      expect(await buildService().handleCall(
          WindowControlProtocol.mOpenTab, null), isFalse);
    });

    test('mw_open_tab：register 抛错（未知 site）返回 false、不留标签',
        () async {
      final throwingStore = TabStore(
        registry: _ThrowingRegistry(),
        hasHome: false,
      );
      final result = await buildService(givenStore: throwingStore).handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 'x',
            siteId: 'unknown-site',
            roomId: '1',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(result, isFalse);
      expect(throwingStore.tabs, isEmpty);
    });

    test('mw_close_tab：迁移关闭走 closeForMove；未知 tabId/非法载荷 false',
        () async {
      final svc = buildService();
      await svc.handleCall(
        WindowControlProtocol.mOpenTab,
        WindowControlProtocol.encodeOpenTab(
          const OpenTabCall(
            tabId: 't1',
            siteId: 'douyin',
            roomId: '111',
            shareUrl: '',
            activate: true,
          ),
        ),
      );
      expect(
        await svc.handleCall(
          WindowControlProtocol.mCloseTab,
          WindowControlProtocol.encodeCloseTab(const CloseTabCall(tabId: 't1')),
        ),
        isTrue,
      );
      expect(store.tabs, isEmpty);

      expect(
        await svc.handleCall(
          WindowControlProtocol.mCloseTab,
          WindowControlProtocol.encodeCloseTab(const CloseTabCall(tabId: 'gone')),
        ),
        isFalse,
      );
      expect(
        await svc.handleCall(WindowControlProtocol.mCloseTab, null),
        isFalse,
      );
    });

    test('未知方法返回 null（单 handler 槽位继续向 default 回落）', () async {
      expect(await buildService().handleCall('something_else', null), isNull);
    });
  });
}
