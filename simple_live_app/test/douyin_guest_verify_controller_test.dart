import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_controller.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_page.dart';
import 'package:simple_live_app/services/guard_server_service.dart';

/// 1x1 合法 PNG：假帧必须可被解码器解码，否则 Image.memory 的解码异常会被
/// 测试框架记成未处理异常
final Uint8List _k1x1Png = base64Decode(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
);

class _FakeGuard extends GuardServerService {
  Object? startError;
  final List<DouyinVerifyStatus> statuses = [];
  int statusCursor = 0;
  int frameSeq = 0;
  int frameFailuresLeft = 0;
  final List<List<VerifyPointerEvent>> sentBatches = [];
  int cancels = 0;
  int reloads = 0;

  @override
  Future<DouyinVerifySession> startVerifySession(String webRid) async {
    if (startError != null) throw startError!;
    return const DouyinVerifySession(
      sessionId: "vs_t",
      webRid: "123456",
      adopted: false,
      ttlMs: 300000,
      viewWidth: 1280,
      viewHeight: 800,
      minFrameMs: 150,
    );
  }

  @override
  Future<DouyinVerifyStatus> verifySessionStatus(String sessionId) async {
    if (statusCursor < statuses.length) {
      return statuses[statusCursor++];
    }
    return statuses.last;
  }

  @override
  Future<VerifyFrame> verifySessionFrame(String sessionId) async {
    if (frameFailuresLeft > 0) {
      frameFailuresLeft--;
      throw VerifySessionHttpException(status: 503, message: "busy");
    }
    frameSeq++;
    return VerifyFrame(
      bytes: Uint8List.fromList(_k1x1Png),
      seq: frameSeq,
      state: "active",
    );
  }

  @override
  Future<int> sendVerifyEvents(
    String sessionId,
    List<VerifyPointerEvent> events,
  ) async {
    sentBatches.add(events);
    return events.length;
  }

  @override
  Future<void> cancelVerifySession(String sessionId) async {
    cancels++;
  }

  @override
  Future<void> reloadVerifySession(String sessionId) async {
    reloads++;
  }
}

DouyinVerifyStatus _status(
  String state, {
  String phase = "captcha",
  String reason = "",
  int remainingMs = 100000,
}) =>
    DouyinVerifyStatus(
      state: state,
      phase: phase,
      webRid: "123456",
      url: "/123456",
      title: "",
      remainingMs: remainingMs,
      reason: reason,
    );

