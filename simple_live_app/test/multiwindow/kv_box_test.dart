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
}
