import 'package:simple_live_core/simple_live_core.dart';

/// 跨窗标签迁移时的弹幕聊天历史线格式（mw_ 载荷专用）。
///
/// 仅承载聊天展示四元组（用户名 / 正文 / RGB / 是否本人），全部 JSON 兼容，
/// 不含任何凭据字段。[LiveRoomController.messages] 契约上全是 chat
/// （onWSMessage 仅 chat 入列、addSysMsg 也是 chat），故线格式不承载
/// LiveMessageType，也不承载 online 的人气值 data；对端解码后恒重建为 chat。
/// 对端（可能是被构造的脏载荷）逐条严格校验，坏条目跳过而非整批丢弃。

List<Map<String, Object?>> encodeChatHistory(
  Iterable<LiveMessage> messages,
) =>
    [
      for (final m in messages)
        <String, Object?>{
          'u': m.userName,
          'm': m.message,
          'c': [m.color.r, m.color.g, m.color.b],
          's': m.isSelf,
        },
    ];

List<LiveMessage> decodeChatHistory(Object? raw) {
  if (raw is! List) return const [];
  final out = <LiveMessage>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final u = entry['u'];
    final text = entry['m'];
    final color = entry['c'];
    final self = entry['s'];
    if (u is! String || text is! String) continue;
    if (color is! List || color.length != 3) continue;
    if (self != null && self is! bool) continue;
    final rgb = <int>[];
    var valid = true;
    for (final v in color) {
      if (v is num && v >= 0 && v <= 255) {
        rgb.add(v.toInt());
      } else {
        valid = false;
        break;
      }
    }
    if (!valid) continue;
    out.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: u,
        message: text,
        color: LiveMessageColor(rgb[0], rgb[1], rgb[2]),
        isSelf: self == true,
      ),
    );
  }
  return out;
}
