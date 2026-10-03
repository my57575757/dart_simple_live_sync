import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

    test('空 html 抛软封异常（子类），用户文案保留', () {
      expect(
        () => DouyinWebViewService.validateResponse(200, ''),
        throwsA(
          isA<DouyinSoftBlockedException>().having(
            (e) => e.message,
            'message',
            contains('空白页面'),
          ),
        ),
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

  group('软封登录引导', () {
    setUpAll(() {
      InAppWebViewPlatform.instance = WindowsInAppWebViewPlatform();
    });

    const sharedChannel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );

    MethodChannel controllerChannel(String id) =>
        MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

    /// 按 pollHtmls 序列依次返回房间页结果；返回搭建好的 service 与计数
    DouyinWebViewService buildService(List<String> pollHtmls) {
      var pollCount = 0;
      final service = DouyinWebViewService();
      service.debugDeleteAttempt = (dir) async {};

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sharedChannel, (call) async {
        if (call.method != 'run') return null;
        final args = (call.arguments as Map).cast<String, dynamic>();
        final id = args['id'] as String;
        final headlessChannel = MethodChannel(
          'com.pichillilorenzo/flutter_headless_inappwebview_$id',
        );
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(headlessChannel, (c) async => null);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(controllerChannel(id), (webCall) async {
          switch (webCall.method) {
            case 'getUrl':
              return 'https://live.douyin.com/';
            case 'evaluateJavascript':
              final source = (webCall.arguments as Map)['source'] as String;
              if (source.contains('JSON.stringify')) {
                final html = pollHtmls[pollCount.clamp(0, pollHtmls.length - 1)];
                pollCount++;
                // 模拟 WebView2 ExecuteScriptAsync：对 JS 结果再做一层 JSON 包装；
                // Windows controller 会 json.decode 一次，service 拿到内层 JSON 文本
                return jsonEncode(jsonEncode({
                  's': 'done',
                  'code': 200,
                  'html': html,
                }));
              }
          }
          return null;
        });
        Timer.run(service.completeFirstLoadForTesting);
        return true;
      });
      return service;
    }

    test('同一软封周期内多次软封只弹一次登录引导', () {
      fakeAsync((async) {
        final service = buildService(['', '']);
        var promptCount = 0;
        String? capturedRid;
        service.softBlockedPrompt = (rid) async {
          promptCount++;
          capturedRid = rid;
        };

        unawaited(() async {
          for (var i = 0; i < 2; i++) {
            try {
              await service.fetchRoomHtmlForTesting('699394970561', '');
            } catch (_) {}
          }
        }());

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(promptCount, 1, reason: '去重：同周期第二次软封不应再弹窗');
        expect(capturedRid, '699394970561', reason: '引导动作应收到房间号');
      });
    });

    test('成功取房后复位，再次软封重新引导', () {
      fakeAsync((async) {
        final service = buildService(['', 'x' * 30000, '']);
        var promptCount = 0;
        service.softBlockedPrompt = (rid) async => promptCount++;
        final errorTypes = <Type>[];

        unawaited(() async {
          for (var i = 0; i < 3; i++) {
            try {
              await service.fetchRoomHtmlForTesting('699394970561', '');
            } catch (e) {
              errorTypes.add(e.runtimeType);
            }
          }
        }());

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(
          errorTypes,
          equals([DouyinSoftBlockedException, DouyinSoftBlockedException]),
        );
        expect(promptCount, 2, reason: '中间成功复位后，再次软封应重新引导');
      });
    });

    test('完成验证后复位，再次软封重新引导', () {
      fakeAsync((async) {
        final service = buildService(['', '']);
        var promptCount = 0;
        service.softBlockedPrompt = (rid) async => promptCount++;

        unawaited(() async {
          for (var i = 0; i < 2; i++) {
            try {
              await service.fetchRoomHtmlForTesting('699394970561', '');
            } catch (_) {}
            if (i == 0) service.onVerifyCompleted();
          }
        }());

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(promptCount, 2, reason: '完成验证复位后，再次软封应重新引导');
      });
    });
  });

  group('软封轮换设备会话', () {
    setUpAll(() {
      InAppWebViewPlatform.instance = WindowsInAppWebViewPlatform();
    });

    const sharedChannel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );

    test('默认删除器递归删除目录及内部文件', () async {
      final dir = await Directory.systemTemp.createTemp('dywv_erase_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final nested = Directory('${dir.path}/EBWebView/Default');
      await nested.create(recursive: true);
      await File('${nested.path}/Cookies').writeAsString('x');

      final service = DouyinWebViewService();
      await service.eraseUserDataDirForTesting(dir);

      expect(await dir.exists(), isFalse);
    });

    test('删除遇占用（前两次失败）退避后第三次成功', () {
      fakeAsync((async) {
        var attempts = 0;
        final service = DouyinWebViewService();
        service.debugDeleteAttempt = (dir) async {
          attempts++;
          if (attempts < 3) throw StateError('directory in use');
        };

        Object? error;
        unawaited(
          service
              .eraseUserDataDirForTesting(Directory(r'D:\fake'))
              .then((_) {}, onError: (Object e) => error = e),
        );
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(error, isNull);
        expect(attempts, 3);
      });
    });

    test('连续两次空响应（软封）后重建并清除数据目录', () {
      fakeAsync((async) {
        var eraseCalls = 0;
        var runCount = 0;
        final errorTypes = <Type>[];

        MethodChannel controllerChannel(String id) =>
            MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

        final service = DouyinWebViewService();
        service.debugDeleteAttempt = (dir) async {
          eraseCalls++;
        };

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sharedChannel, (call) async {
          if (call.method != 'run') return null;
          runCount++;
          final args = (call.arguments as Map).cast<String, dynamic>();
          final id = args['id'] as String;
          // headless 自身通道（dispose 等），与 controller 通道不同名
          final headlessChannel = MethodChannel(
            'com.pichillilorenzo/flutter_headless_inappwebview_$id',
          );
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(headlessChannel, (c) async => null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(controllerChannel(id), (
                webCall,
              ) async {
            switch (webCall.method) {
              case 'getUrl':
                return 'https://live.douyin.com/';
              case 'evaluateJavascript':
                final source =
                    (webCall.arguments as Map)['source'] as String;
                if (source.contains('JSON.stringify')) {
                  final state = jsonEncode({
                    's': 'done',
                    'code': 200,
                    'html': '',
                  });
                  return jsonEncode(state);
                }
            }
            return null;
          });
          Timer.run(service.completeFirstLoadForTesting);
          return true;
        });

        unawaited(() async {
          for (var i = 0; i < 2; i++) {
            try {
              await service.fetchRoomHtmlForTesting('699394970561', '');
            } catch (e) {
              errorTypes.add(e.runtimeType);
            }
          }
        }());

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(
          errorTypes,
          equals([DouyinSoftBlockedException, DouyinSoftBlockedException]),
          reason: 'runCount=$runCount eraseCalls=$eraseCalls',
        );
        expect(eraseCalls, 1, reason: '第二次软封后应清除一次数据目录');
      });
    });
  });
}
