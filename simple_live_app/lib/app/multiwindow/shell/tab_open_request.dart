class TabOpenRequest {
  TabOpenRequest({
    required this.siteId,
    required this.roomId,
    this.shareUrl = "",
  });

  final String siteId;
  final String roomId;
  final String shareUrl;

  /// 跨标签去重键：同一直播间不同 shareUrl 视为同一房间
  String get key => "${siteId}_$roomId";
}
