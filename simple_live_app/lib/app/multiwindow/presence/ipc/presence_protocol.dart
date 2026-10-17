import 'dart:convert';

import '../presence_client.dart';

/// 账号面 presence IPC 协议（pr_ 前缀）。形态对齐 DataPlaneProtocol：
/// 私有构造、常量方法名、显式 encode/decode、非法载荷返回 null。
///
/// 载荷全部 JSON 兼容（Map/List/num/String/bool/null）。dp_ 流量经
/// MainDataPlaneService，pr_ 流量经 MainPresenceService，两服务互不解析
/// 对方方法，唯一交点是主窗 handler 默认分支的一行委托。
class PresenceProtocol {
  PresenceProtocol._();

  // ---- 方法名：子 → 主 ----
  static const String mRegister = 'pr_register';
  static const String mClaim = 'pr_claim';
  static const String mRelease = 'pr_release';
  static const String mDetach = 'pr_detach';
  static const String mBatchRelease = 'pr_batch_release';
  static const String mGuardSend = 'pr_guard_send';

  // ---- 方法名：主 → 子 ----
  static const String mApplyEnter = 'pr_apply_enter';
  static const String mApplyYield = 'pr_apply_yield';
  static const String mApplySuspended = 'pr_apply_suspended';

  // ---- pr_guard_send 的 kind ----
  static const String kDanmaku = 'danmaku';
  static const String kAction = 'action';

  // ---- claim failure reason 线值 ----
  static const String rNotLoggedIn = 'not_logged_in';
  static const String rNotConfigured = 'not_configured';
  static const String rDetailFailed = 'detail_failed';
  static const String rEnterFailed = 'enter_failed';

  static const Map<PresenceFailureReason, String> _reasonToWire = {
    PresenceFailureReason.notLoggedIn: rNotLoggedIn,
    PresenceFailureReason.notConfigured: rNotConfigured,
    PresenceFailureReason.detailFailed: rDetailFailed,
    PresenceFailureReason.enterFailed: rEnterFailed,
  };

  static String? reasonToWire(PresenceFailureReason reason) =>
      _reasonToWire[reason]; // ipcFailed 是子端本地结果，无线上值

  static PresenceFailureReason? reasonFromWire(String? wire) {
    for (final entry in _reasonToWire.entries) {
      if (entry.value == wire) return entry.key;
    }
    return null;
  }

