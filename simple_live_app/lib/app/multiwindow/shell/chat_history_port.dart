/// 标签跨窗迁移时弹幕聊天历史的导入/导出端口。
///
/// 由 LiveRoomController 实现；TabStore 经此窄接口访问控制器，使壳层与编排
/// 测试无需构造重量级 LiveRoomController。载荷为 mw_ 线格式（见
/// ChatHistoryCodec）：纯 JSON 兼容的聊天展示四元组，不含任何凭据。
abstract class ChatHistoryPort {
  /// 导出当前聊天列表为线格式（保持现有顺序；源列表已限长约 200 条）。
  List<Object?> exportChatHistory();

  /// 接收随迁历史并回填到聊天列表；只更新列表，不触发播放器飘屏动画。
  void importChatHistory(List<Object?> raw);
}
