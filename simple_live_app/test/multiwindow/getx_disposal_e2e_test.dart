import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_batch_releaser.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_app/modules/mine/account/web_login.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class _FakeGuard extends GuardServerService {
  int enters = 0;
  int exits = 0;

  @override
  bool get configured => true;

  @override
  String? savedAccountId(String platform) => 'acct1';

  @override
  Future<String?> ensureAccount(String platform) async => 'acct1';

  @override
  Future<Map<String, dynamic>> enterRoom({
    required String accountId,
    required String roomId,
    String? webRid,
    Map<String, dynamic>? extra,
  }) async {
    enters++;
    return {'joined': false, 'starGuard': false};
  }

  @override
  Future<void> exitRoom({
    required String accountId,
    required String roomId,
    String? webRid,
    Map<String, dynamic>? extra,
  }) async {
    exits++;
  }
}

class _FakeTab implements DouyinPresenceTab {
  _FakeTab(this.id, this.webRid);
  final String id;
  final String webRid;
  bool closed = false;

  @override
  String get tabId => id;
  @override
  bool get isClosed => closed;
  @override
  String get guardRoomId => 'room_$webRid';
  @override
  String get guardWebRid => webRid;
  @override
  Map<String, dynamic> guardExtraArgs() => const {};

  @override
  Future<LiveRoomDetail> fetchAccountDetail() async => LiveRoomDetail(
        roomId: webRid,
        title: 't',
        cover: '',
        userName: 'u',
        userAvatar: '',
        online: 1,
        status: true,
        url: 'https://live.douyin.com/$webRid',
        danmakuData: DouyinDanmakuArgs(
          webRid: webRid,
          roomId: 'room_$webRid',
          userId: 'uid_$webRid',
          cookie: '',
        ),
      );

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {}

  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {}

  @override
  Future<void> applyYieldToGuest() async {}

  @override
  Future<void> applySuspended() async {}
}

/// 与 LiveRoomController._leaveDouyinPresence 同构的 GetX 销毁契约：
/// onClose → release → 网关摘栈。用真实 Get.put(permanent)+Get.delete(force)
/// 走 GetX 注销序，而不是手调 release。
class _DisposingController extends GetxController {
  _DisposingController({
    required this.tabId,
    required this.gateway,
    required this.tab,
    required this.events,
    required this.pendingRelease,
  });

  final String tabId;
  final DouyinPresenceGateway gateway;
  final _FakeTab tab;
  final List<String> events;
  final List<Future<void>> pendingRelease;

  @override
  void onClose() {
    events.add('onClose:$tabId');
    tab.closed = true;
    // 生产侧是 unawaited(_leaveDouyinPresence)，此处收口 Future 供测试排空
    pendingRelease.add(gateway.release(tabId));
    super.onClose();
  }
}

/// 记录 batchRelease 调用点，验证「先摘栈再销毁控制器」
class _LoggingBatchReleaser implements PresenceBatchReleaser {
  _LoggingBatchReleaser(this.inner, this.events);
  final DouyinPresenceGateway inner;
  final List<String> events;

  @override
  Future<void> batchRelease(Set<String> tabIds) async {
    events.add('batchRelease:${tabIds.join(',')}');
    await inner.batchRelease(tabIds);
  }
}

class _DisposingRegistry implements RoomControllerRegistry {
  _DisposingRegistry({
    required this.gateway,
    required this.events,
  });

  final DouyinPresenceGateway gateway;
  final List<String> events;

  /// 跨控制器收口 release Future：unregister 后实例已从 map 移除，
  /// 但 onClose 挂起的 release 仍需排空
  final List<Future<void>> pendingRelease = [];
  final Map<String, _DisposingController> controllers = {};
  final Map<String, _FakeTab> tabs = {};

