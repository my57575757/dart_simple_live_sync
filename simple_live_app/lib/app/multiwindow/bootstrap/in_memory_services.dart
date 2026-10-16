import 'dart:async';

import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 子引擎专用：纯内存 LocalStorage，按启动快照播种，init() 不打开 Hive。
/// settings/shield box 由装配层注入 RemoteKvBox（写穿）；缺省回退纯内存。
class InMemoryLocalStorageService extends LocalStorageService {
  InMemoryLocalStorageService({
    KvBox<dynamic>? settingsBox,
    KvBox<String>? shieldBox,
  }) {
    this.settingsBox = settingsBox ?? MemoryKvBox<dynamic>();
    this.shieldBox = shieldBox ?? MemoryKvBox<String>();
  }

  @override
  Future<void> init() async {}

  /// 无主窗 id 的回退路径（纯快照模式）；写穿路径由装配层直接 seedReplaceAll
  void applySnapshot(WindowSnapshot snapshot) {
    for (final entry in snapshot.settings.entries) {
      settingsBox.put(entry.key, entry.value);
    }
    for (final word in snapshot.shield) {
      shieldBox.put(word, word);
    }
  }
}

/// 子引擎专用：关注只保留 id→shareUrl 映射（无完整 FollowUser），
/// 音量/标签/历史走内存 box；装配 dataPort 后 follow/volume/history 写穿主引擎。
class InMemoryDBService extends DBService {
  InMemoryDBService({SubDataPlanePort? dataPort}) : _dataPort = dataPort {
    historyBox = _history;
    followBox = _follow;
    tagBox = _tag;
    volumeBox = _volume;
  }

  final SubDataPlanePort? _dataPort;

  final MemoryKvBox<History> _history = MemoryKvBox<History>();
  final MemoryKvBox<FollowUser> _follow = MemoryKvBox<FollowUser>();
  final MemoryKvBox<FollowUserTag> _tag = MemoryKvBox<FollowUserTag>();
  final MemoryKvBox<double> _volume = MemoryKvBox<double>();

  final Map<String, String> _followShareUrls = {};

  @override
  Future<void> init() async {}

  void applySnapshot(WindowSnapshot snapshot) {
    seedDataSnapshot(snapshot);
  }

  /// dp_ready 对账/启动快照：静默全量替换（不发 IPC、不依赖广播）
  void seedDataSnapshot(WindowSnapshot snapshot) {
    _volume.seedReplaceAll(Map<Object, double>.of(snapshot.volumes));
    _followShareUrls
      ..clear()
      ..addAll(snapshot.followShareUrls);
  }

  // —— 广播种子（SubDataPlaneClient 调用，静默）——

  void seedVolume(String key, double? value, {bool deleted = false}) {
    if (deleted) {
      _volume.seedDelete(key);
    } else if (value != null) {
      _volume.seedPut(key, value);
    }
  }

  void seedVolumesClear() {
    unawaited(_volume.seedClear());
  }

  void seedFollowShare(String key, String shareUrl) {
    _followShareUrls[key] = shareUrl;
  }

  void seedFollowRemove(String key) {
    _followShareUrls.remove(key);
  }

  void _fire(String method, Object? arguments) {
    final port = _dataPort;
    if (port == null) return;
    try {
      unawaited(port.invokeMain(method, arguments).catchError((Object e) {
        Log.d('数据面写穿失败（本地已生效）：$method - $e');
        return null;
      }));
    } catch (e) {
      Log.d('数据面写穿同步异常：$method - $e');
    }
  }

  @override
  bool getFollowExist(String id) => _followShareUrls.containsKey(id);

  @override
  String? getFollowShareUrl(String id) => _followShareUrls[id];

  @override
  List<FollowUser> getFollowList() => const [];

  @override
  Future<void> addFollow(FollowUser follow) async {
    // 与生产逻辑一致：不覆盖已有有效 shareUrl
    final existing = _followShareUrls[follow.id];
    final share = (existing != null &&
            existing.isNotEmpty &&
            follow.shareUrl.isEmpty)
        ? existing
        : follow.shareUrl;
    _followShareUrls[follow.id] = share;
    follow.shareUrl = share;
    _fire(DataPlaneProtocol.mFollowSet,
        DataPlaneProtocol.followSet(follow.toJson()));
  }

  @override
  Future<void> updateFollow(FollowUser follow) => addFollow(follow);

  @override
  Future<void> deleteFollow(String id) async {
    _followShareUrls.remove(id);
    _fire(DataPlaneProtocol.mFollowRemove,
        DataPlaneProtocol.followRemove(id));
  }

  @override
  Future<void> addOrUpdateVolume(String id, double volume) async {
    _volume.seedPut(id, volume);
    _fire(DataPlaneProtocol.mVolumeSet,
        DataPlaneProtocol.volumeSet(id, volume));
  }

  @override
  Future<void> addOrUpdateHistory(History history) async {
    _history.seedPut(history.id, history);
    _fire(DataPlaneProtocol.mHistoryAdd,
        DataPlaneProtocol.historyAdd(history.toJson()));
  }
}
