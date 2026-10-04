import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:test/test.dart';

/// 把 state（普通 Map）编码为页面中的 \" 转义 SSR 片段
String ssrHtml(Map<String, dynamic> state) {
  final base = jsonEncode(state).replaceAll('"', '\\"');
  const suffix = '}';
  return 'x {\\"state\\":$base$suffix]' '\\n y';
}

Map<String, dynamic> _fullState({int status = 2}) => {
      'appStore': <String, dynamic>{},
      'roomStore': {
        'roomInfo': {
          'room': {
            'id_str': '9876543210987654321',
            'status': status,
            'title': 't',
            'cover': {
              'url_list': ['c1']
            },
            'owner': {
              'nickname': 'n',
              'signature': 's',
              'avatar_thumb': {
                'url_list': ['a1']
              },
            },
            'room_view_stats': {'display_value': 42},
            'stream_url': <String, dynamic>{},
          },
          'anchor': {
            'nickname': 'an',
            'avatar_thumb': {
              'url_list': ['an1']
            },
          },
        }
      },
      'userStore': {
        'odin': {'user_unique_id': '7691511956330530313'}
      },
    };

String fullRoomHtml({int status = 2}) => ssrHtml(_fullState(status: status));

String skeletonHtml() =>
    ssrHtml({
      'appStore': <String, dynamic>{},
      'roomStore': {
        'roomInfo': {
          'web_rid': '12345678901',
          'anchor': {'nickname': 'an'},
        }
      },
      'userStore': {
        'odin': {'user_unique_id': '7691511956330530313'}
      },
    });

