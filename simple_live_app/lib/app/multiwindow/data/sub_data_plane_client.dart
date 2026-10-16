import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/in_memory_services.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';

/// 子引擎数据面客户端：dp_ready 对账、dp_changed 分流、设置防抖 reload、
/// 关注按钮定向刷新。所有写入都先在本地乐观生效（RemoteKvBox/InMemoryDB），
/// 本类只接收，绝不向主窗回发 changed，无回环。
class SubDataPlaneClient {
  SubDataPlaneClient({
    required this.port,
    required this.settings,
    required this.shield,
    required this.db,
    required this.registry,
    required this.onSettingsChanged,
  });

  final SubDataPlanePort port;
  final SeedableKvBox<dynamic> settings;
  final SeedableKvBox<String> shield;
  final InMemoryDBService db;
  final RoomControllerRegistry registry;
  final void Function() onSettingsChanged;

  Timer? _reloadTimer;

  static const Duration _reloadDebounce = Duration(milliseconds: 100);

  /// 开窗后一次性对账：拉主窗当前全量数据，全量替换本地数据面
  Future<void> reconcile() async {
    try {
      final raw = await port.invokeMain(DataPlaneProtocol.mReady);
      if (raw is! Map) return;
      final snapshot =
          WindowSnapshot.fromJson(Map<String, dynamic>.from(raw));
      settings.seedReplaceAll(Map<Object, dynamic>.of(snapshot.settings));
      shield.seedReplaceAll(
          <Object, String>{for (final word in snapshot.shield) word: word});
      db.seedDataSnapshot(snapshot);
      _scheduleReload();
    } catch (e) {
      // 主窗不可达时沿用启动快照（主窗关闭=整个应用退出，此路径实际不可达）
      Log.d('dp_ready 对账失败，沿用启动快照：$e');
    }
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, onSettingsChanged);
  }

  void _applySeed(SeedableKvBox<dynamic> box, ChangeEvent e) {
    if (e.clear) {
      unawaited(box.seedClear());
    } else if (e.deleted) {
      box.seedDelete(e.key);
    } else {
      box.seedPut(e.key, e.value);
    }
  }

  /// 总 handler 的 dp_changed 分支调用
  void handleChanged(Object? arguments) {
    final e = DataPlaneProtocol.decodeChanged(arguments);
    if (e == null) return;
    switch (e.kind) {
      case DataPlaneProtocol.kindKv:
        _applySeed(settings, e);
        _scheduleReload();
      case DataPlaneProtocol.kindShield:
        if (e.clear) {
          unawaited(shield.seedClear());
        } else if (e.deleted) {
          shield.seedDelete(e.key);
        } else if (e.value is String) {
          shield.seedPut(e.key, e.value as String);
        }
        _scheduleReload();
      case DataPlaneProtocol.kindVolume:
        if (e.clear) {
          db.seedVolumesClear();
        } else {
          final value = e.value;
          db.seedVolume(e.key, value is num ? value.toDouble() : null,
              deleted: e.deleted || value == null);
        }
      case DataPlaneProtocol.kindFollow:
        if (e.deleted) {
          db.seedFollowRemove(e.key);
        } else {
          db.seedFollowShare(e.key, e.value?.toString() ?? '');
        }
        registry.controllerForRoomKey(e.key)?.followed.value = !e.deleted;
    }
  }
}
