import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// C1 回归：验证 GetxRoomControllerRegistry 依赖的 permanent + force
/// 路由生命周期语义。
///
/// 背景：GetX smartManagement 默认 full，Get.put 的非 permanent 单例会
/// reportDependencyLinkedToRoute 到创建时的当前路由；从搜索/历史/工具箱/
/// 分类详情等压栈路由内打开标签时，Get.back() 退出入口页会连带删除该控制器
/// （真 onClose：退房/停心跳/销毁播放器），标签描述符与 IndexedStack 页面
/// 却还在 → 死标签。修复：register 用 permanent: true，unregister 用
/// Get.delete(force: true)。
///
/// 真实 LiveRoomController 的 onInit 依赖 media_kit 原生播放器
/// （player.setVolume 会实例化 libmpv Player）、Hive(DBService)、
/// FollowService、AppSettingsController、BackgroundAudioService 及
/// loadData() 网络请求，flutter test 环境无法经 Get.put 完整构造
/// （既有 live_room_presence_test 也只直接 new、不走 GetX 生命周期），
/// 故此处用最小 GetxController 按 registry 完全相同的参数验证 GetX 语义：
/// 1) 压栈路由内 put permanent 控制器，路由 pop 后仍然存活；
/// 2) 同路由内的非 permanent 对照控制器在 pop 后被删除（证明本环境中
///    路由 pop 删除机制确实触发，permanent 的存活才有区分度）；
/// 3) Get.delete 不带 force 对 permanent 是空操作；
/// 4) Get.delete(force: true) 才能删除且 onClose 被调用。
class ProbeController extends GetxController {
  bool onCloseCalled = false;

  @override
  void onClose() {
    onCloseCalled = true;
    super.onClose();
  }
}

/// 暂存 put 返回的实例，供 pop 后检查 onClose 是否被调用
final Map<String, ProbeController> probeHolders = {};

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ElevatedButton(
        onPressed: () => Get.toNamed('/pushed'),
        child: const Text('push'),
      ),
    );
  }
}

class _PushedPage extends StatelessWidget {
  const _PushedPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          ElevatedButton(
            // 与 GetxRoomControllerRegistry.register 相同的 put 参数
            // （permanent: true + tag），并放一个非 permanent 对照
            onPressed: () {
              probeHolders['perm'] =
                  Get.put(ProbeController(), tag: 'perm', permanent: true);
              probeHolders['eph'] = Get.put(ProbeController(), tag: 'eph');
            },
            child: const Text('register'),
          ),
          ElevatedButton(
            onPressed: () => Get.back(),
            child: const Text('back'),
          ),
        ],
      ),
    );
  }
}

void main() {
  tearDown(() {
    probeHolders.clear();
    Get.reset();
  });

  testWidgets(
      'C1：压栈路由内注册的 permanent 控制器在路由 pop 后存活，'
      'force 前不可删、force 删除时 onClose 被调用', (tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        home: const _HomePage(),
        getPages: [
          GetPage(name: '/', page: () => const _HomePage()),
          GetPage(name: '/pushed', page: () => const _PushedPage()),
        ],
      ),
    );

    await tester.tap(find.text('push'));
    await tester.pumpAndSettle();
    expect(find.text('register'), findsOneWidget);

    // 在压栈路由 /pushed 内注册（模拟从搜索/历史等入口页打开标签）
    await tester.tap(find.text('register'));
    await tester.pump();
    expect(Get.isRegistered<ProbeController>(tag: 'perm'), isTrue);
    expect(Get.isRegistered<ProbeController>(tag: 'eph'), isTrue);

    // 退出入口页
    await tester.tap(find.text('back'));
    await tester.pumpAndSettle();
    expect(find.text('push'), findsOneWidget);

    // 对照：非 permanent 被路由 pop 连带删除（证明 pop 删除机制已触发）
    expect(Get.isRegistered<ProbeController>(tag: 'eph'), isFalse,
        reason: '非 permanent 对照控制器应随路由 pop 被删除');
    expect(probeHolders['eph']!.onCloseCalled, isTrue);

    // C1 核心：permanent 控制器在路由 pop 后仍然存活且未被 onClose
    expect(Get.isRegistered<ProbeController>(tag: 'perm'), isTrue,
        reason: 'permanent 标签控制器不得被入口路由 pop 连带删除');
    expect(probeHolders['perm']!.onCloseCalled, isFalse);

    // 不带 force 对 permanent 是空操作（对应 unregister 修复前的泄漏场景）
    final deletedWithoutForce =
        await Get.delete<ProbeController>(tag: 'perm');
    expect(deletedWithoutForce, isFalse);
    expect(Get.isRegistered<ProbeController>(tag: 'perm'), isTrue);
    expect(probeHolders['perm']!.onCloseCalled, isFalse);

    // force: true 才能删除（GetxRoomControllerRegistry.unregister 的行为），
    // 且真 onClose 被调用（退房/停心跳/销毁播放器照常执行）
    final deletedWithForce =
        await Get.delete<ProbeController>(tag: 'perm', force: true);
    expect(deletedWithForce, isTrue);
    expect(Get.isRegistered<ProbeController>(tag: 'perm'), isFalse);
    expect(probeHolders['perm']!.onCloseCalled, isTrue);
  });
}
