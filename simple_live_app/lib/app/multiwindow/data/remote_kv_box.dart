import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';

/// 子引擎 KV：读走内存；写先乐观落本地（UI 零延迟、读己之写立即可见），
/// 再 fire-and-forget 写穿主引擎。远端广播只走 seed*（见 SubDataPlaneClient），
/// 不经过这里的 put/delete/clear，故不会回环发 IPC。
class RemoteKvBox<T> implements SeedableKvBox<T> {
  RemoteKvBox(this.boxName, this.port);

  final String boxName;
  final SubDataPlanePort port;
  final MemoryKvBox<T> _local = MemoryKvBox<T>();

  void _fire(String method, Object? arguments) {
    try {
      unawaited(
        port.invokeMain(method, arguments).catchError((Object e) {
          Log.d('数据面写穿失败（已保留本地值）：$boxName - $e');
          return null;
        }),
      );
    } catch (e) {
      Log.d('数据面写穿同步异常：$boxName - $e');
    }
  }

  @override
  T? get(Object key, {T? defaultValue}) =>
      _local.get(key, defaultValue: defaultValue);

  @override
  bool containsKey(Object key) => _local.containsKey(key);

  @override
  Iterable<T> get values => _local.values;

  @override
  Iterable<Object> get keys => _local.keys;

  @override
  Map<Object, T> toMap() => _local.toMap();

  @override
  Future<void> put(Object key, T value) async {
    _local.seedPut(key, value);
    _fire(DataPlaneProtocol.mKvSet,
        DataPlaneProtocol.kvSet(boxName, key.toString(), value));
  }

  @override
  Future<void> delete(Object key) async {
    // 与 Hive 语义对齐：本地没有的键不产生写穿（子窗内存经 ready 对账是全量）
    if (!_local.containsKey(key)) return;
    _local.seedDelete(key);
    _fire(DataPlaneProtocol.mKvDelete,
        DataPlaneProtocol.kvDelete(boxName, key.toString()));
  }

  @override
  Future<int> clear() async {
    final count = _local.toMap().length;
    await _local.seedClear();
    _fire(DataPlaneProtocol.mKvClear, DataPlaneProtocol.kvClear(boxName));
    return count;
  }

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Stream<KvChange<T>> changes() => _local.changes();

  @override
  void seedPut(Object key, T value) => _local.seedPut(key, value);

  @override
  void seedDelete(Object key) => _local.seedDelete(key);

  @override
  Future<void> seedClear() => _local.seedClear();

  @override
  void seedReplaceAll(Map<Object, T> entries) =>
      _local.seedReplaceAll(entries);
}
