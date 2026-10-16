import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';

void main() {
  test('MemoryKvBox 基础读写与默认值', () async {
    final box = MemoryKvBox<String>();
    expect(box.get('a'), isNull);
    expect(box.get('a', defaultValue: 'd'), 'd');
    expect(box.containsKey('a'), isFalse);

    await box.put('a', 'x');
    expect(box.get('a'), 'x');
    expect(box.containsKey('a'), isTrue);
    expect(box.values, ['x']);
    expect(box.keys, ['a']);
    expect(box.toMap(), {'a': 'x'});

    await box.putAll({'b': 'y', 'c': 'z'});
    expect(box.values, ['x', 'y', 'z']);

    final cleared = await box.clear();
    expect(cleared, 3);
    expect(box.values, isEmpty);
  });

  test('MemoryKvBox 支持非字符串键（标签排序用 int 键）', () async {
    final box = MemoryKvBox<String>();
    await box.put(0, '零');
    expect(box.get(0), '零');
    await box.delete(0);
    expect(box.containsKey(0), isFalse);
  });

  test('MemoryKvBox changes：put/delete 缺失/clear 事件序列对齐 Hive',
      () async {
    final box = MemoryKvBox<String>();
    final events = <List<Object?>>[];
    box.changes().listen((e) => events.add([e.key, e.value, e.deleted]));

    await box.put('a', '1');
    await box.put('a', '2'); // 同值覆盖也发
    await box.delete('missing'); // 不存在不发
    await box.put('b', 'x');
    await box.clear();

    expect(events, [
      ['a', '1', false],
      ['a', '2', false],
      ['b', 'x', false],
      ['a', null, true],
      ['b', null, true],
    ]);
  });

  test('MemoryKvBox putAll 逐键发事件', () async {
    final box = MemoryKvBox<String>();
    final keys = <Object>[];
    box.changes().listen((e) => keys.add(e.key));
    await box.putAll({1: '一', 2: '二'});
    expect(keys, [1, 2]);
  });

  test('SeedableKvBox seed* 静默：不发事件但读可见、可整体替换',
      () async {
    final SeedableKvBox<String> box = MemoryKvBox<String>();
    final events = <KvChange<String>>[];
    box.changes().listen(events.add);

    box.seedPut('a', '1');
    expect(box.get('a'), '1');
    box.seedDelete('a');
    expect(box.containsKey('a'), isFalse);
    box.seedReplaceAll({'x': 'X', 'y': 'Y'});
    expect(box.toMap(), {'x': 'X', 'y': 'Y'});
    await box.seedClear();
    expect(box.values, isEmpty);
    expect(events, isEmpty, reason: '种子路径不得发事件');
  });
}
