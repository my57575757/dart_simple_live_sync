import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/multiwindow/bootstrap/kv_box.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

import '../app/controller/app_settings_controller.dart';
import '../app/log.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late KvBox<History> historyBox;
  late KvBox<FollowUser> followBox;
  late KvBox<FollowUserTag> tagBox;
  final Uuid uuid = const Uuid();

  late KvBox<double> volumeBox;
  Future init() async {
    historyBox = HiveKvBox<History>(await Hive.openBox("History"));
    followBox = HiveKvBox<FollowUser>(await Hive.openBox("FollowUser"));
    volumeBox = HiveKvBox<double>(await Hive.openBox("Volume"));
    tagBox =
        HiveKvBox<FollowUserTag>(await Hive.openBox("FollowUserTag"));
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.containsKey(id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    await tagBox.delete(id);
  }

  FollowUserTag? getFollowTag(String tag) {
    return tagBox.values.firstWhereOrNull((item) => item.tag == tag);
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表
  List<FollowUserTag> getFollowTagList() {
    return tagBox.values.toList();
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    await tagBox.put(followTag.id, followTag);
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    // 限制标签唯一且长度不超过8个字符
    if (getFollowTagExistByTag(tag) && tag.length > 8) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(id: uniqueId, tag: tag, userId: []);
    await tagBox.put(uniqueId, followUserTag);
    return followUserTag;
  }

  // 调整标签顺序
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    final Map<int, FollowUserTag> updatedMap = {
      for (int i = 0; i < userTagList.length; i++) i: userTagList[i]
    };
    await tagBox.clear();
    await tagBox.putAll(updatedMap);
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  /// 关注记录中保存的分享链接；未关注或为空返回 null。
  /// 供直播间构造期同步回填 shareUrl（替代对 followBox 的直连）。
  String? getFollowShareUrl(String id) {
    return followBox.get(id)?.shareUrl;
  }

  /// 导出全部房间音量（跨窗快照用）
  Map<String, double> exportVolumes() {
    return {
      for (final key in volumeBox.keys)
        key.toString(): volumeBox.get(key) ?? 70,
    };
  }

  /// 导出关注房间 id → shareUrl（含空串，空串也代表“已关注”）
  Map<String, String> exportFollowShareUrls() {
    return {
      for (final follow in followBox.values) follow.id: follow.shareUrl,
    };
  }

  Future addFollow(FollowUser follow) async {
    var existing = followBox.get(follow.id);
    if (existing != null &&
        existing.shareUrl.isNotEmpty &&
        follow.shareUrl.isEmpty) {
      follow.shareUrl = existing.shareUrl;
    }
    await followBox.put(follow.id, follow);
  }

  /// 更新关注用户（用于同步场景）
  /// 与 addFollow 不同，此方法专门用于同步场景，保留有效 shareUrl
  Future updateFollow(FollowUser follow) async {
    var existing = followBox.get(follow.id);
    if (existing != null &&
        existing.shareUrl.isNotEmpty &&
        follow.shareUrl.isEmpty) {
      follow.shareUrl = existing.shareUrl;
    }
    await followBox.put(follow.id, follow);
  }

  Future deleteFollow(String id) async {
    await followBox.delete(id);
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await historyBox.put(history.id, history);
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }

  Future addOrUpdateVolume(String id, double volume) async {
    await volumeBox.put(id, volume);
  }

  double? getVolume(String id) {
    if (volumeBox.containsKey(id)) {
      var d = volumeBox.get(id);
      Log.d("value:$d");
      return d;
    }
    return 70;
  }
}
