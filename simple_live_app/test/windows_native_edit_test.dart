import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/windows_native_edit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('simple_live/native_edit');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    WindowsNativeEdit.instance.onSubmit = null;
    WindowsNativeEdit.instance.onClosed = null;
  });

  test('nativeEditPhysicalRect 按 DPR 换算全局逻辑矩形', () {
    final rect = nativeEditPhysicalRect(
      globalLogicalOrigin: const Offset(10, 20),
      logicalSize: const Size(100, 40),
      devicePixelRatio: 1.5,
    );
    expect(rect, const Rect.fromLTWH(15, 30, 150, 60));
  });

  test('show/setText/hide 发出正确方法与参数', () async {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });

    final svc = WindowsNativeEdit.instance;
    await svc.show(
      rect: const Rect.fromLTWH(1, 2, 300, 44),
      fontSizePx: 24,
      bgColor: 0xFFFFFFFF,
      textColor: 0xFF000000,
      hintColor: 0xFF999999,
      radiusPx: 30,
      padXPx: 18,
      hintText: '说点什么…',
      text: '草稿',
    );
    await svc.setText('abc');
    await svc.hide();

    expect(calls[0].method, 'show');
    expect(calls[0].arguments, <String, dynamic>{
      'x': 1,
      'y': 2,
      'w': 300,
      'h': 44,
      'fontSize': 24.0,
      'bg': 0xFFFFFFFF,
      'textColor': 0xFF000000,
      'hintColor': 0xFF999999,
      'radius': 30,
      'padX': 18,
      'hint': '说点什么…',
      'text': '草稿',
    });
    expect(calls[1], isMethodCall('setText', arguments: 'abc'));
    expect(calls[2].method, 'hide');
  });

  test('commit 返回原生文本', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => '你好');
    expect(await WindowsNativeEdit.instance.commit(), '你好');
  });

  test('原生反向调用 submit/closed 路由到当前回调', () async {
    // 先 show 一次以安装 incoming handler
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    await WindowsNativeEdit.instance.show(
      rect: const Rect.fromLTWH(0, 0, 10, 10),
      fontSizePx: 16,
      bgColor: 0,
      textColor: 0,
      hintColor: 0,
      radiusPx: 0,
      padXPx: 0,
      hintText: '',
      text: '',
    );

    final submitted = <String>[];
    var closedCount = 0;
    WindowsNativeEdit.instance.onSubmit = submitted.add;
    WindowsNativeEdit.instance.onClosed = () => closedCount++;

    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('submit', '弹幕')),
      null,
    );
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec()
          .encodeMethodCall(const MethodCall('closed', null)),
      null,
    );
    await Future<void>.delayed(Duration.zero);

    expect(submitted, ['弹幕']);
    expect(closedCount, 1);
  });
}
