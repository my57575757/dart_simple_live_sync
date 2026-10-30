// widget 覆盖：主窗/子窗移动菜单结构与服务路由。
// 环境：仅在 Windows 开发/门禁机运行（Platform.isWindows 不可 override）；
// 非 Windows 分支由 test/tab_move_menu_test.dart 纯函数用例覆盖。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_strip.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

class _RoomRegistry implements RoomControllerRegistry {
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

/// T7 之后的 SubWindowPort（invoke 返回 Object?）；菜单测试不触发真编排，
/// 所有方法给空闲实现。
class _IdlePort implements SubWindowPort {
  @override
  Future<SubWindowHandle> createRoomWindow(String argumentsJson) async =>
      const SubWindowHandle('wX');
  @override
  Future<Object?> invoke(
      String windowId, String method, Object? arguments) async {
    return null;
  }
  @override
  Future<List<String>> listWindowIds() async => const ['w2'];
  @override
  Stream<void> get windowsChanged => const Stream<void>.empty();
}

class _ControlPort implements SubWindowControlPort {
  final List<(String, Object?)> invokes = [];
  Object? result;
  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    invokes.add((method, arguments));
    return result;
  }
}

/// 主窗手势测试只验证路由到 WOS.moveTabToWindow，不跑真实编排
/// （真实编排由 window_move_orchestration_test 覆盖）。
class _RecordingWos extends WindowOpenService {
  _RecordingWos({required super.port, required super.store, required super.registry});

  final List<(String, String)> moveCalls = [];

  @override
  Future<String?> moveTabToWindow({
    required String tabId,
    String? sourceWindowId,
    required String target,
    String? siteId,
    String? roomId,
    String? shareUrl,
  }) async {
    moveCalls.add((tabId, target));
    return null;
  }
}

const _home = Scaffold(
  body: Align(alignment: Alignment.topCenter, child: TabStrip()),
);

Widget _app({bool withSmartDialog = false}) {
  if (withSmartDialog) {
    return GetMaterialApp(
      navigatorObservers: [FlutterSmartDialog.observer],
      builder: FlutterSmartDialog.init(),
      home: _home,
    );
  }
  return const GetMaterialApp(home: _home);
}

Future<void> _openContextMenu(WidgetTester tester) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.text('r1')),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void putRoomAndTab() {
  final roomRegistry = _RoomRegistry();
  final store = TabStore(registry: roomRegistry);
  store.open(TabOpenRequest(siteId: 'douyin', roomId: 'r1'));
  Get.put<RoomControllerRegistry>(roomRegistry, permanent: true);
  Get.put<TabStore>(store, permanent: true);
}

