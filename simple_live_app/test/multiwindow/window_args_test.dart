import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';

void main() {
  test('完整快照往返编解码，中文与各类型不丢', () {
    const args = RoomWindowArgs(
      tabs: [
        RoomTabArg(siteId: 'douyin', roomId: '123456', shareUrl: 'https://live.douyin.com/123456'),
        RoomTabArg(siteId: 'bilibili', roomId: '654321'),
      ],
      snapshot: WindowSnapshot(
        settings: {
          'kThemeMode': 2,
          'kDanmuEnable': true,
          'kPlayerVolume': 66.5,
          'kName': '弹幕',
        },
        shield: ['垃圾词', 'bad'],
        volumes: {'douyin_123456': 33.0},
        followShareUrls: {'douyin_123456': 'https://live.douyin.com/123456', 'douyin_x': ''},
      ),
    );

    final decoded = RoomWindowArgs.decode(args.encode());

    expect(decoded.tabs.length, 2);
    expect(decoded.tabs[0].siteId, 'douyin');
    expect(decoded.tabs[0].roomId, '123456');
    expect(decoded.tabs[0].shareUrl, 'https://live.douyin.com/123456');
    expect(decoded.tabs[1].shareUrl, '');
    expect(decoded.snapshot.settings['kThemeMode'], 2);
    expect(decoded.snapshot.settings['kDanmuEnable'], true);
    expect(decoded.snapshot.settings['kPlayerVolume'], 66.5);
    expect(decoded.snapshot.settings['kName'], '弹幕');
    expect(decoded.snapshot.shield, ['垃圾词', 'bad']);
    expect(decoded.snapshot.volumes['douyin_123456'], 33.0);
    expect(decoded.snapshot.followShareUrls['douyin_123456'],
        'https://live.douyin.com/123456');
    expect(decoded.snapshot.followShareUrls['douyin_x'], '');
  });

  test('缺省 snapshot 编解码得到空集合', () {
    final decoded = RoomWindowArgs.decode(
      const RoomWindowArgs(tabs: [
        RoomTabArg(siteId: 'huya', roomId: 'r'),
      ]).encode(),
    );
    expect(decoded.snapshot.settings, isEmpty);
    expect(decoded.snapshot.shield, isEmpty);
    expect(decoded.snapshot.volumes, isEmpty);
    expect(decoded.snapshot.followShareUrls, isEmpty);
  });

  test('type 不匹配抛 FormatException', () {
    expect(
      () => RoomWindowArgs.decode('{"type":"other"}'),
      throwsA(isA<FormatException>()),
    );
  });
}
