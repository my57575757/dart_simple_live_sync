import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:get/get.dart';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_registry.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 主引擎数据面：收子窗写请求落真实 Hive，订阅真实 box 变更流统一扇出广播。
/// watch 是扇出唯一出口（主窗本地写与子窗写穿落盘都经过它），handler 不另发广播。
///
/// 时序契约：MemoryKvBox 的 changes 为同步广播（put 返回前监听器已执行），
/// 生产 HiveKvBox 经 box.watch 异步派发。监听回调不得向同一 box 回写
/// （同步广播下会重入），也不得抛异常；扇出已逐窗 try/catch 包裹同步部分，
/// invoke 返回的 Future 用 catchError 兜底，单窗失败不影响其余窗。
class MainDataPlaneService extends GetxService {
  MainDataPlaneService({
    required this.port,
    required this.registry,
    required this.storage,
    required this.db,
    this.onSettingsChanged,
    this.mainController,
  });

  final SubWindowPort port;
  final WindowRegistry registry;
  final LocalStorageService storage;
  final DBService db;
  final void Function()? onSettingsChanged;
  final WindowController? mainController;

  final List<StreamSubscription<dynamic>> _subs = [];
  final Set<String> _suppressed = <String>{};
  bool _remoteWrite = false;
  Timer? _reloadTimer;
  bool _closed = false;

  static const Duration _reloadDebounce = Duration(milliseconds: 100);

