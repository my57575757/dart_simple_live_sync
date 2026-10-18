import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';

void main() {
  group('request_move', () {
    test('往返保留全部字段；shareUrl 允许空串', () {
      const c = WindowMoveCall(
        sourceWindowId: 'w2',
        tabId: 't1',
        siteId: 'douyin',
        roomId: 'r1',
        shareUrl: '',
        target: '__main__',
      );
      final d = WindowControlProtocol.decodeRequestMove(
          WindowControlProtocol.encodeRequestMove(c))!;
      expect(d.sourceWindowId, 'w2');
      expect(d.tabId, 't1');
      expect(d.siteId, 'douyin');
      expect(d.roomId, 'r1');
      expect(d.shareUrl, '');
      expect(d.target, '__main__');
    });

    test('非法载荷：非 Map / 缺字段 / 空串 / 错类型 → null', () {
      expect(WindowControlProtocol.decodeRequestMove(null), isNull);
      expect(WindowControlProtocol.decodeRequestMove('x'), isNull);
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': 'w2',
            'tabId': 't1',
            'siteId': 'douyin',
            'roomId': 'r1',
            // shareUrl 缺失
            'target': '__new__',
          }),
          isNull);
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': '',
            'tabId': 't1',
            'siteId': 'douyin',
            'roomId': 'r1',
            'shareUrl': '',
            'target': '__new__',
          }),
          isNull,
          reason: 'sourceWindowId 不得空串');
      expect(
          WindowControlProtocol.decodeRequestMove({
            'sourceWindowId': 'w2',
            'tabId': 1,
            'siteId': 'douyin',
            'roomId': 'r1',
            'shareUrl': '',
            'target': '__new__',
          }),
          isNull);
    });

    test('target 校验：控制字符/超长 → null；__new__/__main__/窗口 ID 通过', () {
      Map<String, Object?> payload(Object? target) => {
            'sourceWindowId': 'w2',
            'tabId': 't1',
            'siteId': 'douyin',
            'roomId': 'r1',
            'shareUrl': '',
            'target': target,
          };

      expect(WindowControlProtocol.decodeRequestMove(payload('a\nb')), isNull,
          reason: 'target 不得含换行');
      expect(WindowControlProtocol.decodeRequestMove(payload('a\rb')), isNull,
          reason: 'target 不得含回车');
      expect(WindowControlProtocol.decodeRequestMove(payload('a\tb')), isNull,
          reason: 'target 不得含制表符');
      expect(
          WindowControlProtocol.decodeRequestMove(
              payload('w' * 129)),
          isNull,
          reason: 'target 长度上限 128');
      expect(WindowControlProtocol.decodeRequestMove(payload('')), isNull,
          reason: 'target 不得空串');

      for (final t in [
        WindowControlProtocol.targetNew,
        WindowControlProtocol.targetMain,
        'w1',
        'w' * 128,
      ]) {
        final d = WindowControlProtocol.decodeRequestMove(payload(t));
        expect(d, isNotNull, reason: '合法 target 应通过: $t');
        expect(d!.target, t);
      }
    });
  });

  group('open_tab / close_tab', () {
    test('open_tab 往返含 activate', () {
      const c = OpenTabCall(
        tabId: 't9',
        siteId: 'bilibili',
        roomId: '9',
        shareUrl: 'u',
        activate: false,
      );
      final d = WindowControlProtocol.decodeOpenTab(
          WindowControlProtocol.encodeOpenTab(c))!;
      expect(d.tabId, 't9');
      expect(d.siteId, 'bilibili');
      expect(d.activate, isFalse);
    });

    test('open_tab activate 错类型/缺失 → null；close_tab 空 id → null', () {
      expect(
          WindowControlProtocol.decodeOpenTab({
            'tabId': 't',
            'siteId': 'douyin',
            'roomId': 'r',
            'shareUrl': '',
          }),
          isNull);
      expect(WindowControlProtocol.decodeCloseTab({'tabId': ''}), isNull);
      expect(WindowControlProtocol.decodeCloseTab(null), isNull);
    });

    test('close_tab 往返', () {
      final d = WindowControlProtocol.decodeCloseTab(
          WindowControlProtocol.encodeCloseTab(
              const CloseTabCall(tabId: 'x')))!;
      expect(d.tabId, 'x');
    });
  });

  group('window list / move result', () {
    test('列表往返保序', () {
      const list = [
        WindowListEntry(id: '__main__', label: '主窗口'),
        WindowListEntry(id: 'w1', label: '直播间窗口 1'),
      ];
      final d = WindowControlProtocol.decodeWindowList(
          WindowControlProtocol.encodeWindowList(list))!;
      expect(d.map((e) => e.id), ['__main__', 'w1']);
      expect(d.map((e) => e.label), ['主窗口', '直播间窗口 1']);
    });

    test('列表非 List / 元素缺字段 → null', () {
      expect(WindowControlProtocol.decodeWindowList('x'), isNull);
      expect(
          WindowControlProtocol.decodeWindowList([
            {'id': 'w1'}
          ]),
          isNull);
    });

    test('move result 往返；失败缺省 message 允许', () {
      final ok = WindowControlProtocol.decodeMoveResult(
          WindowControlProtocol.encodeMoveResult(true))!;
      expect(ok.ok, isTrue);
      expect(ok.message, isNull);
      final fail = WindowControlProtocol.decodeMoveResult(
          WindowControlProtocol.encodeMoveResult(false,
              message: '目标窗口无响应'))!;
      expect(fail.ok, isFalse);
      expect(fail.message, '目标窗口无响应');
      expect(WindowControlProtocol.decodeMoveResult({'ok': 'x'}), isNull);
    });
  });
}
