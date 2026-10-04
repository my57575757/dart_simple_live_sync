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

  group('stripTtwid', () {
    test('移除 cookie 串中的 ttwid，保留其余字段', () {
      expect(
        DouyinWebViewService.stripTtwid(
          'ttwid=t1; sessionid=s2; odin_tt=o3',
        ),
        equals('sessionid=s2; odin_tt=o3'),
      );
    });

    test('无 ttwid 时原样保留', () {
      expect(DouyinWebViewService.stripTtwid('a=b'), equals('a=b'));
    });

    test('空串安全', () {
      expect(DouyinWebViewService.stripTtwid(''), isEmpty);
    });
  });

  group('isAccountCookie', () {
    test('含 sessionid 为账号 cookie', () {
      expect(
        DouyinWebViewService.isAccountCookie('sessionid=abc; ttwid=t'),
        isTrue,
      );
    });

    test('仅 ttwid 为游客 cookie', () {
      expect(DouyinWebViewService.isAccountCookie('ttwid=t'), isFalse);
    });

    test('空串为游客 cookie', () {
      expect(DouyinWebViewService.isAccountCookie(''), isFalse);
    });
  });

  group('共享会话身份切换', () {
    setUpAll(() {
      InAppWebViewPlatform.instance = WindowsInAppWebViewPlatform();
    });

    const sharedChannel = MethodChannel(
      'com.pichillilorenzo/flutter_headless_inappwebview',
    );
    const cookieManagerChannel = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
    );

    MethodChannel controllerChannel(String id) =>
        MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

    /// 搭好全套 mock：cookie 调用按序记入 cookieCalls，reload 计数
    void wireMocks(
      DouyinWebViewService service,
      List<String> cookieCalls,
      void Function() reloadHook, {
      bool Function()? isThrowing,
    }) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(cookieManagerChannel, (call) async {
        cookieCalls.add(call.method);
        if (call.method == 'setCookie') {
          final args = (call.arguments as Map).cast<String, dynamic>();
          cookieCalls.add('${args['name']}=${args['value']}');
        }
        if (call.method == 'deleteAllCookies') return true;
        return null;
      });
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
              if (isThrowing?.call() ?? false) {
                throw PlatformException(code: '0', message: 'controller gone');
              }
              return 'https://live.douyin.com/';
            case 'reload':
              reloadHook();
              Timer.run(service.completeReloadForTesting);
              return null;
            case 'evaluateJavascript':
              final source =
                  (webCall.arguments as Map)['source'] as String;
              if (source.contains('JSON.stringify')) {
                // 原生通道对 JS 字符串结果加一层 JSON 引号，插件内再 decode 一层
                final state = {
                  's': 'done',
                  'code': 200,
                  'html': 'x' * 30000,
                };
                return jsonEncode(jsonEncode(state));
              }
          }
          return null;
        });
        Timer.run(service.completeFirstLoadForTesting);
        return true;
      });
    }

    test('游客空 cookie：不注入 cookie 不 reload', () {
      fakeAsync((async) {
        final cookieCalls = <String>[];
        var reloadCount = 0;
        final service = DouyinWebViewService();
        wireMocks(service, cookieCalls, () => reloadCount++);

        Object? error;
        unawaited(() async {
          try {
            await service.fetchRoomHtmlForTesting('699394970561', '');
          } catch (e) {
            error = e;
          }
        }());

        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(error, isNull);
        expect(cookieCalls, isEmpty, reason: '空 cookie 无需注入');
        expect(reloadCount, 0, reason: '首页已自然建立 ttwid');
        expect(service.sessionModeForTesting, 'guest');
      });
    });

    test('账号→游客：先 deleteAllCookies 清洗再回种 ttwid 并 reload', () {
      fakeAsync((async) {
        final cookieCalls = <String>[];
        var reloadCount = 0;
        var throwOnGetUrl = false;
        final service = DouyinWebViewService();
        wireMocks(
          service,
          cookieCalls,
          () => reloadCount++,
          isThrowing: () => throwOnGetUrl,
        );

        Object? error;
        unawaited(() async {
          try {
            await service.fetchRoomHtmlForTesting(
              '699394970561',
              'sessionid=abc; ttwid=old',
            );
            await service.fetchRoomHtmlForTesting(
              '699394970561',
              'ttwid=device',
            );
          } catch (e) {
            error = e;
          }
        }());

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(error, isNull);
        expect(service.sessionModeForTesting, 'guest');
        expect(reloadCount, 2, reason: '账号注入与游客清洗各 reload 一次');

        final sessionIndex = cookieCalls.indexOf('sessionid=abc');
        final purgeIndex = cookieCalls.indexOf('deleteAllCookies');
        final replantIndex = cookieCalls.indexOf('ttwid=device');
        expect(sessionIndex, isNonNegative);
        expect(purgeIndex, greaterThan(sessionIndex),
            reason: '账号阶段不得清空 cookie；切游客必须先清空整个 jar');
        expect(replantIndex, greaterThan(purgeIndex),
            reason: '清空后回种设备 ttwid');
        expect(cookieCalls.indexOf('ttwid=old'), isNegative,
            reason: '账号 cookie 中的旧 ttwid 不回种');

        // rebuild 后身份复位为游客：模拟通道级异常触发重建
        throwOnGetUrl = true;
        unawaited(() async {
          try {
            await service.fetchRoomHtmlForTesting(
              '699394970561',
              'sessionid=abc; ttwid=old',
            );
          } catch (_) {}
        }());

        async.elapse(const Duration(seconds: 20));
        async.flushMicrotasks();

        expect(service.sessionModeForTesting, 'guest',
            reason: '通道异常 rebuild 后身份必须复位');
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
    const cookieManagerChannel = MethodChannel(
      'com.pichillilorenzo/flutter_inappwebview_cookiemanager',
    );

    const envStaticChannel = MethodChannel(
      'com.pichillilorenzo/flutter_webview_environment',
    );

    /// 模拟 WebViewEnvironment.create：记录 userDataFolder，per-env 通道全放行
    void mockEnvCreate(List<String> envFolders) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(envStaticChannel, (call) async {
        if (call.method != 'create') return null;
        final args = (call.arguments as Map).cast<String, dynamic>();
        final id = args['id'].toString();
        final folder =
            ((args['settings'] as Map?)?['userDataFolder'] ?? '').toString();
        envFolders.add(folder);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
          MethodChannel(
            'com.pichillilorenzo/flutter_webview_environment_$id',
          ),
          (c) async => null,
        );
        return null;
      });
    }

    test('启动前清扫：删除同层过期设备目录、保留当前目录', () async {
      final parent = await Directory.systemTemp.createTemp('dywv_sweep_');
      addTearDown(() async {
        if (await parent.exists()) await parent.delete(recursive: true);
      });
      final stale1 = Directory('${parent.path}/simple_live_app.exe.WebView2');
      final stale2 = Directory('${parent.path}/simple_live_app.exe.WebView2.p1');
      final current = Directory('${parent.path}/simple_live_app.exe.WebView2.p2');
      for (final d in [stale1, stale2, current]) {
        await Directory('${d.path}/EBWebView').create(recursive: true);
      }

      final service = DouyinWebViewService();
      await service.sweepStaleUserDataDirsForTesting(
        current: current,
        parent: parent,
        prefix: 'simple_live_app.exe.WebView2',
      );

      expect(await stale1.exists(), isFalse);
      expect(await stale2.exists(), isFalse);
      expect(await current.exists(), isTrue);
    });

    test('清扫遇占用不抛错，过期目录保留等下次启动再清', () async {
      final parent = await Directory.systemTemp.createTemp('dywv_sweep_');
      addTearDown(() async {
        if (await parent.exists()) await parent.delete(recursive: true);
      });
      final current = Directory('${parent.path}/x.exe.WebView2');
      final stale = Directory('${parent.path}/x.exe.WebView2.p1');
      for (final d in [current, stale]) {
        await d.create(recursive: true);
      }

      final service = DouyinWebViewService();
      await service.sweepStaleUserDataDirsForTesting(
        current: current,
        parent: parent,
        prefix: 'x.exe.WebView2',
        deleteAttempt: (dir) async =>
            throw const PathAccessException('locked', OSError('busy', 32)),
      );

      expect(await stale.exists(), isTrue);
    });

    test('首次空响应（软封）：轮换ttwid无效后换新设备目录、重建并重试成功', () {
      fakeAsync((async) {
        var runCount = 0;
        final deletedCookies = <String>[];
        final envFolders = <String>[];

        MethodChannel controllerChannel(String id) =>
            MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

        final service = DouyinWebViewService();
        mockEnvCreate(envFolders);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(cookieManagerChannel, (call) async {
          if (call.method == 'deleteCookie') {
            deletedCookies.add(
              ((call.arguments as Map)['name'] ?? '').toString(),
            );
          }
          return null;
        });
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
              case 'reload':
                Timer.run(service.completeReloadForTesting);
                return null;
              case 'evaluateJavascript':
                final source =
                    (webCall.arguments as Map)['source'] as String;
                if (source.contains('JSON.stringify')) {
                  // 第一个（被封）会话始终返回空 body；重建后的新会话返回正常页
                  final html = runCount == 1 ? '' : 'x' * 30000;
                  final state = jsonEncode({
                    's': 'done',
                    'code': 200,
                    'html': html,
                  });
                  return jsonEncode(state);
                }
            }
            return null;
          });
          Timer.run(service.completeFirstLoadForTesting);
          return true;
        });

        Object? error;
        String? html;
        unawaited(() async {
          try {
            html = await service.fetchRoomHtmlForTesting('699394970561', '');
          } catch (e) {
            error = e;
          }
        }());

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();

        expect(error, isNull, reason: '首次软封应在当次自愈，不向调用方抛错');
        expect(deletedCookies, contains('ttwid'),
            reason: '应先在同会话轮换 ttwid');
        expect(service.profileIndexForTesting, 1,
            reason: '轮换无效后应换新设备目录，而非强删被锁的当前目录');
        expect(envFolders.single, endsWith('.WebView2.p1'),
            reason: '新浏览器会话应使用带 .p1 后缀的数据目录');
        expect(runCount, 2, reason: '应重建出第二个浏览器会话');
        expect(html?.length ?? 0, greaterThan(20000));
      });
    });

    test('首次空响应：同会话轮换ttwid后重试成功，不重建不换目录', () {
      fakeAsync((async) {
        var runCount = 0;
        var pollCount = 0;
        final deletedCookies = <String>[];

        MethodChannel controllerChannel(String id) =>
            MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

        final service = DouyinWebViewService();

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(cookieManagerChannel, (call) async {
          if (call.method == 'deleteCookie') {
            deletedCookies.add(
              ((call.arguments as Map)['name'] ?? '').toString(),
            );
          }
          return null;
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sharedChannel, (call) async {
          if (call.method != 'run') return null;
          runCount++;
          final args = (call.arguments as Map).cast<String, dynamic>();
          final id = args['id'] as String;
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
              case 'reload':
                Timer.run(service.completeReloadForTesting);
                return null;
              case 'evaluateJavascript':
                final source =
                    (webCall.arguments as Map)['source'] as String;
                if (source.contains('JSON.stringify')) {
                  pollCount++;
                  // 首次被封空响应；轮换 ttwid 后同会话即恢复
                  final html = pollCount == 1 ? '' : 'x' * 30000;
                  final state = jsonEncode({
                    's': 'done',
                    'code': 200,
                    'html': html,
                  });
                  return jsonEncode(state);
                }
            }
            return null;
          });
          Timer.run(service.completeFirstLoadForTesting);
          return true;
        });

        Object? error;
        String? html;
        unawaited(() async {
          try {
            html = await service.fetchRoomHtmlForTesting('699394970561', '');
          } catch (e) {
            error = e;
          }
        }());

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();

        expect(error, isNull);
        expect(deletedCookies, contains('ttwid'));
        expect(service.profileIndexForTesting, 0, reason: '轮换成功不应换设备目录');
        expect(runCount, 1, reason: '不应重建浏览器会话');
        expect(html?.length ?? 0, greaterThan(20000));
      });
    });

    test('轮换ttwid与新目录重建后均空：只重试一次并抛出软封', () {
      fakeAsync((async) {
        var runCount = 0;
        final envFolders = <String>[];

        MethodChannel controllerChannel(String id) =>
            MethodChannel('com.pichillilorenzo/flutter_inappwebview_$id');

        final service = DouyinWebViewService();
        mockEnvCreate(envFolders);

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(cookieManagerChannel, (call) async {
          return null;
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(sharedChannel, (call) async {
          if (call.method != 'run') return null;
          runCount++;
          final args = (call.arguments as Map).cast<String, dynamic>();
          final id = args['id'] as String;
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
              case 'reload':
                Timer.run(service.completeReloadForTesting);
                return null;
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

        Object? error;
        unawaited(() async {
          try {
            await service.fetchRoomHtmlForTesting('699394970561', '');
          } catch (e) {
            error = e;
          }
        }());

        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();

        expect(error, isA<DouyinSoftBlockedException>());
        expect(service.profileIndexForTesting, 1);
        expect(runCount, 2, reason: '轮换+重建各一次，不循环');
      });
    });
  });
}
