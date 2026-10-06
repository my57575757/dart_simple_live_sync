import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/playback_watchdog.dart';

void main() {
  test('位置持续不推进：超时触发一次onTimeout', () async {
    var fires = 0;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 50),
      pollInterval: const Duration(milliseconds: 20),
      isActive: () => true,
      position: () => const Duration(seconds: 10),
      onTimeout: () => fires++,
    );

    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fires, 1);
  });

  test('位置持续推进：不触发', () async {
    var fires = 0;
    var seconds = 0;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 80),
      pollInterval: const Duration(milliseconds: 20),
      isActive: () => true,
      position: () => Duration(seconds: seconds++),
      onTimeout: () => fires++,
    );

    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(fires, 0);
  });

  test('非活动状态（暂停/后台/下播）：不触发，恢复后重新基线', () async {
    var fires = 0;
    var active = true;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 50),
      pollInterval: const Duration(milliseconds: 20),
      isActive: () => active,
      position: () => const Duration(seconds: 10),
      onTimeout: () => fires++,
    );

    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    active = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(fires, 0);
  });

  test('尚未起播（位置为0）：不触发', () async {
    var fires = 0;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 40),
      pollInterval: const Duration(milliseconds: 20),
      isActive: () => true,
      position: () => Duration.zero,
      onTimeout: () => fires++,
    );

    w.start();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fires, 0);
  });
}
