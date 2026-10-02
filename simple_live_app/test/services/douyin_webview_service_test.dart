import 'dart:async';
import 'dart:convert';

import 'package:simple_live_app/services/douyin_webview_service.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview_platform_interface/flutter_inappwebview_platform_interface.dart';
import 'package:flutter_inappwebview_windows/flutter_inappwebview_windows.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseCookiePairs', () {
    test('正常多对', () {
      expect(
        DouyinWebViewService.parseCookiePairs('a=b; c=d'),
        equals({'a': 'b', 'c': 'd'}),
      );
    });

    test('带空格可解析', () {
      expect(
        DouyinWebViewService.parseCookiePairs('  a=b ; c=d  '),
        equals({'a': 'b', 'c': 'd'}),
      );
    });

    test('空串返回空 Map', () {
      expect(DouyinWebViewService.parseCookiePairs(''), isEmpty);
    });

    test('无等号/空名的片段被跳过', () {
      expect(
        DouyinWebViewService.parseCookiePairs('noequal; =b; a=b'),
        equals({'a': 'b'}),
      );
    });

    test('value 中允许含等号', () {
      expect(
        DouyinWebViewService.parseCookiePairs('a=b=c'),
        equals({'a': 'b=c'}),
      );
    });
  });

  group('validateResponse', () {
    test('空 html 抛风控提示', () {
      expect(
        () => DouyinWebViewService.validateResponse(200, ''),
        throwsA(isA<DouyinWebViewException>()),
      );
    });

    test('小页面含 captcha 抛人机验证提示', () {
      final html = '<html>captcha /verify</html>'.padRight(6000, 'x');
      expect(
        () => DouyinWebViewService.validateResponse(200, html),
        throwsA(
          isA<DouyinWebViewException>().having(
            (e) => e.message,
            'message',
            contains('人机验证'),
          ),
        ),
      );
    });

    test('小页面普通内容抛页面异常提示', () {
      final html = '<html>nothing</html>'.padRight(6000, 'x');
      expect(
        () => DouyinWebViewService.validateResponse(200, html),
        throwsA(isA<DouyinWebViewException>()),
      );
    });

    test('HTTP >=400 抛带状态码提示', () {
      expect(
        () => DouyinWebViewService.validateResponse(500, 'x' * 30000),
        throwsA(
          isA<DouyinWebViewException>().having(
            (e) => e.message,
            'message',
            contains('500'),
          ),
        ),
      );
    });

    test('正常大小页面通过', () {
      expect(
        () => DouyinWebViewService.validateResponse(200, 'a' * 30000),
        returnsNormally,
      );
    });
  });

  group('buildFetchScript', () {
    test('包含凭证模式、路径与 token', () {
      final script = DouyinWebViewService.buildFetchScript(
        'tok123',
        '201413078149',
      );
      expect(script, contains("credentials:'include'"));
      expect(script, contains('201413078149'));
      expect(script, contains('tok123'));
    });

    test('fetch 路径斜杠必须在引号内（否则 JS 语法错误）', () {
      final script = DouyinWebViewService.buildFetchScript(
        'tok123',
        '201413078149',
      );
      expect(script, contains('fetch("/201413078149",'));
      expect(script, isNot(contains('fetch(/"')));
    });

    test('恶意 webRid 经 JSON 编码转义，不产生裸注入', () {
      const evil = 'a"});alert(1);//';
      final script = DouyinWebViewService.buildFetchScript('t', evil);
      expect(script, contains(jsonEncode('/$evil')));
      expect(script, isNot(contains(evil)));
    });
  });

  group('buildPollScript', () {
    test('包含 token', () {
      expect(
        DouyinWebViewService.buildPollScript('tokABC'),
        contains('tokABC'),
      );
    });
  });

  group('buildSilenceMediaScript', () {
    final script = DouyinWebViewService.buildSilenceMediaScript();

    test('暂停并静音已有 video/audio', () {
      expect(script, contains("querySelectorAll('video,audio')"));
      expect(script, contains('.pause()'));
      expect(script, contains('.muted=true'));
    });

    test('捕获阶段拦截后续 play，防止页面脚本重新播放', () {
      expect(script, contains("addEventListener('play'"));
      expect(script, contains('true'), reason: '必须用捕获阶段');
    });
  });

  group('WebView2 启动失败重试', () {
    setUpAll(() {
      InAppWebViewPlatform.instance = WindowsInAppWebViewPlatform();
    });

    const sharedChannel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );

    test('首次创建失败（用户数据目录锁）后退避重试，成功取回房间页', () {
      fakeAsync((async) {
        var runCount = 0;
        var pollCount = 0;

        MethodChannel controllerChannel(String id) =>
            MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

        final service = DouyinWebViewService();

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sharedChannel, (call) async {
          if (call.method != 'run') return null;
          runCount++;
          final args = (call.arguments as Map).cast<String, dynamic>();
          final id = args['id'] as String;
          if (runCount == 1) {
            throw PlatformException(
              code: '0',
              message: 'Cannot create the HeadlessInAppWebView instance!',
            );
          }
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(controllerChannel(id), (
                webCall,
              ) async {
            switch (webCall.method) {
              case 'getUrl':
                return 'https://live.douyin.com/';
              case 'evaluateJavascript':
                final source = (webCall.arguments as Map)['source'] as String;
                if (source.contains('JSON.stringify')) {
                  pollCount++;
                  if (pollCount == 1) {
                    // 原生 dump() 会给 JS 字符串结果再加一层 JSON 引号
                    return jsonEncode('{"s":"pending"}');
                  }
                  final state = jsonEncode({
                    's': 'done',
                    'code': 200,
                    'html': 'x' * 30000,
                  });
                  return jsonEncode(state);
                }
            }
            return null;
          });
          Timer.run(service.completeFirstLoadForTesting);
          return true;
        });

        String? html;
        Object? error;
        unawaited(
          () async {
            try {
              html = await service.fetchRoomHtmlForTesting(
                '699394970561',
                '',
              );
            } catch (e) {
              error = e;
            }
          }(),
        );

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(error, isNull);
        expect(runCount, 2, reason: '首次失败后应退避重试一次');
        expect(html?.length ?? 0, greaterThan(20000));
      });
    });
  });
}
