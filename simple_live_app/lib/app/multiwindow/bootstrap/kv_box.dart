import 'package:hive/hive.dart';

/// 同构 KV 存储接缝：生产走 Hive，房间子引擎走纯内存。
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
}

class MemoryKvBox<T> implements KvBox<T> {
  final Map<Object, T> _map = {};

  @override
  T? get(Object key, {T? defaultValue}) =>
      _map.containsKey(key) ? _map[key] : defaultValue;

  @override
  Future<void> put(Object key, T value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(Object key) async {
    _map.remove(key);
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
    _map.clear();
    return count;
  }

  @override
  Map<Object, T> toMap() => Map<Object, T>.of(_map);

  @override
  Future<void> putAll(Map<Object, T> entries) async {
    _map.addAll(entries);
  }
}
