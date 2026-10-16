import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// 子引擎专用：纯内存 LocalStorage，按启动快照播种，init() 不打开 Hive
class InMemoryLocalStorageService extends LocalStorageService {
  InMemoryLocalStorageService() {
    settingsBox = MemoryKvBox<dynamic>();
    shieldBox = MemoryKvBox<String>();
  }

  @override
  Future<void> init() async {}

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
/// 音量/标签/历史走内存 box，进程结束即丢弃
class InMemoryDBService extends DBService {
  InMemoryDBService() {
    historyBox = MemoryKvBox<History>();
    followBox = MemoryKvBox<FollowUser>();
    tagBox = MemoryKvBox<FollowUserTag>();
    volumeBox = MemoryKvBox<double>();
  }

  @override
  Future<void> init() async {}

  final Map<String, String> _followShareUrls = {};

  void applySnapshot(WindowSnapshot snapshot) {
    snapshot.volumes.forEach(volumeBox.put);
    _followShareUrls.addAll(snapshot.followShareUrls);
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
  }

  @override
  Future<void> updateFollow(FollowUser follow) => addFollow(follow);

  @override
  Future<void> deleteFollow(String id) async {
    _followShareUrls.remove(id);
  }
}
