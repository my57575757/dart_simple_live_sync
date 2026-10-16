import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';

class _RecordingPort implements SubDataPlanePort {
  final List<(String, Object?)> calls = [];
  bool throwOnInvoke = false;

  @override
  Future<Object?> invokeMain(String method, [Object? arguments]) async {
    calls.add((method, arguments));
    if (throwOnInvoke) throw StateError('ipc down');
    return null;
  }
}

void main() {
  test('put 乐观更新立即可见并按协议发 IPC', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);

    await box.put('词', '词');
    expect(box.get('词'), '词');
    expect(port.calls.single.$1, DataPlaneProtocol.mKvSet);
    final payload = port.calls.single.$2! as Map;
    expect(payload['box'], DataPlaneProtocol.boxShield);
    expect(payload['key'], '词');
    expect(payload['value'], '词');
  });

  test('delete 已存在键发 mKvDelete；删不存在键不发', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);

    await box.delete('missing');
    expect(port.calls, isEmpty);

    await box.put('k', 1);
    await box.delete('k');
    expect(port.calls.last.$1, DataPlaneProtocol.mKvDelete);
    expect((port.calls.last.$2! as Map)['key'], 'k');
    expect(box.containsKey('k'), isFalse);
  });

  test('clear 静默清空本地并发单条 mKvClear', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<String>(DataPlaneProtocol.boxShield, port);
    await box.put('a', 'a');
    port.calls.clear();
    final n = await box.clear();
    expect(n, 1);
    expect(port.calls.single.$1, DataPlaneProtocol.mKvClear);
    expect(box.values, isEmpty);
  });

  test('seed* 静默：不发任何 IPC', () async {
    final port = _RecordingPort();
    final SeedableKvBox<dynamic> box =
        RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
    box.seedPut('a', 1);
    box.seedReplaceAll({'b': 2});
    await box.seedClear();
    box.seedDelete('b');
    expect(port.calls, isEmpty);
  });

  test('IPC 失败不向调用方抛出，本地乐观值保留', () async {
    final port = _RecordingPort();
    final box = RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, port);
    port.throwOnInvoke = true;
    await box.put('a', 1); // 不抛
    expect(box.get('a'), 1, reason: '本地乐观值保留');
  });
}
