/// 发送成功后本地立即插入自我消息；服务器（部分平台）随后仍会把
/// 同一条消息推回收听连接，用本类按「内容 + 时间窗口」消费掉回环，避免双显。
class SelfEchoTracker {
  /// 去重窗口：各平台回环通常在数秒内到达
  static const int windowMs = 10000;

  /// 待消费条目上限，防止异常情况下无限增长
  static const int maxPending = 20;

  final List<_PendingEcho> _pending = [];

  /// 当前毫秒时间；测试可注入
  final int Function() now;

  SelfEchoTracker({int Function()? now})
      : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// 发送成功时登记一条待回环消息
  void add(String text) {
    _pending.add(_PendingEcho(text, now()));
    if (_pending.length > maxPending) {
      _pending.removeAt(0);
    }
  }

  /// 命中待消费回环则移除并返回 true（调用方丢弃该推送）；
  /// 先清理超出窗口的过期条目
  bool consume(String text) {
    var current = now();
    _pending.removeWhere((e) => current - e.time > windowMs);
    for (var i = 0; i < _pending.length; i++) {
      if (_pending[i].text == text) {
        _pending.removeAt(i);
        return true;
      }
    }
    return false;
  }
}

class _PendingEcho {
  final String text;
  final int time;
  _PendingEcho(this.text, this.time);
}