  @override
  void register(String tabId, TabOpenRequest request) {
    final tab = _FakeTab(tabId, request.roomId);
    final c = _DisposingController(
      tabId: tabId,
      gateway: gateway,
      tab: tab,
      events: events,
      pendingRelease: pendingRelease,
    );
    tabs[tabId] = tab;
    controllers[tabId] = c;
    // 与 GetxRoomControllerRegistry 同构：permanent + tag，unregister 时 force delete
    Get.put<_DisposingController>(c, tag: tabId, permanent: true);
  }

  @override
  void unregister(String tabId) {
    events.add('unregister:$tabId');
    // 真实 GetX 删除：permanent 实例必须 force，才会触发 onClose 释放序
    Get.delete<_DisposingController>(tag: tabId, force: true);
    controllers.remove(tabId);
    tabs.remove(tabId);
  }

  @override
  bool isRegistered(String tabId) =>
      Get.isRegistered<_DisposingController>(tag: tabId);

  @override
  LiveRoomController? controllerForRoomKey(String roomKey) => null;

  @override
  LiveRoomController? controllerForTabId(String tabId) => null;
}

TabOpenRequest _req(String room) =>
    TabOpenRequest(siteId: 'douyin', roomId: room, shareUrl: '');

Future<void> _drain(_DisposingRegistry registry) async {
  await Future.wait(registry.pendingRelease);
  await Future<void>.delayed(Duration.zero);
}

