/// 批量释放 presence 标签的最小依赖。
///
/// TabStore 只需要"批量摘栈"能力，不依赖 DouyinPresenceGateway 具体类：
/// 主引擎注入网关，子引擎注入 IPC presence coordinator（转发
/// pr_batch_release），两者实现同一接口。
abstract class PresenceBatchReleaser {
  Future<void> batchRelease(Set<String> tabIds);
}
