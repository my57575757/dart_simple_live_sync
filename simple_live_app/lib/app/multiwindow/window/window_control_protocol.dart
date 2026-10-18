/// 窗口管理面 IPC 协议（mw_ 前缀）：标签跨窗迁移与窗口枚举。
/// 形态对齐 PresenceProtocol：私有构造、常量方法名/线值、显式 encode/decode、
/// 非法载荷返回 null。载荷全部 JSON 兼容；本协议不含任何凭据字段。
class WindowControlProtocol {
  WindowControlProtocol._();

  // ---- 方法名：子 → 主 ----
  static const String mRequestMove = 'mw_request_move';
  static const String mListWindows = 'mw_list_windows';

  // ---- 方法名：主 → 子 ----
  static const String mOpenTab = 'mw_open_tab';
  static const String mCloseTab = 'mw_close_tab';

  // ---- target 线值 ----
  static const String targetNew = '__new__';
  static const String targetMain = '__main__';

  static String? _nonEmptyStr(Map<dynamic, dynamic> m, String key) {
    final v = m[key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// target 线值上限：窗口 ID / 特殊哨兵均远短于此。
  static const int _maxTargetLen = 128;

  /// target 校验：非空、无控制字符（`\n`/`\r`/`\t`）、长度 ≤ 128。
  /// 控制字符可注入路由键/日志换行，一律拒绝。
  static bool _isValidTarget(String t) {
    if (t.length > _maxTargetLen) return false;
    return !t.contains('\n') && !t.contains('\r') && !t.contains('\t');
  }

  // ---- request_move ----

  static Map<String, Object?> encodeRequestMove(WindowMoveCall call) => {
        'sourceWindowId': call.sourceWindowId,
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'target': call.target,
      };

  static WindowMoveCall? decodeRequestMove(Object? args) {
    if (args is! Map) return null;
    final sourceWindowId = _nonEmptyStr(args, 'sourceWindowId');
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final rawTarget = _nonEmptyStr(args, 'target');
    final target = rawTarget != null && _isValidTarget(rawTarget) ? rawTarget : null;
    final shareUrl = args['shareUrl'];
    if (sourceWindowId == null ||
        tabId == null ||
        siteId == null ||
        roomId == null ||
        target == null ||
        shareUrl is! String) {
      return null;
    }
    return WindowMoveCall(
      sourceWindowId: sourceWindowId,
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
      target: target,
    );
  }

  // ---- open_tab ----

  static Map<String, Object?> encodeOpenTab(OpenTabCall call) => {
        'tabId': call.tabId,
        'siteId': call.siteId,
        'roomId': call.roomId,
        'shareUrl': call.shareUrl,
        'activate': call.activate,
      };

  static OpenTabCall? decodeOpenTab(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    final siteId = _nonEmptyStr(args, 'siteId');
    final roomId = _nonEmptyStr(args, 'roomId');
    final shareUrl = args['shareUrl'];
    final activate = args['activate'];
    if (tabId == null ||
        siteId == null ||
        roomId == null ||
        shareUrl is! String ||
        activate is! bool) {
      return null;
    }
    return OpenTabCall(
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
      activate: activate,
    );
  }

  // ---- close_tab ----

  static Map<String, Object?> encodeCloseTab(CloseTabCall call) =>
      {'tabId': call.tabId};

  static CloseTabCall? decodeCloseTab(Object? args) {
    if (args is! Map) return null;
    final tabId = _nonEmptyStr(args, 'tabId');
    if (tabId == null) return null;
    return CloseTabCall(tabId: tabId);
  }

  // ---- window list ----

  static List<Object?> encodeWindowList(List<WindowListEntry> entries) => [
        for (final e in entries)
          {'id': e.id, 'label': e.label},
      ];

  static List<WindowListEntry>? decodeWindowList(Object? args) {
    if (args is! List) return null;
    final out = <WindowListEntry>[];
    for (final raw in args) {
      if (raw is! Map) return null;
      final id = _nonEmptyStr(raw, 'id');
      final label = _nonEmptyStr(raw, 'label');
      if (id == null || label == null) return null;
      out.add(WindowListEntry(id: id, label: label));
    }
    return out;
  }

  // ---- move result ----

  static Map<String, Object?> encodeMoveResult(bool ok, {String? message}) => {
        'ok': ok,
        if (message != null) 'message': message,
      };

  static MoveResult? decodeMoveResult(Object? args) {
    if (args is! Map || args['ok'] is! bool) return null;
    final message = args['message'];
    if (message != null && message is! String) return null;
    return MoveResult(args['ok'] as bool, message as String?);
  }
}

class WindowMoveCall {
  const WindowMoveCall({
    required this.sourceWindowId,
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
    required this.target,
  });

  final String sourceWindowId;
  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
  final String target;
}

class OpenTabCall {
  const OpenTabCall({
    required this.tabId,
    required this.siteId,
    required this.roomId,
    required this.shareUrl,
    required this.activate,
  });

  final String tabId;
  final String siteId;
  final String roomId;
  final String shareUrl;
  final bool activate;
}

class CloseTabCall {
  const CloseTabCall({required this.tabId});

  final String tabId;
}

class WindowListEntry {
  const WindowListEntry({required this.id, required this.label});

  final String id;
  final String label;
}

/// 迁移回执：message 仅允许固定中文文案，禁止回显异常对象。
class MoveResult {
  const MoveResult(this.ok, this.message);

  factory MoveResult.success() => const MoveResult(true, null);
  factory MoveResult.failure(String message) => MoveResult(false, message);

  final bool ok;
  final String? message;
}