void main() {
  group('N4 kWebLogin 无参深链防御', () {
    tearDown(Get.reset);

    test('无 Get.arguments：args 为 null，onInit/onClose 不 crash', () {
      final c = WebLoginController();
      expect(c.args, isNull);
      // 无参深链路径：不启动看门狗、不碰 CookieManager
      c.onInit();
      expect(c.argsMissing.value, isTrue);
      expect(c.loadFailed.value, isTrue);
      c.closePage(); // canPop=false 时 no-op，不得抛
      c.onClose();
    });

    testWidgets('Get.arguments 类型不符：args 仍为 null，不 cast 崩溃',
        (tester) async {
      await tester.pumpWidget(GetMaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => Get.to(
              () => const Scaffold(body: SizedBox()),
              arguments: 'not-a-WebLoginArgs',
            ),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(Get.arguments, 'not-a-WebLoginArgs');
      final c = WebLoginController();
      expect(c.args, isNull);
      c.onInit();
      c.onClose();
    });

    testWidgets('无参深链：WebLoginPage 展示参数错误兜底，不建 WebView', (tester) async {
      Get.put(WebLoginController());
      await tester.pumpWidget(
        const GetMaterialApp(home: WebLoginPage()),
      );
      await tester.pump();
      expect(find.textContaining('参数缺失'), findsOneWidget);
      expect(find.byType(TextButton), findsOneWidget);
      // 兜底页不得出现 WebView 容器（无 InAppWebView 平台也不该被创建）
      expect(find.byType(InAppWebView), findsNothing);
    });
  });

  group('GetX 注销序 e2e', () {
    tearDown(Get.reset);

    test('多标签逐关：onClose→release→摘栈，holder 归 null', () async {
      final guard = _FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        heartbeatInterval: const Duration(milliseconds: 100),
      );
      addTearDown(gw.stopHeartbeatForTesting);

      final events = <String>[];
      final registry = _DisposingRegistry(gateway: gw, events: events);
      final store = TabStore(
        registry: registry,
        presenceGateway: _LoggingBatchReleaser(gw, events),
      );

      final tA = store.open(_req('111'), tabId: 'A');
      final tB = store.open(_req('222'), tabId: 'B');
      expect(tA.tabId, 'A');
      expect(tB.tabId, 'B');

      await gw.claim(registry.tabs['A']!);
      await gw.claim(registry.tabs['B']!);
      expect(gw.holderTabId, 'B');
      expect(gw.isTrackedTab('A'), isTrue);
      expect(gw.isTrackedTab('B'), isTrue);

      // 逐关 A：Get.delete 触发 onClose → release → 网关摘栈
      store.close('A');
      await _drain(registry);
      expect(gw.isTrackedTab('A'), isFalse);
      expect(gw.holderTabId, 'B');
      expect(events, contains('onClose:A'));
      expect(events, contains('unregister:A'));
      expect(
        events.indexOf('onClose:A') > events.indexOf('unregister:A'),
        isTrue,
        reason: 'TabStore.close→registry.unregister→Get.delete 内触发 onClose，'
            'onClose 必须出现在 unregister 之后（真实 GetX 注销序）',
      );

      store.close('B');
      await _drain(registry);
      expect(gw.isTrackedTab('B'), isFalse);
      expect(gw.holderTabId, isNull);
      expect(guard.exits, 1);
    });

    test('批量关：batchRelease 先于控制器销毁，_tabs 一次清空', () async {
      final guard = _FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        heartbeatInterval: const Duration(milliseconds: 100),
      );
      addTearDown(gw.stopHeartbeatForTesting);

      final events = <String>[];
      final registry = _DisposingRegistry(gateway: gw, events: events);
      final store = TabStore(
        registry: registry,
        presenceGateway: _LoggingBatchReleaser(gw, events),
      );

      store.open(_req('111'), tabId: 'A');
      store.open(_req('222'), tabId: 'B');
      store.open(_req('333'), tabId: 'C');
      await gw.claim(registry.tabs['A']!);
      await gw.claim(registry.tabs['B']!);
      await gw.claim(registry.tabs['C']!);
      expect(gw.holderTabId, 'C');

      await store.closeAll();
      await _drain(registry);

      expect(gw.isTrackedTab('A'), isFalse);
      expect(gw.isTrackedTab('B'), isFalse);
      expect(gw.isTrackedTab('C'), isFalse);
      expect(gw.holderTabId, isNull);
      expect(guard.exits, 1, reason: 'batchRelease 至多一次 exit');

      final batchIdx = events.indexWhere((e) => e.startsWith('batchRelease:'));
      expect(batchIdx, greaterThanOrEqualTo(0));
      for (final id in ['A', 'B', 'C']) {
        final closeIdx = events.indexOf('onClose:$id');
        expect(closeIdx, greaterThan(batchIdx),
            reason: 'batchRelease 必须先于控制器 onClose，'
                '否则 holder 关闭会对同批将亡标签连环 enter/exit');
      }
    });

    test('关闭后心跳 Timer 停止无异常，arbiter.holder 归 null', () async {
      final guard = _FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        heartbeatInterval: const Duration(milliseconds: 50),
      );
      addTearDown(gw.stopHeartbeatForTesting);

      final events = <String>[];
      final registry = _DisposingRegistry(gateway: gw, events: events);
      final store = TabStore(
        registry: registry,
        presenceGateway: _LoggingBatchReleaser(gw, events),
      );

      store.open(_req('111'), tabId: 'A');
      await gw.claim(registry.tabs['A']!);
      expect(gw.holderTabId, 'A');

      // 先停心跳再逐关：stopHeartbeatForTesting 不得抛，关完无残留
      gw.stopHeartbeatForTesting();
      store.close('A');
      await _drain(registry);
      expect(gw.holderTabId, isNull);
      expect(gw.arbiter.holder, isNull);
    });

    test('batchRelease 后迟到 onClose 的 release 幂等，不再 exit', () async {
      final guard = _FakeGuard();
      final gw = DouyinPresenceGateway(
        guard,
        heartbeatInterval: const Duration(milliseconds: 100),
      );
      addTearDown(gw.stopHeartbeatForTesting);

      final events = <String>[];
      final registry = _DisposingRegistry(gateway: gw, events: events);
      final store = TabStore(
        registry: registry,
        presenceGateway: _LoggingBatchReleaser(gw, events),
      );

      store.open(_req('111'), tabId: 'A');
      store.open(_req('222'), tabId: 'B');
      await gw.claim(registry.tabs['A']!);
      await gw.claim(registry.tabs['B']!);

      await store.closeAll();
      await _drain(registry);

      // batchRelease 已 exit 一次；onClose 再 release 为未知 tab，幂等
      expect(guard.exits, 1);
      expect(gw.holderTabId, isNull);
    });
  });
}
