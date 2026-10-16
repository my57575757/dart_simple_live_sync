import 'dart:async';

import 'package:hive/hive.dart';

/// 一次 KV 变更（对齐 Hive BoxEvent：deleted 时 value 为 null）
class KvChange<T> {
  const KvChange(this.key, this.value, {this.deleted = false});

  final Object key;
  final T? value;
  final bool deleted;
}

/// 同构 KV 存储接缝：生产走 Hive，房间子引擎走纯内存/远端写穿。
///
/// 子引擎与主引擎同进程但属于不同 engine/isolate，重复 open 同一 Hive box
/// 文件会触发文件锁与 TypeAdapter 重复注册，因此子引擎不得接触 Hive。
/// 方法名与 Hive Box 保持一致，调用方无需感知后端。
abstract class KvBox<T> {
  T? get(Object key, {T? defaultValue});
  Future<void> put(Object key, T value);
  Future<void> delete(Object key);
  bool containsKey(Object key);
  Iterable<T> get values;
  Iterable<Object> get keys;
  Future<int> clear();
  Map<Object, T> toMap();
  Future<void> putAll(Map<Object, T> entries);

  /// 变更流。事件语义与 Hive box.watch 对齐（put 总发、delete 缺失不发、
  /// clear 逐 key 发 deleted）。
  Stream<KvChange<T>> changes();
}

/// 可静默播种的 KV：远端广播/启动快照走 seed*，不触发 changes、不发 IPC。
abstract class SeedableKvBox<T> implements KvBox<T> {
  void seedPut(Object key, T value);
  void seedDelete(Object key);
  Future<void> seedClear();
  void seedReplaceAll(Map<Object, T> entries);
}

class HiveKvBox<T> implements KvBox<T> {
  HiveKvBox(this.box);

  final Box<T> box;

  @override
  T? get(Object key, {T? defaultValue}) =>
      box.get(key, defaultValue: defaultValue);

  @override
  Future<void> put(Object key, T value) => box.put(key, value);

  @override
  Future<void> delete(Object key) => box.delete(key);

  @override
  bool containsKey(Object key) => box.containsKey(key);

  @override
  Iterable<T> get values => box.values;

  @override
  Iterable<Object> get keys => box.keys.cast<Object>();

  @override
  Future<int> clear() => box.clear();

  @override
  Map<Object, T> toMap() => box.toMap().cast<Object, T>();

  @override
  Future<void> putAll(Map<Object, T> entries) => box.putAll(entries);

  @override
  Stream<KvChange<T>> changes() => box.watch().map(
      (e) => KvChange<T>(e.key as Object, e.value as T?, deleted: e.deleted));
}

class MemoryKvBox<T> implements SeedableKvBox<T> {
  final Map<Object, T> _map = {};
  final StreamController<KvChange<T>> _changes =
      StreamController<KvChange<T>>.broadcast(sync: true);

  @override
  T? get(Object key, {T? defaultValue}) =>
      _map.containsKey(key) ? _map[key] : defaultValue;

  @override
  Future<void> put(Object key, T value) async {
    _map[key] = value;
    _changes.add(KvChange<T>(key, value));
  }

  @override
  Future<void> delete(Object key) async {
    if (!_map.containsKey(key)) return;
    _map.remove(key);
    // 与 Hive BoxEvent 对齐：删除事件 value 恒为 null
    _changes.add(KvChange<T>(key, null, deleted: true));
  }

  @override
  bool containsKey(Object key) => _map.containsKey(key);

  @override
  Iterable<T> get values => _map.values;

  @override
  Iterable<Object> get keys => _map.keys;

  @override
  Future<int> clear() async {
    final count = _map.length;
    final removedKeys = List<Object>.of(_map.keys);
    _map.clear();
    for (final key in removedKeys) {
      // 与 Hive BoxEvent 对齐：删除事件 value 恒为 null
      _changes.add(KvChange<T>(key, null, deleted: true));
    }
    return count;
  }

  @override
  Map<Object, T> toMap() => Map<Object, T>.of(_map);

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    for (final entry in entries.entries) {
      await put(entry.key, entry.value);
    }
  }

  @override
  Stream<KvChange<T>> changes() => _changes.stream;

  @override
  void seedPut(Object key, T value) {
    _map[key] = value;
  }

  @override
  void seedDelete(Object key) {
    _map.remove(key);
  }

  @override
  Future<void> seedClear() async {
    _map.clear();
  }

  @override
  void seedReplaceAll(Map<Object, T> entries) {
    _map
      ..clear()
      ..addAll(entries);
  }
}
