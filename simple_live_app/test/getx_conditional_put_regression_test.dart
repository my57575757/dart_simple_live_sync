import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

/// 回归：多窗子引擎引导里
/// `final Svc? c = cond ? null : Get.put(Svc(), permanent: true)`
/// 这种写法，条件表达式的可空上下文类型会把 put 的泛型实参下推推断成
/// `Svc?`，注册 key 变成 "Svc?"；生产代码一律按非空 Svc 做
/// isRegistered/find，必然全部落空（子窗登录态借用 / 弹幕代理整链失效）。
/// 修复方式：put 处显式给非空泛型实参。
class ConditionalPutService extends GetxService {
  ConditionalPutService();
}

void main() {
  tearDown(Get.reset);

  test('conditional put with nullable context registers under non-nullable',
      () {
    // 经函数返回，避免流分析把条件收窄成恒真（复刻生产里可空通道变量）
    Object? portOf(bool present) => present ? Object() : null;
    final Object? port = portOf(true);

    final ConditionalPutService? service = port == null
        ? null
        : Get.put<ConditionalPutService>(ConditionalPutService(),
            permanent: true);

    expect(service, isNotNull);
    expect(Get.isRegistered<ConditionalPutService>(), isTrue,
        reason: '必须以非空类型注册；缺显式泛型时 key 会变成 '
            '"ConditionalPutService?" 而查不到');
    expect(Get.isRegistered<ConditionalPutService?>(), isFalse,
        reason: '可空类型 key 不应存在');
    expect(identical(Get.find<ConditionalPutService>(), service), isTrue);
  });
}