void main() {
  tearDown(Get.reset);

  group("mapPoint 线性映射与截断", () {
    test("中心/边界坐标按比例换算", () {
      final center = DouyinGuestVerifyController.mapPoint(
        "down",
        const OffsetLite(320, 200),
        const SizeLite(640, 400),
        1280,
        800,
      );
      expect(center.x, closeTo(640, 0.001));
      expect(center.y, closeTo(400, 0.001));

      final tr = DouyinGuestVerifyController.mapPoint(
        "move",
        const OffsetLite(640, 0),
        const SizeLite(640, 400),
        1280,
        800,
      );
      expect(tr.x, 1280);
      expect(tr.y, 0);
    });

    test("越界坐标 clamp 到视口内", () {
      final p = DouyinGuestVerifyController.mapPoint(
        "down",
        const OffsetLite(-50, 9999),
        const SizeLite(1000, 500),
        1280,
        800,
      );
      expect(p.x, 0);
      expect(p.y, 800);
    });

    test("盒子尺寸为 0 不产生 NaN，按 0 处理", () {
      final p = DouyinGuestVerifyController.mapPoint(
        "move",
        const OffsetLite(10, 10),
        const SizeLite(0, 0),
        1280,
        800,
      );
      expect(p.x, 0);
      expect(p.y, 0);
    });

    test("wheel 事件携带 delta", () {
      final p = DouyinGuestVerifyController.mapPoint(
        "wheel",
        const OffsetLite(100, 100),
        const SizeLite(1280, 800),
        1280,
        800,
        dx: 0,
        dy: 120,
      );
      expect(p.dy, 120);
    });
  });

  group("compressEvents 轨迹压缩", () {
    test("未超限原样返回", () {
      final list = List.generate(
        30,
        (i) => VerifyPointerEvent("move", x: i.toDouble(), y: 0),
      );
      expect(DouyinGuestVerifyController.compressEvents(list, 40), same(list));
    });

    test("超限保留开头 1/4 与最新 3/4，中间丢弃", () {
      final list = List.generate(
        100,
        (i) => VerifyPointerEvent("move", x: i.toDouble(), y: 0),
      );
      final out = DouyinGuestVerifyController.compressEvents(list, 40);
      expect(out, hasLength(40));
      // 头 10 个保留（滑块轨迹起点）
      expect(out.first.x, 0);
      expect(out[9].x, 9);
      // 尾 30 个为最新点 70..99
      expect(out[10].x, 70);
      expect(out.last.x, 99);
    });
  });

  group("reduceStatus 状态机收口", () {
    test("verified → succeed", () {
      expect(
        DouyinGuestVerifyController.reduceStatus(_status("verified")),
        VerifyUiAction.succeed,
      );
    });
    test("closed/canceled → closeCanceled", () {
      expect(
        DouyinGuestVerifyController.reduceStatus(
          _status("closed", reason: "canceled"),
        ),
        VerifyUiAction.closeCanceled,
      );
    });
    test("closed/expired 等终态 → showRetry", () {
      for (final reason in [
        "expired",
        "browser_disconnected",
        "page_crashed",
        "load_failed",
      ]) {
        expect(
          DouyinGuestVerifyController.reduceStatus(
            _status("closed", reason: reason),
          ),
          VerifyUiAction.showRetry,
          reason: reason,
        );
      }
    });
    test("active/starting/verifying → stay", () {
      for (final s in ["active", "starting", "verifying"]) {
        expect(
          DouyinGuestVerifyController.reduceStatus(_status(s)),
          VerifyUiAction.stay,
        );
      }
    });
  });

  testWidgets("验证通过：自动返回 true 且成功路径不发 cancel", (tester) async {
    final fake = _FakeGuard();
    fake.statuses.addAll([
      _status("active"),
      _status("active", phase: "interactive"),
      _status("verifying", phase: "interactive"),
      _status("verified", phase: "interactive"),
    ]);

    late Future<Object?>? resultFuture;
    await tester.pumpWidget(_buildApp(fake, () {
      resultFuture = Get.toNamed<Object?>("/verify", arguments: "123456");
    }));
    await tester.tap(find.text("open"));
    await tester.pump();
    await tester.pump();

    // 状态序列：立即拉取 #0 active；周期 1s/2s/3s → interactive/verifying/verified
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 1000));
    await tester.pump(const Duration(milliseconds: 1000));
    // verified 回调里 Get.back，补帧让路由 pop 动画走完
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final result = await resultFuture!.timeout(const Duration(seconds: 5));
    expect(result, true);
    expect(fake.cancels, 0);
  });

  testWidgets("会话打开失败：展示原因与重试/取消；取消返回 false", (tester) async {
    final fake = _FakeGuard();
    fake.startError = Exception("guard 不可达");

    late Future<Object?>? resultFuture;
    await tester.pumpWidget(_buildApp(fake, () {
      resultFuture = Get.toNamed<Object?>("/verify", arguments: "123456");
    }));
    await tester.tap(find.text("open"));

    // 路由动画 + startSession 错误落盘，逐帧等到致命覆盖层
    for (var i = 0; i < 20 && !find.text("guard 不可达").evaluate().isNotEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text("guard 不可达"), findsOneWidget);
    expect(find.text("重新开始"), findsOneWidget);

    await tester.tap(find.text("取消"));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final result = await resultFuture!.timeout(const Duration(seconds: 5));
    expect(result, false);
    // 会话从未建成（无 sessionId），cancel 不会打到服务端
    expect(fake.cancels, 0);
  });
}

/// 复刻生产导航：GetMaterialApp.getPages + BindingsBuilder 命名路由
Widget _buildApp(_FakeGuard fake, VoidCallback onOpen) {
  return GetMaterialApp(
    initialRoute: "/",
    getPages: [
      GetPage(
        name: "/",
        page: () => Scaffold(
          body: Builder(
            builder: (_) => TextButton(
              onPressed: onOpen,
              child: const Text("open"),
            ),
          ),
        ),
      ),
      GetPage(
        name: "/verify",
        page: () => const DouyinGuestVerifyPage(),
        // 注意：必须用块闭包。Get.put 写在箭头闭包里是 GetX 文档明确的坑，
        // 注册实例无法被路由生命周期保留，页面 Get.find 会间歇性失败。
        binding: BindingsBuilder(() {
          Get.put(DouyinGuestVerifyController(guard: fake));
        }),
      ),
    ],
  );
}