void main() {
  late DouyinSite site;

  setUp(() {
    site = DouyinSite();
  });

  group('getRequestHeaders 身份选择', () {
    test('全空时默认匿名 ttwid', () async {
      final h = await site.getRequestHeaders();
      expect(h['cookie'], DouyinSite.kDefaultCookie);
    });

    test('游客态用设备 cookie', () async {
      site.cookie = 'ttwid=device';
      final h = await site.getRequestHeaders();
      expect(h['cookie'], 'ttwid=device');
    });

    test('游客态即使设置了 loginCookie 也不返回', () async {
      site.cookie = 'ttwid=device';
      site.loginCookie = 'sessionid=abc';
      final h = await site.getRequestHeaders();
      expect(h['cookie'], 'ttwid=device');
      expect(h['cookie'].toString().contains('sessionid'), isFalse);
    });

    test('asAccount 且 loginCookie 有效时返回 loginCookie', () async {
      site.cookie = 'ttwid=device';
      site.loginCookie = 'sessionid=abc; ttwid=device';
      final h = await site.getRequestHeaders(asAccount: true);
      expect(h['cookie'], 'sessionid=abc; ttwid=device');
    });

    test('asAccount 但 loginCookie 无效时降级游客', () async {
      site.cookie = 'ttwid=device';
      site.loginCookie = 'other=x';
      final h = await site.getRequestHeaders(asAccount: true);
      expect(h['cookie'], 'ttwid=device');
    });
  });

  group('getRoomDetail webRid HTML 路径身份', () {
    test('游客：fetcher 收到设备 cookie，弹幕 args 无 sessionid', () async {
      String? gotCookie;
      site.cookie = 'ttwid=device';
      site.htmlFetcher = (webRid, cookie) async {
        gotCookie = cookie;
        return fullRoomHtml();
      };

      final detail = await site.getRoomDetail(roomId: '12345678901');
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(gotCookie, 'ttwid=device');
      expect(args.cookie, 'ttwid=device');
      expect(args.cookie.contains('sessionid'), isFalse);
      expect(detail.status, isTrue);
    });

    test('账号：fetcher 收到 loginCookie，弹幕 args 为 loginCookie', () async {
      String? gotCookie;
      site.cookie = 'ttwid=device';
      site.loginCookie = 'sessionid=abc; ttwid=device';
      site.htmlFetcher = (webRid, cookie) async {
        gotCookie = cookie;
        return fullRoomHtml();
      };

      final detail = await site.getRoomDetail(
        roomId: '12345678901',
        asAccount: true,
      );
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(gotCookie, 'sessionid=abc; ttwid=device');
      expect(args.cookie, 'sessionid=abc; ttwid=device');
    });

    test('账号态骨架文档抛 CoreError，不返回离线详情', () async {
      site.loginCookie = 'sessionid=abc';
      site.htmlFetcher = (webRid, cookie) async => skeletonHtml();

      expect(
        site.getRoomDetail(roomId: '12345678901', asAccount: true),
        throwsA(isA<CoreError>()),
      );
    });

    test('游客态骨架走离线详情，args 无 sessionid', () async {
      site.cookie = 'ttwid=device';
      site.htmlFetcher = (webRid, cookie) async => skeletonHtml();

      final detail = await site.getRoomDetail(roomId: '12345678901');
      expect(detail.status, isFalse);
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.cookie, 'ttwid=device');
      expect(args.cookie.contains('sessionid'), isFalse);
    });

    test('shareUrl 兜底身份与请求一致（账号）', () async {
      String? gotWebRid;
      site.loginCookie = 'sessionid=abc';
      site.htmlFetcher = (webRid, cookie) async {
        expect(cookie, 'sessionid=abc');
        if (webRid == 'badWebRid') {
          throw CoreError('首次读取失败');
        }
        gotWebRid = webRid;
        return fullRoomHtml();
      };

      final detail = await site.getRoomDetail(
        roomId: 'badWebRid;https://live.douyin.com/12345678901',
        asAccount: true,
      );
      expect(gotWebRid, '12345678901');
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.cookie, 'sessionid=abc');
    });
  });

  group('getRoomDetail 长 roomId reflow 路径', () {
    late Dio dio;
    String? reflowCookie;

    setUp(() {
      dio = HttpClient.instance.dio;
      dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('/reflow/info/')) {
            reflowCookie = options.headers['Cookie']?.toString();
            handler.resolve(
              Response<Map<String, dynamic>>(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'status_code': 0,
                  'data': {
                    'room': {
                      'id_str': '9876543210987654321',
                      'status': 2,
                      'title': 't',
                      'cover': {
                        'url_list': ['c1']
                      },
                      'owner': {
                        'web_rid': '12345678901',
                        'nickname': 'n',
                        'signature': 's',
                        'avatar_thumb': {
                          'url_list': ['a1']
                        },
                      },
                      'room_view_stats': {'display_value': 42},
                      'stream_url': <String, dynamic>{},
                    }
                  },
                },
              ),
            );
            return;
          }
          handler.next(options);
        },
      ));
    });

    test('账号态 reflow 请求仅 ttwid，但返回 args 为 loginCookie', () async {
      site.cookie = 'ttwid=device';
      site.loginCookie = 'sessionid=abc';

      final detail = await site.getRoomDetail(
        roomId: '9876543210987654321',
        asAccount: true,
      );
      expect(reflowCookie, isNotNull);
      expect(reflowCookie!.contains('ttwid'), isTrue);
      expect(reflowCookie!.contains('sessionid'), isFalse);
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.cookie, 'sessionid=abc');
    });

    test('游客态 args cookie 为设备 ttwid', () async {
      site.cookie = 'ttwid=device';

      final detail = await site.getRoomDetail(roomId: '9876543210987654321');
      final args = detail.danmakuData as DouyinDanmakuArgs;
      expect(args.cookie, 'ttwid=device');
      expect(reflowCookie!.contains('sessionid'), isFalse);
    });
  });

  group('getLiveStatus 恒游客', () {
    test('已设 loginCookie，fetcher 仍收到设备 cookie', () async {
      String? gotCookie;
      site.cookie = 'ttwid=device';
      site.loginCookie = 'sessionid=abc';
      site.htmlFetcher = (webRid, cookie) async {
        gotCookie = cookie;
        return fullRoomHtml();
      };

      expect(await site.getLiveStatus(roomId: '12345678901'), isTrue);
      expect(gotCookie, 'ttwid=device');
    });
  });
}
