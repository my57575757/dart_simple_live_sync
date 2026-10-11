import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'douyin_guest_verify_controller.dart';

class DouyinGuestVerifyPage extends StatelessWidget {
  const DouyinGuestVerifyPage({super.key});

  static const double _viewAspect = 1280 / 800;

  @override
  Widget build(BuildContext context) {
    final panel = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) controller.cancel();
      },
      child: buildScaffold(),
    );
    if (!Platform.isWindows) return panel;
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Center(
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.72,
          height: MediaQuery.of(context).size.height * 0.9,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: panel,
          ),
        ),
      ),
    );
  }

  DouyinGuestVerifyController get controller =>
      Get.find<DouyinGuestVerifyController>();

  Widget buildScaffold() {
    return Scaffold(
      appBar: AppBar(
        title: const Text("游客验证"),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: controller.cancel,
        ),
        actions: [
          Obx(
            () => IconButton(
              tooltip: "重新加载",
              icon: const Icon(Icons.refresh),
              onPressed: controller.state.value == "verifying"
                  ? null
                  : controller.reload,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          buildStatusBar(),
          Expanded(child: Center(child: buildViewArea())),
          const Padding(
            padding: EdgeInsets.all(8.0),
            child: Text(
              "请按画面提示完成滑块验证；通过后自动进入直播间，验证结果仅保存 12 小时",
              style: TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget buildStatusBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          Obx(() {
            final text = switch (controller.state.value) {
              "starting" => "验证页打开中…",
              "verifying" => "验证生效中，请勿操作…",
              "verified" => "验证成功",
              "closed" => "验证已结束",
              _ => switch (controller.phase.value) {
                  "captcha" => "请完成滑块验证",
                  "interactive" => "等待验证生效…",
                  _ => "页面加载中…",
                },
            };
            final busy = controller.state.value == "starting" ||
                controller.state.value == "verifying";
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Text(text, style: const TextStyle(fontSize: 13)),
              ],
            );
          }),
          const Spacer(),
          Obx(() {
            final ms = controller.remainingMs.value;
            if (ms <= 0 || controller.state.value == "verified") {
              return const SizedBox.shrink();
            }
            return Text(
              "剩余 ${(ms ~/ 60000)}:${((ms % 60000) ~/ 1000).toString().padLeft(2, '0')}",
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            );
          }),
        ],
      ),
    );
  }

  Widget buildViewArea() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: AspectRatio(
        aspectRatio: _viewAspect,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final box = SizeLite(constraints.maxWidth, constraints.maxHeight);
            return Stack(
              fit: StackFit.expand,
              children: [
                Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) {
                    if (e.kind != PointerDeviceKind.touch &&
                        e.buttons != kPrimaryMouseButton) {
                      return;
                    }
                    controller.onPointerDown(
                      OffsetLite(e.localPosition.dx, e.localPosition.dy),
                      box,
                    );
                  },
                  onPointerMove: (e) => controller.onPointerMove(
                    OffsetLite(e.localPosition.dx, e.localPosition.dy),
                    box,
                    down: e.down,
                  ),
                  onPointerUp: (e) => controller.onPointerUp(
                    OffsetLite(e.localPosition.dx, e.localPosition.dy),
                    box,
                  ),
                  onPointerSignal: (e) {
                    if (e is PointerScrollEvent) {
                      controller.onPointerScroll(
                        OffsetLite(e.localPosition.dx, e.localPosition.dy),
                        box,
                        dx: e.scrollDelta.dx,
                        dy: e.scrollDelta.dy,
                      );
                    }
                  },
                  child: Obx(() {
                    final data = controller.frame.value;
                    if (data == null || data.isEmpty) {
                      return Container(color: Colors.white);
                    }
                    return Image.memory(
                      data,
                      fit: BoxFit.fill,
                      gaplessPlayback: true,
                    );
                  }),
                ),
                buildFingerDot(box),
                buildLoadingOverlay(),
                buildVerifyingScrim(),
                buildFrameBrokenBanner(),
                buildFatalOverlay(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget buildFingerDot(SizeLite box) {
    return Obx(() {
      final p = controller.finger.value;
      if (p == null) return const SizedBox.shrink();
      return Positioned(
        left: p.x - 10,
        top: p.y - 10,
        child: IgnorePointer(
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.blue.withValues(alpha: 0.35),
              border: Border.all(color: Colors.blue, width: 1.5),
            ),
          ),
        ),
      );
    });
  }

  Widget buildLoadingOverlay() {
    return Obx(() {
      final show = controller.starting.value ||
          (!controller.hasFrame &&
              controller.fatalMessage.value.isEmpty &&
              controller.state.value != "closed");
      if (!show) return const SizedBox.shrink();
      return const ColoredBox(
        color: Colors.white,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text("验证画面加载中…", style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    });
  }

  Widget buildVerifyingScrim() {
    return Obx(() {
      if (controller.state.value != "verifying") {
        return const SizedBox.shrink();
      }
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: Container(
          color: Colors.black54,
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: const Center(
            child: Text(
              "验证生效中，请勿操作",
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
        ),
      );
    });
  }

  Widget buildFrameBrokenBanner() {
    return Obx(() {
      if (!controller.frameBroken.value ||
          controller.fatalMessage.value.isNotEmpty ||
          controller.state.value == "verifying") {
        return const SizedBox.shrink();
      }
      return Positioned(
        top: 8,
        left: 8,
        right: 8,
        child: Center(
          child: Material(
            color: Colors.orange.shade100,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("画面中断", style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 30),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: controller.reload,
                    child: const Text("重新加载"),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget buildFatalOverlay() {
    return Obx(() {
      final msg = controller.fatalMessage.value;
      if (msg.isEmpty) return const SizedBox.shrink();
      return ColoredBox(
        color: Colors.white,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: Colors.orange, size: 40),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  msg,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FilledButton.icon(
                    onPressed: controller.retry,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text("重新开始"),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: controller.cancel,
                    child: const Text("取消"),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    });
  }
}
