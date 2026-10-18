import 'dart:convert';

/// 单个待打开的房间（跨窗重建用）
class RoomTabArg {
  const RoomTabArg({
    required this.siteId,
    required this.roomId,
    this.shareUrl = '',
    this.tabId,
  });

  final String siteId;
  final String roomId;
  final String shareUrl;

  /// 跨窗迁移预定的标签 id；null=新开窗由 TabStore 生成 uuid
  final String? tabId;

  Map<String, dynamic> toJson() => {
        'siteId': siteId,
        'roomId': roomId,
        'shareUrl': shareUrl,
        if (tabId != null) 'tabId': tabId,
      };

  factory RoomTabArg.fromJson(Map<String, dynamic> json) => RoomTabArg(
        siteId: json['siteId'] as String,
        roomId: json['roomId'] as String,
        shareUrl: (json['shareUrl'] as String?) ?? '',
        tabId: json['tabId'] as String?,
      );
}

/// 主引擎 → 子引擎的只读数据快照（M4-1：设置/屏蔽词/音量/关注存在性）
class WindowSnapshot {
  const WindowSnapshot({
    this.settings = const {},
    this.shield = const [],
    this.volumes = const {},
    this.followShareUrls = const {},
    this.followUserNames = const {},
  });

  final Map<String, dynamic> settings;
  final List<String> shield;
  final Map<String, double> volumes;

  /// key=siteId_roomId，value=shareUrl（可能为空串，仅用于关注存在性判断）
  final Map<String, String> followShareUrls;

  /// key=siteId_roomId，value=关注时保存的主播名（标签标题用）
  final Map<String, String> followUserNames;

  Map<String, dynamic> toJson() => {
        'settings': settings,
        'shield': shield,
        'volumes': volumes,
        'followShareUrls': followShareUrls,
        'followUserNames': followUserNames,
      };

  factory WindowSnapshot.fromJson(Map<String, dynamic> json) => WindowSnapshot(
        settings:
            Map<String, dynamic>.from(json['settings'] as Map? ?? const {}),
        shield: ((json['shield'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        volumes: ((json['volumes'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), (v as num).toDouble())),
        followShareUrls: ((json['followShareUrls'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
        followUserNames: ((json['followUserNames'] as Map?) ?? const {})
            .map((k, v) => MapEntry(k.toString(), v.toString())),
      );
}

/// 子窗启动参数（dmw WindowConfiguration.arguments 承载的 JSON 字符串）
class RoomWindowArgs {
  const RoomWindowArgs({
    required this.tabs,
    this.snapshot = const WindowSnapshot(),
    this.mainWindowId = '',
  });

  static const String type = 'room_shell';

  final List<RoomTabArg> tabs;
  final WindowSnapshot snapshot;

  /// 创建该窗的主引擎 windowId（dmw String id）；子窗数据面 IPC 据此回连。
  /// M4-2 前的旧参数无此字段，缺省空串表示不启用写穿（纯快照模式）。
  final String mainWindowId;

  Map<String, dynamic> toJson() => {
        'type': type,
        'tabs': tabs.map((e) => e.toJson()).toList(),
        'snapshot': snapshot.toJson(),
        'mainWindowId': mainWindowId,
      };

  String encode() => jsonEncode(toJson());

  factory RoomWindowArgs.fromJson(Map<String, dynamic> json) {
    if (json['type'] != type) {
      throw FormatException('unknown window args type: ${json['type']}');
    }
    final snapshotJson =
        (json['snapshot'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RoomWindowArgs(
      tabs: ((json['tabs'] as List?) ?? const [])
          .map((e) => RoomTabArg.fromJson(e as Map<String, dynamic>))
          .toList(),
      snapshot: WindowSnapshot.fromJson(snapshotJson),
      mainWindowId: (json['mainWindowId'] as String?) ?? '',
    );
  }

  factory RoomWindowArgs.decode(String raw) =>
      RoomWindowArgs.fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
