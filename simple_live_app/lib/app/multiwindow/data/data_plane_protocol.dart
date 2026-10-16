/// 多窗口数据面 IPC 协议（desktop_multi_window 单通道自定义方法名）。
///
/// 见 spec：docs/10_ai_workflows/superpowers/specs/
/// 2026-10-16-multiwindow-m4-2-data-plane-ipc-design.md §5。
/// 载荷全部为 JSON 兼容类型（Map/List/num/String/bool/null）。
class DataPlaneProtocol {
  DataPlaneProtocol._();

  // —— 子 → 主 方法名 ——
  static const String mReady = 'dp_ready';
  static const String mKvSet = 'dp_kv_set';
  static const String mKvDelete = 'dp_kv_delete';
  static const String mKvClear = 'dp_kv_clear';
  static const String mVolumeSet = 'dp_volume_set';
  static const String mFollowSet = 'dp_follow_set';
  static const String mFollowRemove = 'dp_follow_remove';
  static const String mHistoryAdd = 'dp_history_add';

  // —— 主 → 子 方法名 ——
  static const String mChanged = 'dp_changed';

  // —— KV box 名 ——
  static const String boxSettings = 'settings';
  static const String boxShield = 'shield';
  static const Set<String> boxes = {boxSettings, boxShield};

  // —— 广播 kind ——
  static const String kindKv = 'kv';
  static const String kindShield = 'shield';
  static const String kindVolume = 'volume';
  static const String kindFollow = 'follow';
  static const Set<String> kinds = {
    kindKv,
    kindShield,
    kindVolume,
    kindFollow
  };

  /// 禁止跨窗传播的键：各平台登录凭据、guard 配置/账号、WebDAV、同步信息。
  ///
  /// 入单准则（M4-1 游客态不变量）：任何被子引擎服务初始化读取后会翻转
  /// 登录/配置标志的键都必须在此——DouyinLoginCookie 使子引擎
  /// DouyinAccountService.onInit 判定 logined=true，GuardServerUrl 使
  /// GuardServerService.configured=true，均会破坏子窗固定游客态。
  /// 账号类数据唯一合法通道是 M4-3 的账号面协议。
  static const Set<String> sensitiveKeys = {
    'BilibiliCookie',
    'DouyinCookie',
    'DouyinLoginCookie',
    'GuardServerUrl',
    'GuardServerToken',
    'DouyuCookie',
    'DouyuLoginAccount',
    'DouyuLoginPassword',
    'HuyaCookie',
    'TwitchClientId',
    'TwitchToken',
    'TwitchUserLogin',
    'WebDAVUri',
    'WebDAVUser',
    'kWebDAVPassword',
    'userName',
    'syncUrl',
  };

  static const String sensitivePrefix = 'GuardAccountId_';

  static bool isSensitiveKey(String key) =>
      sensitiveKeys.contains(key) || key.startsWith(sensitivePrefix);

  /// JSON 载荷只接受基础类型（List/Map/实体拒绝；显式 null 合法）
  static bool isAllowedValue(Object? value) =>
      value == null || value is num || value is String || value is bool;

  // —— 解析 ——

  static String? kvBoxOf(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    return box is String && boxes.contains(box) ? box : null;
  }

  static KvWrite? decodeKvSet(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    final key = arguments['key'];
    if (box is! String || !boxes.contains(box)) return null;
    if (key is! String) return null;
    // 缺 value 键拒绝；显式 null 合法（containsKey 区分二者）
    if (!arguments.containsKey('value')) return null;
    final value = arguments['value'];
    if (!isAllowedValue(value)) return null;
    // shield 只接受非空 String（null 也拒：handler 需原样写回屏蔽词）
    if (box == boxShield && value is! String) return null;
    return KvWrite(box, key, value);
  }

  static KvWrite? decodeKvDelete(Object? arguments) {
    if (arguments is! Map) return null;
    final box = arguments['box'];
    final key = arguments['key'];
    if (box is! String || !boxes.contains(box)) return null;
    if (key is! String) return null;
    return KvWrite(box, key, null);
  }

  static ChangeEvent? decodeChanged(Object? arguments) {
    if (arguments is! Map) return null;
    final kind = arguments['kind'];
    final key = arguments['key'];
    if (kind is! String || !kinds.contains(kind)) return null;
    if (key is! String) return null;
    return ChangeEvent(
      kind: kind,
      key: key,
      value: arguments['value'],
      deleted: arguments['deleted'] == true,
      clear: arguments['clear'] == true,
    );
  }

  // —— 构造 ——

  static Map<String, Object?> kvSet(String box, String key, Object? value) =>
      {'box': box, 'key': key, 'value': value};

  static Map<String, Object?> kvDelete(String box, String key) =>
      {'box': box, 'key': key};

  static Map<String, Object?> kvClear(String box) => {'box': box};

  static Map<String, Object?> volumeSet(String key, double value) =>
      {'key': key, 'value': value};

  static Map<String, Object?> followSet(Map<String, dynamic> followJson) =>
      {'follow': followJson};

  static Map<String, Object?> followRemove(String key) => {'key': key};

  static Map<String, Object?> historyAdd(Map<String, dynamic> historyJson) =>
      {'history': historyJson};

  static Map<String, Object?> changed({
    required String kind,
    required String key,
    Object? value,
    bool deleted = false,
    bool clear = false,
  }) =>
      {
        'kind': kind,
        'key': key,
        if (value != null) 'value': value,
        if (deleted) 'deleted': true,
        if (clear) 'clear': true,
      };
}

/// dp_kv_set / dp_kv_delete 解析结果
class KvWrite {
  const KvWrite(this.box, this.key, this.value);

  final String box;
  final String key;
  final Object? value;
}

/// dp_changed 解析结果
class ChangeEvent {
  const ChangeEvent({
    required this.kind,
    required this.key,
    this.value,
    this.deleted = false,
    this.clear = false,
  });

  final String kind;
  final String key;
  final Object? value;
  final bool deleted;
  final bool clear;
}
