import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/modules/live_room/player/playback_watchdog.dart';

void main() {
  test('缓冲持续不播放：超时触发一次onTimeout', () async {
    var fires = 0;
    var playing = false;
    var active = true;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 50),
      isPlaying: () => playing,
      isActive: () => active,
      onTimeout: () => fires++,
    );

    w.onBufferingChanged(true);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(fires, 1);
  });

  test('超时前开始播放：不触发', () async {
    var fires = 0;
    var playing = false;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 80),
      isPlaying: () => playing,
      isActive: () => true,
      onTimeout: () => fires++,
    );

    w.onBufferingChanged(true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    playing = true;
    w.onPlayingChanged(true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fires, 0);
  });

  test('超时触发时已在后台/下播：不触发', () async {
    var fires = 0;
    var active = true;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 50),
      isPlaying: () => false,
      isActive: () => active,
      onTimeout: () => fires++,
    );

    w.onBufferingChanged(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    active = false;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(fires, 0);
  });

  test('缓冲结束(false)：取消，不触发', () async {
    var fires = 0;
    final w = PlaybackWatchdog(
      timeout: const Duration(milliseconds: 50),
      isPlaying: () => false,
      isActive: () => true,
      onTimeout: () => fires++,
    );

    w.onBufferingChanged(true);
    w.onBufferingChanged(false);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(fires, 0);
  });
}
