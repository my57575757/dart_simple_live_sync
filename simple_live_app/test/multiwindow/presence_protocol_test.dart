import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';

void main() {
  test('子→主：register/claim/release/batch/guardSend encode/decode 往返', () {
    final register = PresenceProtocol.encodeRegister(
      const PresenceRegisterCall(
        windowId: 'w1',
        tabId: 't1',
        siteId: 'douyin',
        roomId: '711',
        shareUrl: '',
      ),
    );
    final dRegister = PresenceProtocol.decodeRegister(register)!;
    expect(dRegister.windowId, 'w1');
    expect(dRegister.tabId, 't1');
    expect(dRegister.siteId, 'douyin');
    expect(dRegister.roomId, '711');
    expect(dRegister.shareUrl, '');
    expect(PresenceProtocol.encodeRegister(dRegister), register);

    final claim = PresenceProtocol.encodeClaim(
      const PresenceClaimCall(
        windowId: 'w1',
        tabId: 't1',
        roomId: '711',
        shareUrl: 'http://x/711',
        guardRoomId: '', // 空串合法（#6 SSR 骨架房）
        guardWebRid: 'g711',
        guardExtra: <String, Object?>{},
      ),
    );
    final dClaim = PresenceProtocol.decodeClaim(claim)!;
    expect(dClaim.guardRoomId, '');
    expect(dClaim.guardWebRid, 'g711');
    expect(dClaim.guardExtra, isEmpty);
    expect(PresenceProtocol.encodeClaim(dClaim), claim);

    // 空 guardWebRid 同样是合法值（仅 String 类型必填）
    final claimEmptyWebRid = PresenceProtocol.encodeClaim(
      const PresenceClaimCall(
        windowId: 'w1',
        tabId: 't1',
        roomId: '711',
        shareUrl: '',
        guardRoomId: 'r711',
        guardWebRid: '',
        guardExtra: <String, Object?>{},
      ),
    );
    final dClaimEmptyWebRid =
        PresenceProtocol.decodeClaim(claimEmptyWebRid)!;
    expect(dClaimEmptyWebRid.guardWebRid, '');
    expect(
      PresenceProtocol.encodeClaim(dClaimEmptyWebRid),
      claimEmptyWebRid,
    );

    final release = PresenceProtocol.encodeRelease(
      const PresenceReleaseCall(windowId: 'w1', tabId: 't1'),
    );
    final dRelease = PresenceProtocol.decodeRelease(release)!;
    expect(dRelease.windowId, 'w1');
    expect(dRelease.tabId, 't1');
    expect(PresenceProtocol.encodeRelease(dRelease), release);

    final batch = PresenceProtocol.encodeBatchRelease(
      const PresenceBatchReleaseCall(windowId: 'w1', tabIds: ['t1', 't2']),
    );
    final dBatch = PresenceProtocol.decodeBatchRelease(batch)!;
    expect(dBatch.tabIds, ['t1', 't2']);
    expect(PresenceProtocol.encodeBatchRelease(dBatch), batch);

    final danmaku = PresenceProtocol.encodeGuardSend(
      const PresenceGuardSendCall(
        windowId: 'w1',
        tabId: 't1',
        kind: PresenceProtocol.kDanmaku,
        content: '你好',
      ),
    );
    final dDanmaku = PresenceProtocol.decodeGuardSend(danmaku)!;
    expect(dDanmaku.kind, PresenceProtocol.kDanmaku);
    expect(dDanmaku.content, '你好');
    expect(dDanmaku.action, isNull);

    final action = PresenceProtocol.encodeGuardSend(
      const PresenceGuardSendCall(
        windowId: 'w1',
        tabId: 't1',
        kind: PresenceProtocol.kAction,
        action: 'like',
      ),
    );
    final dAction = PresenceProtocol.decodeGuardSend(action)!;
    expect(dAction.action, 'like');
    expect(dAction.content, isNull);
  });

  test('主→子 apply 与 claim/send 响应编解码、reason 四值映射', () {
    final enter = PresenceProtocol.encodeApplyEnter(
      const PresenceApplyEnterCall(
        tabId: 't1',
        cookie: 'sessionid=abc',
        status: <String, Object?>{'inRoom': true},
        reentered: true,
      ),
    );
    final dEnter = PresenceProtocol.decodeApplyEnter(enter)!;
    expect(dEnter.cookie, 'sessionid=abc');
    expect(dEnter.status, {'inRoom': true});
    expect(dEnter.reentered, isTrue);
    expect(PresenceProtocol.encodeApplyEnter(dEnter), enter);

    // 空 cookie 是合法值（必须是 String，空串不拦）
    final emptyCookie = PresenceProtocol.encodeApplyEnter(
      const PresenceApplyEnterCall(
        tabId: 't2',
        cookie: '',
        status: <String, Object?>{},
        reentered: false,
      ),
    );
    final dEmptyCookie = PresenceProtocol.decodeApplyEnter(emptyCookie)!;
    expect(dEmptyCookie.cookie, '');
    expect(PresenceProtocol.encodeApplyEnter(dEmptyCookie), emptyCookie);

    // ipcFailed 是子端本地结果，禁止编码上线
    expect(
      () => PresenceProtocol.encodeClaimFailure(
        PresenceFailureReason.ipcFailed,
      ),
      throwsArgumentError,
    );

    expect(
      PresenceProtocol.decodeTabApply(PresenceProtocol.encodeTabApply('t9')),
      't9',
    );

    expect(
      PresenceProtocol.decodeClaimResult(PresenceProtocol.encodeClaimOk()),
      (ok: true, reason: null),
    );
    for (final reason in PresenceFailureReason.values
        .where((r) => r != PresenceFailureReason.ipcFailed)) {
      final decoded = PresenceProtocol.decodeClaimResult(
        PresenceProtocol.encodeClaimFailure(reason),
      )!;
      expect(decoded.ok, isFalse);
      expect(decoded.reason, reason);
      expect(
        PresenceProtocol.reasonFromWire(PresenceProtocol.reasonToWire(reason)),
        reason,
      );
    }
    expect(PresenceProtocol.reasonToWire(PresenceFailureReason.ipcFailed),
        isNull);
    expect(PresenceProtocol.reasonFromWire('bogus'), isNull);

    final notHolder = PresenceProtocol.decodeSendResult(
      PresenceProtocol.encodeSendResult(PresenceSendResult.notHolder),
    )!;
    expect(notHolder.success, isFalse);
    expect(notHolder.code, 'not_holder');
    expect(notHolder.message, isNull);

    final sent = PresenceProtocol.decodeSendResult(
      PresenceProtocol.encodeSendResult(
        const PresenceSendResult(success: true, message: '已发送'),
      ),
    )!;
    expect(sent.success, isTrue);
    expect(sent.code, isNull);
    expect(sent.message, '已发送');
  });

  test('坏载荷：全部 decode 为 null（不入仲裁栈、不发 HTTP）', () {
    expect(PresenceProtocol.decodeRegister(null), isNull);
    expect(PresenceProtocol.decodeRegister('x'), isNull);
    expect(
      PresenceProtocol.decodeRegister(<String, Object?>{'windowId': 'w1'}),
      isNull,
    );
    expect(
      PresenceProtocol.decodeRegister(const {
        'windowId': '',
        'tabId': 't',
        'siteId': 'douyin',
        'roomId': '1',
        'shareUrl': '',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeRegister(const {
        'windowId': 'w',
        'tabId': 't',
        'siteId': 'douyin',
        'roomId': '1',
        'shareUrl': 2,
      }),
      isNull,
    );

    final goodClaim = Map<String, Object?>.from(
      PresenceProtocol.encodeClaim(
        const PresenceClaimCall(
          windowId: 'w',
          tabId: 't',
          roomId: '1',
          shareUrl: '',
          guardRoomId: 'r',
          guardWebRid: 'g',
          guardExtra: <String, Object?>{},
        ),
      ),
    );
    final badExtra = Map<String, Object?>.from(goodClaim)
      ..['guardExtra'] = 'no';
    final badRoomIdType = Map<String, Object?>.from(goodClaim)
      ..['guardRoomId'] = 1;
    final missingWebRid = Map<String, Object?>.from(goodClaim)
      ..remove('guardWebRid');
    expect(PresenceProtocol.decodeClaim(badExtra), isNull);
    expect(PresenceProtocol.decodeClaim(badRoomIdType), isNull);
    expect(PresenceProtocol.decodeClaim(missingWebRid), isNull);

    // guardExtra 非字符串键：decode 必须返回 null，不许抛 _TypeError
    final nonStringExtraKey = Map<String, Object?>.from(goodClaim)
      ..['guardExtra'] = <Object, Object?>{1: 'x'};
    expect(PresenceProtocol.decodeClaim(nonStringExtraKey), isNull);

    expect(PresenceProtocol.decodeClaim(null), isNull);
    expect(PresenceProtocol.decodeClaim('x'), isNull);

    expect(PresenceProtocol.decodeRelease(null), isNull);
    expect(
      PresenceProtocol.decodeRelease({'windowId': 'w'}),
      isNull,
    );
    expect(
      PresenceProtocol.decodeBatchRelease({
        'windowId': 'w',
        'tabIds': 'x',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeBatchRelease({
        'windowId': 'w',
        'tabIds': ['t', 1],
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeBatchRelease({
        'windowId': 'w',
        'tabIds': ['t', ''],
      }),
      isNull,
    );

    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'poke',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'danmaku',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'danmaku',
        'content': '',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'action',
        'action': '',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'danmaku',
        'content': 1,
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeGuardSend({
        'windowId': 'w',
        'tabId': 't',
        'kind': 'action',
      }),
      isNull,
    );

    expect(
      PresenceProtocol.decodeApplyEnter({
        'tabId': 't',
        'cookie': 'c',
        'status': <String, Object?>{},
        'reentered': 'yes',
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeApplyEnter({
        'tabId': 't',
        'cookie': 1,
        'status': <String, Object?>{},
        'reentered': false,
      }),
      isNull,
    );
    expect(
      PresenceProtocol.decodeApplyEnter({
        'tabId': 't',
        'cookie': 'c',
        // status 非字符串键：decode 必须返回 null，不许抛 _TypeError
        'status': <Object, Object?>{1: 'x'},
        'reentered': false,
      }),
      isNull,
    );

    expect(PresenceProtocol.decodeApplyEnter(null), isNull);
    expect(PresenceProtocol.decodeApplyEnter('x'), isNull);

    expect(PresenceProtocol.decodeTabApply('x'), isNull);
    expect(PresenceProtocol.decodeTabApply({'tabId': ''}), isNull);

    expect(PresenceProtocol.decodeClaimResult(null), isNull);
    expect(PresenceProtocol.decodeClaimResult({'ok': 'x'}), isNull);
    expect(
      PresenceProtocol.decodeClaimResult({'ok': false, 'reason': 'nope'}),
      isNull,
    );
    expect(PresenceProtocol.decodeClaimResult({'ok': false}), isNull);

    expect(PresenceProtocol.decodeSendResult(null), isNull);
    expect(PresenceProtocol.decodeSendResult({'success': 'x'}), isNull);
    expect(
      PresenceProtocol.decodeSendResult({'success': true, 'code': 1}),
      isNull,
    );
  });

  test('sanitizeForLog：cookie 脱敏，输出不含原文，非敏感字段正常序列化', () {
    const cookie = 'sessionid=secretvalue';
    final enter = PresenceProtocol.encodeApplyEnter(
      const PresenceApplyEnterCall(
        tabId: 't1',
        cookie: cookie,
        status: <String, Object?>{
          'inRoom': true,
          'nested': <String, Object?>{'cookie': 'x'},
        },
        reentered: false,
      ),
    );
    final log =
        PresenceProtocol.sanitizeForLog(PresenceProtocol.mApplyEnter, enter);
    expect(log, contains('pr_apply_enter'));
    expect(log, contains('<cookie:${cookie.length}chars>'));
    expect(log.contains('sessionid'), isFalse);
    expect(log.contains('secretvalue'), isFalse);
    expect(log, contains('<cookie:1chars>'), reason: '嵌套 map 内 cookie 同样脱敏');
    expect(log, contains('"tabId":"t1"'), reason: '非敏感字段正常序列化');

    final listLog = PresenceProtocol.sanitizeForLog('x', const [
      <String, Object?>{'cookie': 'sessionid=abc'},
    ]);
    expect(listLog.contains('sessionid'), isFalse);
    expect(listLog, contains('<cookie:'));

    // cookie 值非 String：替换为 <cookie:0chars>，序列化不抛
    final numCookieLog = PresenceProtocol.sanitizeForLog(
      'x',
      const <String, Object?>{'cookie': 1, 'tabId': 't1'},
    );
    expect(numCookieLog, contains('<cookie:0chars>'));
    expect(numCookieLog, contains('"tabId":"t1"'));

    expect(
      PresenceProtocol.sanitizeForLog('x', Object()),
      contains('unserializable'),
    );

    final claim = PresenceProtocol.encodeClaim(
      const PresenceClaimCall(
        windowId: 'w',
        tabId: 't',
        roomId: '1',
        shareUrl: '',
        guardRoomId: 'r',
        guardWebRid: 'g',
        guardExtra: <String, Object?>{},
      ),
    );
    final claimLog =
        PresenceProtocol.sanitizeForLog(PresenceProtocol.mClaim, claim);
    expect(claimLog, contains('"tabId":"t"'));
    expect(claimLog.contains('cookie'), isFalse, reason: 'claim 载荷无 cookie');
  });
}