  @override
  void onInit() {
    super.onInit();
    _subs.add(storage.settingsBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindKv, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(storage.shieldBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindShield, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(db.volumeBox.changes().listen((c) =>
        _onBoxChange(DataPlaneProtocol.kindVolume, c.key.toString(), c.value,
            deleted: c.deleted)));
    _subs.add(db.followBox.changes().listen(_onFollowChange));
    mainController?.setWindowMethodHandler(
        (call) => handleCall(call.method, call.arguments));
  }

  @override
  void onClose() {
    _closed = true;
    _reloadTimer?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _subs.clear();
    super.onClose();
  }

  void _onFollowChange(KvChange<FollowUser> c) {
    final follow = c.value;
    _onBoxChange(
      DataPlaneProtocol.kindFollow,
      c.key.toString(),
      follow?.shareUrl,
      deleted: c.deleted || follow == null,
    );
  }

  void _onBoxChange(String kind, String key, Object? value,
      {required bool deleted}) {
    if (_suppressed.contains(kind)) return;
    if (kind == DataPlaneProtocol.kindKv) {
      // 扇出侧守卫：主窗本地登录等敏感写入也不得进入子引擎
      if (DataPlaneProtocol.isSensitiveKey(key)) return;
      if (!DataPlaneProtocol.isAllowedValue(value)) return;
    }
    _fanout(DataPlaneProtocol.changed(
        kind: kind, key: key, value: value, deleted: deleted));
    if (_remoteWrite) _scheduleReload();
  }

  void _scheduleReload() {
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, () {
      if (_closed) return;
      final callback = onSettingsChanged;
      if (callback == null) return;
      try {
        callback();
      } catch (e) {
        Log.d('数据面设置 reload 回调异常：$e');
      }
    });
  }

  void _fanout(Map<String, Object?> payload) {
    for (final windowId in registry.childWindowIds) {
      try {
        unawaited(port
            .invoke(windowId, DataPlaneProtocol.mChanged, payload)
            .catchError((Object e) => null));
      } catch (e) {
        Log.d('数据面广播失败：$windowId - $e');
      }
    }
  }

  KvBox<dynamic> _kvBox(String name) => name == DataPlaneProtocol.boxShield
      ? storage.shieldBox
      : storage.settingsBox;

  Future<void> _withRemoteFlag(Future<void> Function() action) async {
    _remoteWrite = true;
    try {
      await action();
    } finally {
      _remoteWrite = false;
    }
  }

  /// 落盘失败统一回执 false：Hive 写异常不得经 method channel 逸出，
  /// 否则子端乐观态与主端不一致且收不到失败回执。
  Future<bool> _guardedWrite(Future<void> Function() action) async {
    try {
      await action();
      return true;
    } catch (e) {
      Log.d('数据面落盘失败：$e');
      return false;
    }
  }

  /// 主窗 method handler 入口（onInit 挂到 mainController；测试直接调）
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case DataPlaneProtocol.mReady:
        return WindowSnapshotBuilder.buildDataSnapshot().toJson();

      case DataPlaneProtocol.mKvSet:
        final w = DataPlaneProtocol.decodeKvSet(arguments);
        if (w == null) return false;
        // 写入侧守卫：敏感键不落盘、不扇出
        if (w.box == DataPlaneProtocol.boxSettings &&
            DataPlaneProtocol.isSensitiveKey(w.key)) {
          Log.d('数据面拒绝敏感键写穿：${w.key}');
          return false;
        }
        return _guardedWrite(() => _withRemoteFlag(() async {
              if (w.box == DataPlaneProtocol.boxShield) {
                await storage.shieldBox.put(w.key, w.value as String);
              } else {
                await storage.settingsBox.put(w.key, w.value);
              }
            }));

      case DataPlaneProtocol.mKvDelete:
        final w = DataPlaneProtocol.decodeKvDelete(arguments);
        if (w == null) return false;
        // 删除侧同样守敏感键：游客子窗不得删除主窗凭据
        if (w.box == DataPlaneProtocol.boxSettings &&
            DataPlaneProtocol.isSensitiveKey(w.key)) {
          Log.d('数据面拒绝敏感键删除：${w.key}');
          return false;
        }
        return _guardedWrite(
            () => _withRemoteFlag(() => _kvBox(w.box).delete(w.key)));

      case DataPlaneProtocol.mKvClear:
        final boxName = DataPlaneProtocol.kvBoxOf(arguments);
        if (boxName == null) return false;
        // settings 投影箱无差别 clear 会删掉主窗凭据：子箱从不持有敏感键，
        // 子窗也没有 settingsBox.clear 业务入口（仅主窗 WebDAV 恢复/重置深
        // 路由可达，M4-3 收口），故整箱清空一律拒绝；shield 无敏感键放行。
        if (boxName == DataPlaneProtocol.boxSettings) {
          Log.d('数据面拒绝 settings 整箱清空（凭据安全）');
          return false;
        }
        const kind = DataPlaneProtocol.kindShield;
        final ok = await _guardedWrite(() async {
          _suppressed.add(kind);
          try {
            await _kvBox(boxName).clear();
            // Hive BoxBaseImpl.clear 先 await backend 后同步 keystore.notify，
            // 逐 key 事件经 async broadcast 以 microtask 链式重排，而 await 链
            // 同步坍缩会使 finally 早于它们执行；排空一个事件轮次再解除抑制。
            // MemoryKvBox 为 sync 广播，此处空等。
            await Future<void>.delayed(Duration.zero);
          } finally {
            _suppressed.remove(kind);
          }
        });
        if (!ok) return false;
        _fanout(DataPlaneProtocol.changed(kind: kind, key: '', clear: true));
        _scheduleReload();
        return true;

      case DataPlaneProtocol.mVolumeSet:
        if (arguments is! Map) return false;
        final key = arguments['key'];
        final value = arguments['value'];
        if (key is! String || value is! num) return false;
        return _guardedWrite(() => _withRemoteFlag(
            () => db.addOrUpdateVolume(key, value.toDouble())));

      case DataPlaneProtocol.mFollowSet:
        final FollowUser follow;
        try {
          if (arguments is! Map || arguments['follow'] is! Map) return false;
          follow = FollowUser.fromJson(
              Map<String, dynamic>.from(arguments['follow'] as Map));
        } catch (e) {
          Log.d('dp_follow_set 载荷解析失败：$e');
          return false;
        }
        final setOk = await _guardedWrite(
            () => _withRemoteFlag(() => db.addFollow(follow)));
        if (!setOk) return false;
        EventBus.instance.emit(Constant.kUpdateFollow, follow.id);
        return true;

      case DataPlaneProtocol.mFollowRemove:
        if (arguments is! Map || arguments['key'] is! String) return false;
        final key = arguments['key'] as String;
        final removeOk = await _guardedWrite(
            () => _withRemoteFlag(() => db.deleteFollow(key)));
        if (!removeOk) return false;
        EventBus.instance.emit(Constant.kUpdateFollow, key);
        return true;

      case DataPlaneProtocol.mHistoryAdd:
        try {
          if (arguments is! Map || arguments['history'] is! Map) return false;
          final history = History.fromJson(
              Map<String, dynamic>.from(arguments['history'] as Map));
          await db.addOrUpdateHistory(history);
        } catch (e) {
          Log.d('dp_history_add 载荷解析失败：$e');
          return false;
        }
        return true;

      default:
        return null;
    }
  }
}