void main() {
  tearDown(() {
    MultiWindowRole.isSubWindow = false;
    Get.reset();
  });

  testWidgets('主窗：有「移到新窗口」且恒 enabled；无子窗时无「其他窗口」',
      (tester) async {
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final windows = WindowRegistry(mainWindowId: 'main');
    Get.put<WindowOpenService>(
      WindowOpenService(
          port: _IdlePort(), store: store, registry: windows),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    expect(find.text('移到新窗口'), findsOneWidget);
    expect(find.text('移到其他窗口'), findsNothing);
    final item = tester.widget<PopupMenuItem<String>>(
      find
          .ancestor(
            of: find.text('移到新窗口'),
            matching: find.byType(PopupMenuItem<String>),
          )
          .first,
    );
    expect(item.enabled, isTrue, reason: '账号态置灰已删除：任何标签恒可点');
  });

  testWidgets('主窗有子窗：点「移到其他窗口」弹二级列表，编号 1 起',
      (tester) async {
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final windows = WindowRegistry(mainWindowId: 'main')
      ..registerChild('w2', const {'douyin_other'});
    Get.put<WindowOpenService>(
      WindowOpenService(
          port: _IdlePort(), store: store, registry: windows),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);
    expect(find.text('移到其他窗口'), findsOneWidget);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pumpAndSettle();

    expect(find.text('直播间窗口 1'), findsOneWidget);
  });

  testWidgets('未注册任何窗口服务：零移动项，既有菜单不变', (tester) async {
    putRoomAndTab();
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    expect(find.text('移到新窗口'), findsNothing);
    expect(find.text('移到其他窗口'), findsNothing);
    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('复制房间链接'), findsOneWidget);
  });

  testWidgets('子窗：点「其他窗口」经 controlService 拉列表，二级排除自己',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeWindowList(const [
        WindowListEntry(
            id: WindowControlProtocol.targetMain, label: '主窗口'),
        WindowListEntry(id: 'w1', label: '直播间窗口 1'),
        WindowListEntry(id: 'w2', label: '直播间窗口 2'),
      ]);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);
    expect(find.text('移到新窗口'), findsOneWidget);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pumpAndSettle();

    expect(control.invokes.first.$1,
        WindowControlProtocol.mListWindows);
    expect(find.text('主窗口'), findsOneWidget);
    expect(find.text('直播间窗口 2'), findsOneWidget);
    expect(find.text('直播间窗口 1'), findsNothing,
        reason: '自己 windowId 必须排除');
  });

  testWidgets('子窗点「移到新窗口」：发出 mw_request_move（源/标签/目标齐全）',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeMoveResult(true);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());
    await _openContextMenu(tester);

    await tester.tap(find.text('移到新窗口'));
    await tester.pumpAndSettle();

    expect(control.invokes.single.$1,
        WindowControlProtocol.mRequestMove);
    final call =
        WindowControlProtocol.decodeRequestMove(control.invokes.single.$2)!;
    expect(call.sourceWindowId, 'w1');
    expect(call.tabId, store.tabs.single.tabId);
    expect(call.target, WindowControlProtocol.targetNew);
  });

  testWidgets('子窗：纵向拖出条带松手 → mRequestMove(targetNew)',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeMoveResult(true);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());

    // 纵向拖出条带 → 按住期间显示提示、不提前发起移动；松手后提示消失，
    // 走与右键菜单完全相同的 requestMove(targetNew) 路径
    final tabCenter = tester.getCenter(find.text('r1'));
    final gesture = await tester.startGesture(
      tabCenter,
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsOneWidget);
    expect(control.invokes, isEmpty, reason: '松手前不发起移动');
    await gesture.up();
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsNothing);
    expect(control.invokes.single.$1,
        WindowControlProtocol.mRequestMove);
    final call = WindowControlProtocol.decodeRequestMove(
        control.invokes.single.$2)!;
    expect(call.sourceWindowId, 'w1');
    expect(call.tabId, store.tabs.single.tabId);
    expect(call.target, WindowControlProtocol.targetNew);
  });

  testWidgets('主窗：纵向拖出 → WOS.moveTabToWindow(targetNew)',
      (tester) async {
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final wos = _RecordingWos(
      port: _IdlePort(),
      store: store,
      registry: WindowRegistry(mainWindowId: 'main'),
    );
    Get.put<WindowOpenService>(wos, permanent: true);
    await tester.pumpWidget(_app());

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('r1')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, -25));
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsOneWidget);
    await gesture.up();
    await tester.pump();

    expect(wos.moveCalls.single.$1, store.tabs.single.tabId);
    expect(wos.moveCalls.single.$2, WindowControlProtocol.targetNew);
  });

  testWidgets('条带内横向滚动/小幅纵向移动、无服务拖出：均不误触发',
      (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeMoveResult(
        true,
      );
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app());

    final tabCenter = tester.getCenter(find.text('r1'));

    // 横向 40px：ListView 滚动手势，不 arm
    var g = await tester.startGesture(tabCenter,
        kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsNothing);
    await g.up();
    await tester.pump();

    // 纵向 10px（中央起手仍在条带 margin 内）：不 arm
    g = await tester.startGesture(tabCenter,
        kind: PointerDeviceKind.mouse);
    await g.moveBy(const Offset(0, 10));
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsNothing);
    await g.up();
    await tester.pump();

    expect(control.invokes, isEmpty);
  });

  testWidgets('未注册移动服务：拖出无提示无动作', (tester) async {
    putRoomAndTab();
    await tester.pumpWidget(_app());

    final gesture = await tester.startGesture(
      tester.getCenter(find.text('r1')),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(const Offset(0, 30));
    await tester.pump();
    expect(find.text('松开鼠标，移入新窗口'), findsNothing);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('子窗候选为空：toast 提示且不弹二级', (tester) async {
    MultiWindowRole.isSubWindow = true;
    putRoomAndTab();
    final store = Get.find<TabStore>();
    final control = _ControlPort()
      ..result = WindowControlProtocol.encodeWindowList(const []);
    Get.put<SubWindowControlService>(
      SubWindowControlService(
          windowId: 'w1', port: control, store: store),
      permanent: true,
    );
    await tester.pumpWidget(_app(withSmartDialog: true));
    await _openContextMenu(tester);

    await tester.tap(find.text('移到其他窗口'));
    await tester.pump();
    expect(find.text('没有可移入的其他窗口'), findsOneWidget);

    // 排空 SmartDialog toast 残留 Timer（同
    // sub_window_presence_controller_test 的清理时序）
    final dismiss = SmartDialog.dismiss(status: SmartStatus.toast);
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await dismiss;
  });
}