  static String? _nonEmptyStr(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  // ---- register ----

  static Map<String, Object?> encodeRegister(PresenceRegisterCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
      };

  static PresenceRegisterCall? decodeRegister(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    if (windowId == null ||
        tabId == null ||
        siteId == null ||
        roomId == null ||
        shareUrl is! String) {
      return null;
    }
    return PresenceRegisterCall(
      windowId: windowId,
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
    );
  }

  // ---- claim ----

  static Map<String, Object?> encodeClaim(PresenceClaimCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'guardRoomId': call.guardRoomId,
        'guardWebRid': call.guardWebRid,
        'guardExtra': call.guardExtra,
      };

  static PresenceClaimCall? decodeClaim(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    // 空串合法（#6 骨架房），但缺失/错类型非法
    final guardRoomId = args['guardRoomId'];
    final guardWebRid = args['guardWebRid'];
    final guardExtra = args['guardExtra'];
    if (windowId == null ||
        tabId == null ||
        roomId == null ||
        shareUrl is! String ||
        guardRoomId is! String ||
        guardWebRid is! String ||
        guardExtra is! Map ||
        !guardExtra.keys.every((k) => k is String)) {
      return null;
    }
    return PresenceClaimCall(
      windowId: windowId,
      tabId: tabId,
      roomId: roomId,
      shareUrl: shareUrl,
      guardRoomId: guardRoomId,
      guardWebRid: guardWebRid,
      guardExtra: Map<String, Object?>.from(guardExtra),
    );
  }

  // ---- release / detach（同载荷）----

  static Map<String, Object?> encodeRelease(PresenceReleaseCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
      };

  static PresenceReleaseCall? decodeRelease(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    if (windowId == null || tabId == null) return null;
    return PresenceReleaseCall(windowId: windowId, tabId: tabId);
  }

  // ---- batch release ----

  static Map<String, Object?> encodeBatchRelease(
          PresenceBatchReleaseCall call) =>
      {
        'windowId': call.windowId,
        'tabIds': call.tabIds,
      };

  static PresenceBatchReleaseCall? decodeBatchRelease(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabIds = args['tabIds'];
    if (windowId == null || tabIds is! List) return null;
    for (final id in tabIds) {
      if (id is! String || id.isEmpty) return null;
    }
    return PresenceBatchReleaseCall(
      windowId: windowId,
      tabIds: List<String>.from(tabIds),
    );
  }

  // ---- guard send ----

  static Map<String, Object?> encodeGuardSend(PresenceGuardSendCall call) => {
        'windowId': call.windowId,
        'tabId': call.tabId,
        'kind': call.kind,
        if (call.content != null) 'content': call.content,
        if (call.action != null) 'action': call.action,
        // 房间标识仅公开参数（siteId/roomId/webRid/extra），非空时携带；
        // 缺省/空 = 抖音走网关。严禁在此放入任何凭据字段。
        if (call.siteId != null && call.siteId!.isNotEmpty)
          'siteId': call.siteId,
        if (call.roomId != null && call.roomId!.isNotEmpty)
          'roomId': call.roomId,
        if (call.webRid != null && call.webRid!.isNotEmpty)
          'webRid': call.webRid,
        if (call.extra != null && call.extra!.isNotEmpty) 'extra': call.extra,
      };

  static PresenceGuardSendCall? decodeGuardSend(Object? args) {
    if (args is! Map) return null;
    final windowId = _nonEmptyStr(args, 'windowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final kind = args['kind'];
    if (windowId == null ||
        tabId == null ||
        (kind != kDanmaku && kind != kAction)) {
      return null;
    }
    // 新增房间参数全部可选；extra 存在时须是 Map（键 String）
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final webRid = _nonEmptyStr(args, 'webRid');
    final extraRaw = args['extra'];
    if (extraRaw != null &&
        (extraRaw is! Map || !extraRaw.keys.every((k) => k is String))) {
      return null;
    }
    final extra =
        extraRaw is Map ? Map<String, Object?>.from(extraRaw) : null;

    if (kind == kDanmaku) {
      final content = args['content'];
      if (content is! String || content.isEmpty) return null;
      return PresenceGuardSendCall(
        windowId: windowId,
        tabId: tabId,
        kind: kDanmaku,
        content: content,
        siteId: siteId,
        roomId: roomId,
        webRid: webRid,
        extra: extra,
      );
    }
    final action = args['action'];
    if (action is! String || action.isEmpty) return null;
    return PresenceGuardSendCall(
      windowId: windowId,
      tabId: tabId,
      kind: kAction,
      action: action,
      siteId: siteId,
      roomId: roomId,
      webRid: webRid,
      extra: extra,
    );
  }

  // ---- 主 → 子 apply ----

  static Map<String, Object?> encodeApplyEnter(PresenceApplyEnterCall call) => {
        'tabId': call.tabId,
        'cookie': call.cookie,
        // creds 仅在非空时携带（twitch OAuth 三元组）；cookie 恒带（可为 ''）
        if (call.creds != null && call.creds!.isNotEmpty) 'creds': call.creds,
        'status': call.status,
        'reentered': call.reentered,
      };

  static PresenceApplyEnterCall? decodeApplyEnter(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    final cookie = args['cookie'];
    final status = args['status'];
    final reentered = args['reentered'];
    final creds = args['creds'];
    if (tabId == null || cookie is! String || reentered is! bool) {
      return null;
    }
    // status 允许缺失/空 Map（非抖音凭据下发语义）；缺失默认 {}
    if (status != null &&
        (status is! Map || !status.keys.every((k) => k is String))) {
      return null;
    }
    // creds 可缺失；存在时必须是 String→String Map
    if (creds != null) {
      if (creds is! Map ||
          !creds.keys.every((k) => k is String) ||
          !creds.values.every((v) => v is String)) {
        return null;
      }
    }
    return PresenceApplyEnterCall(
      tabId: tabId,
      cookie: cookie,
      creds: creds is Map
          ? Map<String, String>.from(creds)
          : null,
      status: status is Map
          ? Map<String, Object?>.from(status)
          : const <String, Object?>{},
      reentered: reentered,
    );
  }

  static Map<String, Object?> encodeTabApply(String tabId) => {'tabId': tabId};

  static String? decodeTabApply(Object? args) {
    if (args is! Map) return null;
    return _nonEmptyStr(args, 'tabId');
  }

  // ---- 响应 ----

  static Map<String, Object?> encodeClaimOk() => {'ok': true};

  static Map<String, Object?> encodeClaimFailure(
      PresenceFailureReason reason) {
    final wire = reasonToWire(reason);
    if (wire == null) {
      // ipcFailed 是 invoke 抛错时子端本地构造的结果，永不来自主端
      throw ArgumentError('不可上线的 claim reason: $reason');
    }
    return {'ok': false, 'reason': wire};
  }

  static ({bool ok, PresenceFailureReason? reason})? decodeClaimResult(
      Object? raw) {
    if (raw is! Map || raw['ok'] is! bool) return null;
    final ok = raw['ok'] as bool;
    if (ok) return (ok: true, reason: null);
    final wireReason = raw['reason'];
    final reason =
        wireReason is String ? reasonFromWire(wireReason) : null;
    if (reason == null) return null;
    return (ok: false, reason: reason);
  }

  static Map<String, Object?> encodeSendResult(PresenceSendResult result) => {
        'success': result.success,
        if (result.code != null) 'code': result.code,
        if (result.message != null) 'message': result.message,
      };

  static PresenceSendResult? decodeSendResult(Object? raw) {
    if (raw is! Map || raw['success'] is! bool) return null;
    final code = raw['code'];
    final message = raw['message'];
    if ((code != null && code is! String) ||
        (message != null && message is! String)) {
      return null;
    }
    return PresenceSendResult(
      success: raw['success'] as bool,
      code: code as String?,
      message: message as String?,
    );
  }

  /// 日志安全序列化：任何层级的 cookie 键替换为 <cookie:Nchars>，
  /// creds 键整体替换为 <creds:Nkeys>（绝不打值）；调用方必须经此函数
  /// 打印 pr_ 载荷，严禁直接打印原始 args。
  static String sanitizeForLog(String method, Object? args) {
    Object? scrub(Object? value) {
      if (value is Map) {
        return <String, Object?>{
          for (final entry in value.entries)
            entry.key.toString(): entry.key == 'cookie'
                ? '<cookie:${entry.value is String ? (entry.value as String).length : 0}chars>'
                : entry.key == 'creds'
                    ? '<creds:${entry.value is Map ? (entry.value as Map).length : 0}keys>'
                    : scrub(entry.value),
        };
      }
      if (value is List) return value.map(scrub).toList();
      return value;
    }

    try {
      return '$method ${jsonEncode(scrub(args))}';
    } catch (_) {
      return '$method <unserializable>';
    }
  }
}

class PresenceRegisterCall {
  const PresenceRegisterCall({
    required this.windowId,
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
  });

  final String windowId;
  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
}

class PresenceClaimCall {
  const PresenceClaimCall({
    required this.windowId,
    required this.tabId,
    required this.roomId,
    required this.shareUrl,
    required this.guardRoomId,
    required this.guardWebRid,
    required this.guardExtra,
  });

  final String windowId;
  final String tabId;
  final String roomId;
  final String shareUrl;
  final String guardRoomId;
  final String guardWebRid;
  final Map<String, Object?> guardExtra;
}

class PresenceReleaseCall {
  const PresenceReleaseCall({required this.windowId, required this.tabId});

  final String windowId;
  final String tabId;
}

class PresenceBatchReleaseCall {
  const PresenceBatchReleaseCall({
    required this.windowId,
    required this.tabIds,
  });

  final String windowId;
  final List<String> tabIds;
}

class PresenceGuardSendCall {
  const PresenceGuardSendCall({
    required this.windowId,
    required this.tabId,
    required this.kind,
    this.content,
    this.action,
    this.siteId,
    this.roomId,
    this.webRid,
    this.extra,
  });

  final String windowId;
  final String tabId;
  final String kind;
  final String? content;
  final String? action;

  /// 非抖音写动作的站点标识（bilibili/douyu/huya/twitch）；
  /// 缺省/空 = 抖音走网关。公开房间参数，非凭据。
  final String? siteId;
  final String? roomId;
  final String? webRid;

  /// 仅 JSON 兼容公开房间参数，严禁放 cookie/token 等凭据
  final Map<String, Object?>? extra;
}

class PresenceApplyEnterCall {
  const PresenceApplyEnterCall({
    required this.tabId,
    required this.cookie,
    required this.status,
    required this.reentered,
    this.creds,
  });

  final String tabId;

  /// 单串凭据：抖音/斗鱼/虎牙/B站（可为 ''）。twitch 恒 ''，走 [creds]。
  final String cookie;

  /// 多键凭据：twitch {oauthToken,userLogin,clientId}；其余站点 null。
  /// 与 cookie 同级同等敏感，仅在 pr_apply_enter 单向下发。
  final Map<String, String>? creds;
  final Map<String, Object?> status;
  final bool reentered;
}
