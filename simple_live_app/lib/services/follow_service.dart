import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

class FollowService extends GetxService {
  StreamSubscription<dynamic>? subscription;
  static FollowService get instance => Get.find<FollowService>();

  final StreamController _updatedListController = StreamController.broadcast();
  Stream get updatedListStream => _updatedListController.stream;

  /// 关注用户列表
  RxList<FollowUser> followList = RxList<FollowUser>();

  /// 直播中的用户列表
  RxList<FollowUser> liveList = RxList<FollowUser>();

  /// 未直播的用户列表
  RxList<FollowUser> notLiveList = RxList<FollowUser>();

  /// 用户自定义的tag
  RxList<FollowUserTag> followTagList = RxList<FollowUserTag>();

  /// 当前tag的用户列表
  RxList<FollowUser> curTagFollowList = RxList<FollowUser>();

  /// 已经更新状态的数量
  var updatedCount = 0;

  /// 是否正在更新
  var updating = false.obs;

  Timer? updateTimer;

  /// 状态变化后合并刷新通知的防抖定时器
  Timer? listNotifyTimer;

  /// 本轮是否有状态实际变化（开播/下播）
  bool hasStatusChanged = false;

  /// 防抖窗口：窗口内多次变化只重建一次列表
  static const int listNotifyDebounceMs = 800;

