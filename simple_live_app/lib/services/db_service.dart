import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';

import '../app/controller/app_settings_controller.dart';
import '../app/log.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<double> volumeBox;
  Future init() async {
    historyBox = await Hive.openBox("History");
    followBox = await Hive.openBox("FollowUser");
    volumeBox = await Hive.openBox("Volume");
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
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

  Future addOrUpdateVolume(String id,double volume) async {
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
