import 'dart:convert';

import 'package:simple_live_app/services/douyin_webview_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
