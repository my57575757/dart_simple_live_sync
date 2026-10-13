import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/mine/account/web_load_watchdog.dart';

void main() {
  group('WebLoadWatchdog 环境创建看门狗', () {
    test('8 秒内未 onWebViewCreated：判定环境初始化失败（白屏事故模型）', () {
      final dog = WebLoadWatchdog();
      dog.start(0);

      expect(dog.poll(7999), isFalse);
      expect(dog.phase, WebLoadPhase.starting);

      expect(dog.poll(8000), isTrue);
      expect(dog.phase, WebLoadPhase.failed);
      expect(dog.failReason, 'init');
    });

    test('失败边沿只报告一次，后续 poll 不重复触发', () {
      final dog = WebLoadWatchdog();
      dog.start(0);

      expect(dog.poll(8000), isTrue);
      expect(dog.poll(9000), isFalse);
    });

    test('8 秒内 created：解除环境看门狗', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(5000);

      expect(dog.poll(8000), isFalse);
      expect(dog.phase, WebLoadPhase.loading);
    });
  });

  group('WebLoadWatchdog 导航看门狗', () {
    test('created 后 15 秒导航无结果：判定加载失败', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(1000);

      expect(dog.poll(15999), isFalse);
      expect(dog.poll(16000), isTrue);
      expect(dog.phase, WebLoadPhase.failed);
      expect(dog.failReason, 'nav');
    });

    test('onLoadStart 重置导航计时', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(0);
      // created 后第 14 秒才真正开始导航，计时应以 loadStart 为准
      dog.markLoadStart(14000);

      expect(dog.poll(28999), isFalse);
      expect(dog.poll(29000), isTrue);
      expect(dog.failReason, 'nav');
    });

    test('onLoadStop 到达即 ready，之后不再判定失败', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(100);
      dog.markLoadStart(200);
      dog.markLoadStop();

      expect(dog.phase, WebLoadPhase.ready);
      // 444 退避 reload 等后续导航即便很慢，也不得用遮罩盖住可见页面
      dog.markLoadStart(10000);
      expect(dog.poll(60000), isFalse);
      dog.markFatal();
      expect(dog.phase, WebLoadPhase.ready);
    });

    test('redirect 模式：首个 onLoadStart 即视为成功（该模式不保证触发 loadStop）',
        () {
      final dog = WebLoadWatchdog(readyOnFirstStart: true);
      dog.start(0);
      dog.markCreated(100);
      dog.markLoadStart(500);

      expect(dog.phase, WebLoadPhase.ready);
      expect(dog.poll(60000), isFalse);
    });

    test('主框架 onReceivedError：立即失败，不必等超时', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(100);
      dog.markLoadStart(200);
      dog.markFatal();

      expect(dog.phase, WebLoadPhase.failed);
      expect(dog.failReason, 'network');
    });
  });

  group('WebLoadWatchdog 终态与迟到事件', () {
    test('failed 后迟到的 created/load 事件不得复活状态机', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markFatal();
      dog.markCreated(200);
      dog.markLoadStart(300);
      dog.markLoadStop();

      expect(dog.phase, WebLoadPhase.failed);
    });

    test('starting 阶段先收到 loadStart（created 事件缺失）也按加载中处理', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markLoadStart(1000);

      expect(dog.phase, WebLoadPhase.loading);
      expect(dog.poll(15999), isFalse);
      expect(dog.poll(16000), isTrue);
    });
  });

  group('WebLoadWatchdog 重试策略', () {
    test('首次失败自动重试一次，共 3 次尝试，耗尽后不再可重试', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markFatal();

      expect(dog.attempt, 0);
      expect(dog.shouldAutoRetry, isTrue);
      expect(dog.canRetry, isTrue);

      dog.retry(200);
      expect(dog.attempt, 1);
      expect(dog.phase, WebLoadPhase.starting);
      dog.markFatal();
      expect(dog.shouldAutoRetry, isFalse);
      expect(dog.canRetry, isTrue);

      dog.retry(400);
      expect(dog.attempt, 2);
      dog.markFatal();
      expect(dog.canRetry, isFalse);
      expect(dog.shouldAutoRetry, isFalse);
    });

    test('未失败时 retry 无效', () {
      final dog = WebLoadWatchdog();
      dog.start(0);
      dog.markCreated(100);
      dog.retry(200);

      expect(dog.attempt, 0);
      expect(dog.phase, WebLoadPhase.loading);
    });
  });
}