  /// 抖音返回 444 后置为 true：停止自动获取抖音直播状态，由用户手动刷新解除
  bool douyinBlocked = false;

  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      loadData(updateStatus: false);
    });
    initTimer();
    super.onInit();
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    listNotifyTimer?.cancel();
    for (var timer in _retryTimers) {
      timer.cancel();
    }
    _retryTimers.clear();
    subscription?.cancel();
    super.onClose();
  }

  // 添加标签
  Future<void> addFollowUserTag(String tag) async {
    // 判断待添加tag是否已存在，存在则return
    if (followTagList.any((item) => item.tag == tag)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    FollowUserTag item = await DBService.instance.addFollowTag(tag);
    followTagList.add(item);
  }

  // 删除标签
  Future<void> delFollowUserTag(FollowUserTag tag) async {
    followTagList.remove(tag);
    await DBService.instance.deleteFollowTag(tag.id);
  }

  // 获取用户自定义标签列表
  void getAllTagList() {
    var list = DBService.instance.getFollowTagList();
    followTagList.assignAll(list);
  }

  // 修改标签
  void updateFollowUserTag(FollowUserTag tag) {
    DBService.instance.updateFollowTag(tag);
    // 查找并修改
    var index = followTagList.indexWhere((oTag) => oTag.id == tag.id);
    followTagList[index] = tag;
  }

  // 根据标签筛选数据
  void filterDataByTag(FollowUserTag tag) {
    curTagFollowList.clear();
    // 用一个新的列表来存储需要删除的 userId
    List<String> toRemove = [];
    for (var id in tag.userId) {
      if (followList.any((x) => x.id == id)) {
        // 找到对应的 followUser 添加到 curTagFollowList
        curTagFollowList.add(followList.firstWhere((x) => x.id == id));
      } else {
        // 标记要删除的 id
        toRemove.add(id);
      }
    }
    // 双向确认用户取消关注后标签内是否还有该用户
    // 在遍历结束后统一移除不在 followList 中的 id
    tag.userId.removeWhere((id) => toRemove.contains(id));
    // 更新数据库
    if (toRemove.isNotEmpty) {
      DBService.instance.updateFollowTag(tag);
    }
    // 标签内排序
    curTagFollowList.sort(
      (a, b) => b.liveStatus.value.compareTo(a.liveStatus.value),
    );
  }

  // 添加关注
  Future<void> addFollow(FollowUser follow) async {
    await DBService.instance.addFollow(follow);
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
            minutes:
                AppSettingsController.instance.autoUpdateFollowDuration.value),
        (timer) {
          Log.logPrint("Update Follow Timer");
          loadData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  Future<void> loadData(
      {bool updateStatus = true, bool manual = false}) async {
    var list = DBService.instance.getFollowList();
    getAllTagList();
    if (list.isEmpty) {
      updating.value = false;
      followList.assignAll(list);
      return;
    }
    followList.assignAll(list);
    if (updateStatus) {
      startUpdateStatus(manual: manual);
    }
  }

  /// 获取最优并发数
  /// 根据 CPU 核心数和用户设置自动计算
  int getOptimalConcurrency() {
    var userSetting = AppSettingsController.instance.updateFollowThreadCount.value;

    // 如果用户设置为 0，则自动根据 CPU 核心数计算
    if (userSetting == 0) {
      var cpuCount = Platform.numberOfProcessors;
      // 网络 I/O 密集型任务，并发数可以是 CPU 核心数的 2-3 倍
      var optimal = (cpuCount * 2.5).round();
      // 限制在合理范围内（最少 4，最多 20）
      return optimal.clamp(4, 20);
    }

    return userSetting;
  }

  /// 每次刷新递增，用于作废上一轮的重试
  int _runGeneration = 0;

  /// 本轮已拿到首次结果（成功或失败）的用户 id
  final Set<String> _settledIds = <String>{};

  /// 等待重试的定时器
  final Set<Timer> _retryTimers = <Timer>{};

  @visibleForTesting
  int get retryTimerCount => _retryTimers.length;

  static const int _retryDelaySeconds = 15;

  /// 抖音队列失败暂停后重试队头的间隔
  @visibleForTesting
  Duration douyinRetryDelay = const Duration(minutes: 1);

  /// 抖音队列相邻请求间隔（生产为 1.5–2.5s 随机），测试可覆盖
  @visibleForTesting
  Duration Function()? douyinGapForTesting;

  final Random _random = Random();

  Duration _douyinGap() =>
      douyinGapForTesting?.call() ??
      Duration(milliseconds: 1500 + _random.nextInt(1001));

  void startUpdateStatus({bool manual = false}) {
    if (manual) {
      douyinBlocked = false;
    }
    _runGeneration++;
    var generation = _runGeneration;
    _settledIds.clear();
    hasStatusChanged = false;
    listNotifyTimer?.cancel();
    updatedCount = 0;
    updating.value = true;

    for (var timer in _retryTimers) {
      timer.cancel();
    }
    _retryTimers.clear();

    final douyinItems = <FollowUser>[];
    final otherItems = <FollowUser>[];
    for (var item in followList) {
      if (item.siteId == Constant.kDouyin) {
        douyinItems.add(item);
      } else {
        otherItems.add(item);
      }
    }

    Log.logPrint(
        "开始更新关注状态：抖音串行队列 ${douyinItems.length}，其余 ${otherItems.length}");

    // 抖音：单队列串行（间隔约 2s 随机；失败暂停整队列，每 1 分钟重试队头）
    unawaited(_runDouyinQueue(douyinItems, generation));

    // 其余平台：保持并发 worker
    if (otherItems.isEmpty) {
      return;
    }
    var taskQueue = Queue<FollowUser>.from(otherItems);
    var concurrency =
        getOptimalConcurrency().clamp(1, otherItems.length);

    Future<void> worker() async {
      while (taskQueue.isNotEmpty) {
        var item = taskQueue.removeFirst();
        await updateOtherStatus(item, generation: generation);
      }
    }

    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker());
    }

    Future.wait(workers).then((_) {
      Log.logPrint("其余平台状态更新完成");
    });
  }

  /// 抖音串行队列：逐个处理，请求间随机间隔约 2s；某请求失败（非 444）
  /// 则暂停整个队列，等待 [douyinRetryDelay] 后重试同一队头，成功后继续剩余。
  Future<void> _runDouyinQueue(List<FollowUser> items, int generation) async {
    var index = 0;
    while (index < items.length) {
      if (generation != _runGeneration) {
        return;
      }
      if (douyinBlocked) {
        // 风控已触发：后续抖音用户本轮一律按未知处理，不再发请求
        for (var k = index; k < items.length; k++) {
          final item = items[k];
          final previous = item.liveStatus.value;
          item.liveStatus.value = 0;
          item.liveStartTime = null;
          if (generation == _runGeneration) {
            _settleItem(item, changed: previous != 0);
          }
        }
        return;
      }

      final item = items[index];
      final processed = await _processDouyinItem(item, generation);
      if (generation != _runGeneration) {
        return;
      }
      if (processed) {
        index++;
        if (index < items.length) {
          await Future.delayed(_douyinGap());
        }
      } else {
        // 失败暂停：后续不请求，等待后重试同一队头
        await Future.delayed(douyinRetryDelay);
      }
    }
  }

  /// 处理单个抖音用户。
  /// 返回 true：已落定（成功或 444 风控）；false：临时失败，未 settle，需重试。
  Future<bool> _processDouyinItem(FollowUser item, int generation) async {
    final previous = item.liveStatus.value;
    try {
      var site = Sites.allSites[item.siteId]!;
      var queryId = "${item.roomId};${item.shareUrl}";
      // 抖音统一走 guard（room_id 由服务端缓存），guard 未配置时回退 core 内置取页
      var isLiving = await resolveDouyinLiving(
        webRid: item.roomId,
        directFallback: () => site.liveSite.getLiveStatus(roomId: queryId),
      );
      item.liveStatus.value = isLiving ? 2 : 1;
      if (isLiving) {
        var detail = await site.liveSite.getRoomDetail(roomId: queryId);
        item.liveStartTime = detail.showTime;
      } else {
        item.liveStartTime = null;
      }
    } catch (e) {
      Log.logPrint(e);
      if (e is CoreError && e.statusCode == 444) {
        // 抖音风控：停止本轮后续抖音请求，由用户手动刷新解除
        item.liveStatus.value = 0;
        item.liveStartTime = null;
        douyinBlocked = true;
        if (generation == _runGeneration) {
          _settleItem(item, changed: previous != 0);
        }
        return true;
      }
      _applyTransientFailure(item);
      return false;
    }
    if (generation != _runGeneration) {
      return true;
    }
    _settleItem(item, changed: item.liveStatus.value != previous);
    return true;
  }

  /// 抖音直播状态统一走 guard（服务端缓存 room_id、无进场副作用）：登录用户
  /// 带账号查，游客走匿名；guard 未配置时由 directFallback 走 core 内置取页
  @visibleForTesting
  Future<bool> resolveDouyinLiving({
    required String webRid,
    required Future<bool> Function() directFallback,
  }) async {
    if (!Get.isRegistered<GuardServerService>()) return directFallback();
    final guard = GuardServerService.instance;
    if (!guard.configured) return directFallback();
    // 登录返回账号 id；游客返回 null，服务端走匿名（拉黑房自动游客复核）
    final accountId = await guard.ensureAccount("douyin");
    try {
      final data = await guard.getLiveStatus(
        accountId: accountId,
        webRid: webRid,
      );
      return data["living"] == true;
    } on DioException catch (e) {
      // 服务端重建后旧 accountId 失效：重新注册并重试一次
      if (e.response?.statusCode != 404) rethrow;
      final newId = await guard.reregister("douyin");
      if (newId == null || newId == accountId) rethrow;
      final data = await guard.getLiveStatus(
        accountId: newId,
        webRid: webRid,
      );
      return data["living"] == true;
    }
  }

  /// 非抖音平台状态更新：并发执行，失败保留旧状态并安排一次性重试
  Future updateOtherStatus(FollowUser item,
      {required int generation}) async {
    final previous = item.liveStatus.value;
    try {
      var site = Sites.allSites[item.siteId]!;
      var isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      item.liveStatus.value = isLiving ? 2 : 1;
      if (isLiving) {
        var detail = await site.liveSite.getRoomDetail(roomId: item.roomId);
        item.liveStartTime = detail.showTime;
      } else {
        item.liveStartTime = null;
      }
    } catch (e) {
      Log.logPrint(e);
      if (e is CoreError && e.statusCode == 444) {
        item.liveStatus.value = 0;
        item.liveStartTime = null;
      } else {
        // 查询失败：保留上轮状态与位置，等待重试
        _applyTransientFailure(item);
        _scheduleRetry(item, generation, e);
      }
    }
    // 新一轮刷新已开始，本轮结果作废
    if (generation != _runGeneration) {
      return;
    }
    _settleItem(item, changed: item.liveStatus.value != previous);
  }

  /// 单个结果落定：仅在状态真实变化时安排刷新，一轮全部结束立即刷新一次
  void _settleItem(FollowUser item, {required bool changed}) {
    _settledIds.add(item.id);
    updatedCount = _settledIds.length;
    if (changed) {
      hasStatusChanged = true;
    }
    if (_settledIds.length >= followList.length) {
      _finishRound();
    } else if (changed) {
      _scheduleListNotify();
    }
  }

  @visibleForTesting
  void settleItemForTesting(FollowUser item, {bool changed = false}) {
    _settleItem(item, changed: changed);
  }

  void _scheduleListNotify() {
    listNotifyTimer?.cancel();
    listNotifyTimer = Timer(
      const Duration(milliseconds: listNotifyDebounceMs),
      filterData,
    );
  }

  void _finishRound() {
    if (hasStatusChanged) {
      // 本轮结束立即刷新，不再等防抖窗口
      listNotifyTimer?.cancel();
      listNotifyTimer = null;
      filterData();
    }
    updating.value = false;
  }

  /// 查询失败：已有上轮状态则保留旧状态与开播时间、不挪位置；
  /// 首次查询（仍为未知 0）保持 0 并清空开播时间
  void _applyTransientFailure(FollowUser item) {
    if (item.liveStatus.value == 0) {
      item.liveStartTime = null;
    }
  }

  @visibleForTesting
  void applyTransientFailureForTesting(FollowUser item) {
    _applyTransientFailure(item);
  }

  /// 可确定为永久失败的错误不重试
  bool _isPermanentFailure(Object e) {
    var text = e.toString();
    return text.contains("不存在") ||
        text.contains("未找到") ||
        text.contains("已下架") ||
        text.contains("已删除");
  }

  void _scheduleRetry(FollowUser item, int generation, Object error) {
    if (generation != _runGeneration || _isPermanentFailure(error)) {
      return;
    }
    late Timer timer;
    timer = Timer(const Duration(seconds: _retryDelaySeconds), () {
      _retryTimers.remove(timer);
      if (generation != _runGeneration ||
          douyinBlocked ||
          !followList.any((e) => e.id == item.id)) {
        return;
      }
      Log.logPrint("$_retryDelaySeconds秒后重试更新:${item.userName}");
      updateOtherStatus(item, generation: generation);
    });
    _retryTimers.add(timer);
  }

  void filterData() {
    followList.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    liveList.assignAll(followList.where((x) => x.liveStatus.value == 2));
    notLiveList.assignAll(followList.where((x) => x.liveStatus.value == 1));
    _updatedListController.add(0);
  }

  void exportFile() async {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }

    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }

      var dir = "";
      if (Platform.isIOS) {
        dir = (await getApplicationDocumentsDirectory()).path;
      } else {
        dir = await FilePicker.platform.getDirectoryPath() ?? "";
      }

      if (dir.isEmpty) {
        return;
      }
      var jsonFile = File(
          '$dir/SimpleLive_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
      var jsonText = generateJson();
      await jsonFile.writeAsString(jsonText);
      SmartDialog.showToast("已导出关注列表");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  void inputFile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("无权限");
        return;
      }
      var file = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (file == null) {
        return;
      }
      var jsonFile = File(file.files.single.path!);
      await inputJson(await jsonFile.readAsString());
      SmartDialog.showToast("导入成功");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败:$e");
    } finally {
      loadData();
    }
  }

  void exportText() {
    if (followList.isEmpty) {
      SmartDialog.showToast("列表为空");
      return;
    }
    var content = generateJson();
    Get.dialog(
      AlertDialog(
        title: const Text("导出为文本"),
        content: TextField(
          controller: TextEditingController(text: content),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () {
              Utils.copyToClipboard(content);
              Get.back();
            },
            child: const Text("复制"),
          ),
        ],
      ),
    );
  }

  void inputText() async {
    final TextEditingController textController = TextEditingController();
    await Get.dialog(
      AlertDialog(
        title: const Text("从文本导入"),
        content: TextField(
          controller: textController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: "请输入内容",
          ),
          minLines: 5,
          maxLines: 8,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Get.back();
            },
            child: const Text("关闭"),
          ),
          TextButton(
            onPressed: () async {
              var content = await Utils.getClipboard();
              if (content != null) {
                textController.text = content;
              }
            },
            child: const Text("粘贴"),
          ),
          TextButton(
            onPressed: () async {
              if (textController.text.isEmpty) {
                SmartDialog.showToast("内容为空");
                return;
              }
              try {
                await inputJson(textController.text);
                SmartDialog.showToast("导入成功");
                Get.back();
                loadData();
              } catch (e) {
                SmartDialog.showToast("导入失败，请检查内容是否正确");
              }
            },
            child: const Text("导入"),
          ),
        ],
      ),
    );
  }

  String generateJson() {
    var data = followList
        .map(
          (item) => {
            "siteId": item.siteId,
            "id": item.id,
            "roomId": item.roomId,
            "userName": item.userName,
            "face": item.face,
            "addTime": item.addTime.toString(),
            "tag": item.tag,
            "shareUrl": item.shareUrl
          },
        )
        .toList();
    return jsonEncode(data);
  }

  Future inputJson(String content) async {
    var data = jsonDecode(content);

    for (var item in data) {
      var follow = FollowUser.fromJson(item);
      // 导入关注列表同时导入标签列表 此方法可优化为所有导入逻辑
      if (follow.tag != "全部") {
        // logic: 尝试添加，存在则返回已存在的对象
        var tag = await DBService.instance.addFollowTag(follow.tag);
        // 更新tag
        tag.userId.addIf(!tag.userId.contains(follow.id), follow.id);
        await DBService.instance.updateFollowTag(tag);
      }
      await DBService.instance.addFollow(follow);
    }
  }
}
