import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:share_plus/share_plus.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/player/playback_watchdog.dart';
import 'package:simple_live_app/modules/live_room/player/player_controller.dart';
import 'package:simple_live_app/modules/settings/danmu_settings_page.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/background_audio_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_app/services/windows_ime_watchdog.dart';
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:simple_live_app/modules//sync/local_sync/local_sync_controller.dart';

/// 抖音房间在场状态：游客 / 进入中 / 账号已进入
enum RoomPresence { guest, entering, account }

class LiveRoomController extends PlayerController with WidgetsBindingObserver {
  final syncController = LocalSyncController("localhost");

  final Site pSite;
  final String pRoomId;
  final String pShareUrl;
  late LiveDanmaku liveDanmaku;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    required this.pShareUrl,
  }) {
    rxSite = pSite.obs;
    rxRoomId = pRoomId.obs;
    rxShareUrl = pShareUrl.obs;
    hydrateShareUrlFromFollow();
    liveDanmaku = site.liveSite.getDanmaku();
    // 抖音应该默认是竖屏的
    if (site.id == "douyin") {
      isVertical.value = true;
    }
  }

  late Rx<Site> rxSite;
  Site get site => rxSite.value;
  late Rx<String> rxRoomId;
  String get roomId => rxRoomId.value;
  late Rx<String> rxShareUrl;
  String get shareUrl => rxShareUrl.value;

  void hydrateShareUrlFromFollow() {
    if (shareUrl.isNotEmpty) {
      return;
    }
    var follow = DBService.instance.followBox.get("${site.id}_$roomId");
    if (follow != null && follow.shareUrl.isNotEmpty) {
      rxShareUrl.value = follow.shareUrl;
    }
  }

  Rx<LiveRoomDetail?> detail = Rx<LiveRoomDetail?>(null);
  var online = 0.obs;
  var followed = false.obs;
  var liveStatus = false.obs;
  RxList<LiveSuperChatMessage> superChats = RxList<LiveSuperChatMessage>();

  /// 滚动控制
  final ScrollController scrollController = ScrollController();

  /// 聊天信息
  RxList<LiveMessage> messages = RxList<LiveMessage>();

  /// 弹幕发送中
  var sendingDanmaku = false.obs;

  /// 清晰度数据
  RxList<LivePlayQuality> qualites = RxList<LivePlayQuality>();

  /// 当前清晰度
  var currentQuality = -1;
  var currentQualityInfo = "".obs;

  /// 线路数据
  RxList<String> playUrls = RxList<String>();

  Map<String, String>? playHeaders;

  /// 当前线路
  var currentLineIndex = -1;
  var currentLineInfo = "".obs;

  /// 退出倒计时
  var countdown = 60.obs;

  Timer? autoExitTimer;

  /// 设置的自动关闭时间（分钟）
  var autoExitMinutes = 60.obs;

  ///是否延迟自动关闭
  var delayAutoExit = false.obs;

  /// 是否启用自动关闭
  var autoExitEnable = false.obs;

  /// 是否禁用自动滚动聊天栏
  /// - 当用户向上滚动聊天栏时，不再自动滚动
  var disableAutoScroll = false.obs;

  /// 是否处于后台
  var isBackground = false;

  /// 直播间加载失败
  var loadError = false.obs;
  Object? error;

  // 开播时长状态变量
  var liveDuration = "00:00:00".obs;
  Timer? _liveDurationTimer;
  // guard 心跳：观看期间每 20s 续租，服务端租约超时才退房
  Timer? _guardHeartbeatTimer;

  /// 抖音房间在场状态；bili/huya 保持原自动进入行为，不使用此状态
  final presence = RoomPresence.guest.obs;

  /// 进行中的进入流程，并发调用复用同一 Future
  Future<bool>? _enteringFuture;

  @visibleForTesting
  void stopGuardHeartbeatForTesting() => _stopGuardHeartbeat();

  /// 播放卡死兜底看门狗：播放位置长时间不推进（libmpv 对死流有时仍停在
  /// playing 状态、不抛 error/completed）时，按播放失败处理。生效条件不含
  /// playing——恢复期 playing=false 时仍需检测，否则会永久静默成死局。
  late final PlaybackWatchdog _playbackWatchdog = PlaybackWatchdog(
    timeout: bufferingWatchdogTimeout,
    isActive: () => !isBackground && liveStatus.value,
    position: () => player.state.position,
    onTimeout: () => mediaError("播放卡死"),
  );

  /// 缓冲超时阈值（测试可调短）
  @visibleForTesting
  Duration bufferingWatchdogTimeout = const Duration(seconds: 15);

  void initPlaybackWatchdog() {
    _playbackWatchdog.start();
  }

  @override
  void onInit() {
    WidgetsBinding.instance.addObserver(this);
    initPlaybackWatchdog();
    if (FollowService.instance.followList.isEmpty) {
      FollowService.instance.loadData();
    }
    initAutoExit();
    showDanmakuState.value = AppSettingsController.instance.danmuEnable.value;
    followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
    loadData();

    scrollController.addListener(scrollListener);
    //设置音量
    var id = "${site.id}_$roomId";
    var volumeVal = DBService.instance.getVolume(id);
    double volume = volumeVal!.toDouble();
    player.setVolume(volume);

    BackgroundAudioService.instance.setStopRequestedHandler(() async {
      _audioServiceActive = false;
      BackgroundAudioService.instance.markStopped();
      await player.pause();
    });

    super.onInit();
  }

  void scrollListener() {
    if (scrollController.position.userScrollDirection ==
        ScrollDirection.forward) {
      disableAutoScroll.value = true;
    }
  }

  /// 初始化自动关闭倒计时
  void initAutoExit() {
    if (AppSettingsController.instance.autoExitEnable.value) {
      autoExitEnable.value = true;
      autoExitMinutes.value =
          AppSettingsController.instance.autoExitDuration.value;
      setAutoExit();
    } else {
      autoExitMinutes.value =
          AppSettingsController.instance.roomAutoExitDuration.value;
    }
  }

  void setAutoExit() {
    if (!autoExitEnable.value) {
      autoExitTimer?.cancel();
      return;
    }
    autoExitTimer?.cancel();
    countdown.value = autoExitMinutes.value * 60;
    autoExitTimer = Timer.periodic(const Duration(seconds: 1), (timer) async {
      countdown.value -= 1;
      if (countdown.value <= 0) {
        timer = Timer(const Duration(seconds: 10), () async {
          await WakelockPlus.disable();
          exit(0);
        });
        autoExitTimer?.cancel();
        var delay = await Utils.showAlertDialog("定时关闭已到时,是否延迟关闭?",
            title: "延迟关闭", confirm: "延迟", cancel: "关闭", selectable: true);
        if (delay) {
          timer.cancel();
          delayAutoExit.value = true;
          showAutoExitSheet();
          setAutoExit();
        } else {
          delayAutoExit.value = false;
          await WakelockPlus.disable();
          exit(0);
        }
      }
    });
  }
  // 弹窗逻辑

  void refreshRoom() {
    // 账号态刷新即退房回游客：best-effort 退出（在 loadData 换详情前发起）
    if (site.id == Constant.kDouyin && presence.value == RoomPresence.account) {
      unawaited(_exitGuardRoom());
    }
    //messages.clear();
    superChats.clear();
    liveDanmaku.stop();
    _danmakuSuspended = false;
    presence.value = RoomPresence.guest;

    guestVerifyReplays = 0;
    loadData();
  }

  /// 聊天栏始终滚动到底部
  void chatScrollToBottom() {
    if (scrollController.hasClients) {
      // 如果手动上拉过，就不自动滚动到底部
      if (disableAutoScroll.value) {
        return;
      }
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  /// 是否可以启动弹幕：抖音 SSR 骨架占位房间（roomId 为空）无法建立弹幕连接
  static bool canStartDanmaku(LiveRoomDetail? detail) {
    final args = detail?.danmakuData;
    return !(args is DouyinDanmakuArgs && args.roomId.isEmpty);
  }

  /// 初始化弹幕接收事件
  void initDanmau() {
    liveDanmaku.onMessage = onWSMessage;
    liveDanmaku.onClose = onWSClose;
    liveDanmaku.onReady = onWSReady;
  }

  /// 签名服务附加参数：虎牙需要 ayyuid/topSid/subSid
  Map<String, dynamic> _guardExtraArgs() {
    final data = detail.value?.danmakuData;
    if (data is HuyaDanmakuArgs) {
      return {
        "ayyuid": data.ayyuid,
        "topSid": data.topSid,
        "subSid": data.subSid,
        "roomShortId": roomId,
      };
    }
    return {};
  }

  /// 签名服务抖音 webRid（URL 短号）
  String get _guardWebRid {
    final data = detail.value?.danmakuData;
    return data is DouyinDanmakuArgs ? data.webRid : "";
  }

  /// 签名服务房间号：B站 int 房间号、抖音 String 房间 id，其余兜底详情/控制器房间号
  String get _guardRoomId {
    final data = detail.value?.danmakuData;
    if (data is BiliBiliDanmakuArgs) return data.roomId.toString();
    if (data is DouyinDanmakuArgs) return data.roomId;
    return detail.value?.roomId ?? roomId;
  }

  static const _guardPlatforms = ["douyin", "bilibili", "huya"];

  /// bili/huya：进入直播间时让服务端页面进入对应房间（仅已登录、已配置时）。
  /// 抖音默认游客，显式点「进入直播间」时才走 _requestGuardEnter
  Future<void> _enterGuardRoom() async {
    if (site.id == Constant.kDouyin) return;
    final guard = GuardServerService.instance;
    if (!guard.configured || !_guardPlatforms.contains(site.id)) return;
    if (!danmakuLogined) return;
    try {
      var accountId = await guard.ensureAccount(site.id);
      if (accountId == null) return;
      try {
        _applyGuardStatus(
          await guard.enterRoom(
            accountId: accountId,
            roomId: _guardRoomId,
            webRid: _guardWebRid,
            extra: _guardExtraArgs(),
          ),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) rethrow;
        // 服务端会话丢失：重新注册后再进一次
        accountId = await guard.reregister(site.id);
        if (accountId == null) return;
        _applyGuardStatus(
          await guard.enterRoom(
            accountId: accountId,
            roomId: _guardRoomId,
            webRid: _guardWebRid,
            extra: _guardExtraArgs(),
          ),
        );
      }
      _startGuardHeartbeat(accountId);
    } catch (e) {
      Log.logPrint("弹幕服务进入直播间失败: $e");
    }
  }

  /// 抖音显式进入：guard 真实进场，含 404 重新注册重试。
  /// 返回账号与进场状态；未配置/失败返回 null
  Future<({String accountId, Map<String, dynamic> status})?>
      _requestGuardEnter() async {
    final guard = GuardServerService.instance;
    if (!guard.configured) return null;
    var accountId = await guard.ensureAccount(site.id);
    if (accountId == null) return null;
    try {
      final status = await guard.enterRoom(
        accountId: accountId,
        roomId: _guardRoomId,
        webRid: _guardWebRid,
        extra: _guardExtraArgs(),
      );
      return (accountId: accountId, status: status);
    } on DioException catch (e) {
      if (e.response?.statusCode != 404) rethrow;
      final newId = await guard.reregister(site.id);
      if (newId == null) return null;
      final status = await guard.enterRoom(
        accountId: newId,
        roomId: _guardRoomId,
        webRid: _guardWebRid,
        extra: _guardExtraArgs(),
      );
      return (accountId: newId, status: status);
    }
  }

  /// 以账号身份真实进入抖音直播间；播放器不动，游客播放/弹幕失败时零改动
  Future<bool> enterAsAccount() async {
    if (presence.value == RoomPresence.account) return true;
    final inFlight = _enteringFuture;
    if (inFlight != null) return inFlight;
    if (!danmakuLogined) {
      await showDanmakuLoginDialog();
      return false;
    }
    final future = _doEnterAsAccount();
    _enteringFuture = future;
    try {
      return await future;
    } finally {
      _enteringFuture = null;
    }
  }

  /// 抖音写动作（发弹幕/点赞/灯牌/入团）前确保账号在场
  Future<bool> ensureAccountPresence() async {
    if (site.id != Constant.kDouyin) return true;
    if (presence.value == RoomPresence.account) return true;
    return enterAsAccount();
  }

  Future<bool> _doEnterAsAccount() async {
    final liveSite = site.liveSite;
    if (liveSite is! DouyinSite) return false;
    presence.value = RoomPresence.entering;
    // 不用全屏模态 loading：左上角「进入直播间」按钮在 entering 态自会转圈
    // 反馈，画面继续播放、交互不被锁定
    final LiveRoomDetail accountDetail;
    try {
      accountDetail = await liveSite.getRoomDetail(
        roomId: "$roomId;$shareUrl",
        asAccount: true,
      );
    } catch (e) {
      SmartDialog.showToast("无法以账号身份读取该房间（可能被主播限制）");
      presence.value = RoomPresence.guest;
      return false;
    }

    final ({String accountId, Map<String, dynamic> status})? entered;
    try {
      entered = await _requestGuardEnter();
    } catch (e) {
      SmartDialog.showToast("进入直播间失败，已保持游客观看");
      presence.value = RoomPresence.guest;
      return false;
    }
    if (entered == null) {
      SmartDialog.showToast("进入直播间失败，已保持游客观看");
      presence.value = RoomPresence.guest;
      return false;
    }

    // 账号进场成功后才动弹幕：游客弹幕此刻停止，按账号身份重连
    await liveDanmaku.stop();
    detail.value = accountDetail;
    online.value = accountDetail.online;
    liveStatus.value = accountDetail.status || accountDetail.isRecord;
    initDanmau();
    await liveDanmaku.start(accountDetail.danmakuData);

    _applyGuardStatus(entered.status);
    _startGuardHeartbeat(entered.accountId);
    presence.value = RoomPresence.account;
    addSysMsg("已进入直播间");
    return true;
  }

  void _startGuardHeartbeat(String accountId) {
    _guardHeartbeatTimer?.cancel();
    final guard = GuardServerService.instance;

    Future<void> beat({bool retried = false}) async {
      try {
        final data = await guard.heartbeat(
          accountId: accountId,
          roomId: _guardRoomId,
          webRid: _guardWebRid,
          extra: _guardExtraArgs(),
        );
        if (data["inRoom"] != true) {
          // 同账号已在其他端进入别的直播间：本端退让停止心跳，
          // 避免互相踢；等用户在本端主动发弹幕时再抢占
          _stopGuardHeartbeat();
          return;
        }
      } on DioException catch (e) {
        if (!retried && e.response?.statusCode == 404) {
          // 服务端会话丢失：重新注册并用新账号重启心跳
          final newId = await guard.reregister(site.id);
          if (newId != null) {
            _startGuardHeartbeat(newId);
            return;
          }
        }
        Log.logPrint("弹幕服务心跳失败: ${e.message}");
      }
    }

    _guardHeartbeatTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => beat(),
    );
  }

  void _stopGuardHeartbeat() {
    _guardHeartbeatTimer?.cancel();
    _guardHeartbeatTimer = null;
  }

  /// 退出直播间时让服务端页面回到首页；best-effort，失败只记日志
  Future<void> _exitGuardRoom() async {
    _stopGuardHeartbeat();
    guardJoined.value = false;
    guardStarRoom.value = false;
    // 抖音游客态：账号从未真实进场，不发 exit
    if (site.id == Constant.kDouyin && presence.value != RoomPresence.account) {
      return;
    }
    if (!canStartDanmaku(detail.value)) return;
    final guard = GuardServerService.instance;
    if (!guard.configured || !_guardPlatforms.contains(site.id)) return;
    final accountId = guard.savedAccountId(site.id);
    if (accountId == null) return;
    try {
      await guard.exitRoom(
        accountId: accountId,
        roomId: _guardRoomId,
        webRid: _guardWebRid,
        extra: _guardExtraArgs(),
      );
    } catch (e) {
      Log.logPrint("弹幕服务退出直播间失败: $e");
    }
  }

  Future<void> sendDanmaku(String text) async {
    var content = text.trim();
    if (content.isEmpty) {
      return;
    }
    if (content.length > 200) {
      SmartDialog.showToast("弹幕内容过长（最多200字）");
      return;
    }
    // 抖音游客态：先以账号进入，进入被拒/取消则不发
    if (site.id == Constant.kDouyin) {
      final entered = await ensureAccountPresence();
      if (!entered) return;
    }
    sendingDanmaku.value = true;
    try {
      DanmakuSendResult result;
      final guard = GuardServerService.instance;

      String? accountId;
      if (guard.configured && _guardPlatforms.contains(site.id)) {
        // 发送时按需注册：未注册则用本地保存的登录 cookie 自动注册
        accountId = await guard.ensureAccount(site.id);
      }

      if (accountId != null) {
        Future<DanmakuSendResult> sendOnce(String id,
            {bool retried = false}) async {
          try {
            final data = await guard.sendDanmaku(
              platform: site.id,
              accountId: id,
              roomId: _guardRoomId,
              webRid: _guardWebRid,
              content: content,
              extra: _guardExtraArgs(),
            );
            return DanmakuSendResult(
              success: data["success"] == true,
              errorCode: data["platformCode"] != null
                  ? data["platformCode"].toString()
                  : "guard",
              errorMessage: data["message"]?.toString() ?? "",
            );
          } on DioException catch (e) {
            if (e.response?.statusCode == 404 && !retried) {
              // 服务端会话丢失（如容器重启）：accountId 由 cookie 哈希决定，
              // 重新注册得到的 ID 与原 ID 相同，故不能比较 ID，注册成功即重试一次
              final newId = await guard.reregister(site.id);
              if (newId != null) {
                return sendOnce(newId, retried: true);
              }
            }
            final data = e.response?.data;
            final msg = data is Map ? data["message"] : null;
            return DanmakuSendResult(
              success: false,
              errorCode: "guard",
              errorMessage: msg is String && msg.isNotEmpty ? msg : "网络请求失败",
            );
          }
        }

        result = await sendOnce(accountId);
        if (result.success) {
          // 主动发送已在服务端抢占房间，恢复本端心跳保活
          _startGuardHeartbeat(accountId);
        }
      } else {
        result = await liveDanmaku.sendMessage(content);
      }
      if (!result.success) {
        SmartDialog.showToast(
          danmakuErrorText(site.id, result),
        );
      }
    } catch (e) {
      // core 侧异常（如对已关闭 sink.add 抛 StateError）兜底，避免无反馈
      Log.logPrint("发送弹幕异常: $e");
      SmartDialog.showToast(
        danmakuErrorText(
          site.id,
          DanmakuSendResult(success: false, errorCode: "network_error"),
        ),
      );
    } finally {
      sendingDanmaku.value = false;
    }
  }

  /// 点赞/送灯牌是否可用：仅抖音、B站，且已配置签名服务并登录
  bool get guardActionEnabled =>
      GuardServerService.instance.configured &&
      (site.id == "douyin" || site.id == "bilibili") &&
      danmakuLogined;

  final sendingAction = false.obs;

  // enter 返回的房间状态：已加入粉丝团 / 星守护房间 / 勋章当前点亮
  final guardJoined = false.obs;
  final guardStarRoom = false.obs;
  final guardBadgeActive = false.obs;

  void _applyGuardStatus(Map<String, dynamic> status) {
    guardJoined.value = status["joined"] == true;
    guardStarRoom.value = status["starGuard"] == true;
    guardBadgeActive.value = status["badgeActive"] == true;
  }

  Future<void> _sendGuardAction(String action) async {
    if (sendingAction.value) return;
    // 抖音游客态：先以账号进入（点赞/灯牌/入团确认之后），失败则不执行
    if (site.id == Constant.kDouyin) {
      final entered = await ensureAccountPresence();
      if (!entered) return;
    }
    final guard = GuardServerService.instance;
    sendingAction.value = true;
    try {
      var accountId = await guard.ensureAccount(site.id);
      if (accountId == null) {
        SmartDialog.showToast("请先登录并配置弹幕签名服务");
        return;
      }

      Future<Map<String, dynamic>> runOnce(String id,
          {bool retried = false}) async {
        try {
          return await guard.sendAction(
            accountId: id,
            roomId: _guardRoomId,
            webRid: _guardWebRid,
            action: action,
          );
        } on DioException catch (e) {
          if (e.response?.statusCode == 404 && !retried) {
            final newId = await guard.reregister(site.id);
            if (newId != null) return runOnce(newId, retried: true);
          }
          rethrow;
        }
      }

      final data = await runOnce(accountId);
      if (data["success"] != true) {
        SmartDialog.showToast(data["message"]?.toString() ?? "操作失败");
      } else {
        if (action == "join_club") {
          guardJoined.value = true;
          guardBadgeActive.value = true;
        }
        if (action == "light_up") guardBadgeActive.value = true;
        // 主动操作已在服务端抢占房间，恢复本端心跳保活
        _startGuardHeartbeat(accountId);
      }
    } on DioException catch (e) {
      final data = e.response?.data;
      final msg = data is Map ? data["message"] : null;
      SmartDialog.showToast(
        msg is String && msg.isNotEmpty ? msg : "网络请求失败",
      );
    } catch (e) {
      Log.logPrint("直播间互动操作异常: $e");
      SmartDialog.showToast("操作失败，请稍后重试");
    } finally {
      sendingAction.value = false;
    }
  }

  Future<void> like() => _sendGuardAction("like");

  Future<void> sendFansBadge() async {
    // 灯牌为粉丝团成员专属：未入团先入团；团还在但勋章已熄灭先点亮
    if (site.id == "douyin") {
      if (!guardJoined.value) {
        SmartDialog.showToast("请先加入主播的粉丝团");
        await joinFansClub();
        return;
      }
      if (!guardBadgeActive.value) {
        SmartDialog.showToast("粉丝团勋章已熄灭，请先点亮");
        await lightUpFansBadge();
        return;
      }
    }

    final isStarRoom = site.id == "douyin" && guardStarRoom.value;
    final priceText = site.id == "douyin"
        ? (isStarRoom ? "星守护房间将送出点点星光（8 抖币）" : "送出粉丝团灯牌（1 抖币）")
        : "免费";
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: Text(isStarRoom ? "送出点点星光" : "送出粉丝团灯牌"),
        content: Text("$priceText，确认送给主播吗？"),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text("送出"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _sendGuardAction("fans_badge");
    }
  }

  Future<void> joinFansClub() async {
    // 成员关系仍在时不能再调入团接口：勋章活跃 → 无需重复；已熄灭 → 引导点亮
    if (guardJoined.value) {
      if (guardBadgeActive.value) {
        SmartDialog.showToast("你已经加入该主播的粉丝团，无需重复加入");
        return;
      }
      SmartDialog.showToast("粉丝团勋章已熄灭，需重新点亮");
      await lightUpFansBadge();
      return;
    }
    final contentText = site.id == "douyin"
        ? "将消耗 1 抖币，确认加入主播的粉丝团吗？"
        : "将消耗 100 金瓜子（1 电池）购买粉丝团灯牌，确认加入主播的粉丝团吗？";
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text("加入粉丝团"),
        content: Text(contentText),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text("加入"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _sendGuardAction("join_club");
    }
  }

  Future<void> lightUpFansBadge() async {
    final confirmed = await Get.dialog<bool>(
      AlertDialog(
        title: const Text("点亮粉丝团勋章"),
        content: const Text("将消耗 1 抖币送出点亮礼物，重新点亮粉丝团勋章，确认吗？"),
        actions: [
          TextButton(
            onPressed: () => Get.back(result: false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text("点亮"),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _sendGuardAction("light_up");
    }
  }

  @override
  void handleKeyboardKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        fullScreenState.value &&
        !lockControlsState.value &&
        !smallWindowState.value &&
        (event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
      showDanmakuInputDialog();
      return;
    }
    super.handleKeyboardKey(event);
  }

  /// 弹幕输入对话框；全屏键盘回车与控制栏按钮共用
  Future<void> showDanmakuInputDialog() async {
    if (!danmakuLogined) {
      await showDanmakuLoginDialog();
      playerFocusNode.requestFocus();
      return;
    }
    var text = await _showBottomDanmakuInput();
    playerFocusNode.requestFocus();
    if (text == null || text.trim().isEmpty) {
      return;
    }
    await sendDanmaku(text);
  }

  /// 底部弹幕输入框：宽度略窄于画面，回车发送、Esc 取消
  Future<String?> _showBottomDanmakuInput() {
    final textController = TextEditingController();
    final keyFocusNode = FocusNode();
    return Get.dialog<String>(
      barrierColor: Colors.black26,
      KeyboardListener(
        focusNode: keyFocusNode,
        onKeyEvent: (event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Get.back();
          }
        },
        child: Align(
          alignment: Alignment.bottomCenter,
          child: FractionallySizedBox(
            widthFactor: 0.86,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 36),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xCC000000),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: TextField(
                    autofocus: true,
                    controller: textController,
                    maxLength: 200,
                    style: const TextStyle(color: Colors.white),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (v) => Get.back(result: v),
                    decoration: const InputDecoration(
                      isCollapsed: true,
                      counterText: "",
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(vertical: 14),
                      hintText: "发个弹幕呗…",
                      hintStyle: TextStyle(color: Colors.white38),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 当前平台账号是否已登录；竖屏底部栏与全屏弹框入口同源
  bool get danmakuLogined {
    switch (site.id) {
      case Constant.kBiliBili:
        return BiliBiliAccountService.instance.logined.value;
      case Constant.kDouyu:
        return DouyuAccountService.instance.logined.value;
      case Constant.kHuya:
        return HuyaAccountService.instance.logined.value;
      case Constant.kDouyin:
        return DouyinAccountService.instance.logined.value;
      case Constant.kTwitch:
        return TwitchAccountService.instance.configured.value;
      default:
        return false;
    }
  }

  /// 未登录时弹确认框，确认后前往账号管理
  Future<void> showDanmakuLoginDialog() async {
    var result = await Utils.showAlertDialog(
      "登录后才能发送弹幕，是否前往账号管理？",
      title: "未登录",
    );
    if (result) {
      Get.toNamed(RoutePath.kSettingsAccount);
    }
  }

  static String danmakuErrorText(String platform, DanmakuSendResult result) {
    var code = result.errorCode;
    if (code == "not_login") {
      return "未登录，请先在账号管理中登录";
    }
    if (code == "rate_limit") {
      return "发言太快，请稍后再试";
    }
    if (code == "network_error" || code == "timeout") {
      return "网络异常，请稍后再试";
    }
    if (platform == Constant.kBiliBili) {
      switch (code) {
        case "1":
        case "13":
          return "你已被禁言";
        case "3":
          return "房间已锁定，无法发言";
        case "11":
          return "发言太快，请稍后再试";
        case "12":
          return "弹幕内容过长";
        case "14":
          return "该房间仅粉丝团可发言";
        case "15":
          return "需要绑定手机后才能发言";
      }
    }
    if (platform == Constant.kDouyin) {
      switch (code) {
        case "8":
          return "未登录或登录已失效";
        case "9":
          return "账号已被封禁";
        case "50001":
          return "你已被禁言";
        case "50004":
          return "内容包含敏感词";
        case "50008":
          return "当前账号发言受限";
        case "3009008":
          return "发言太快，请稍后再试";
      }
    }
    if (platform == Constant.kDouyu) {
      if (code == "muted") {
        return "你已被禁言";
      }
    }
    if (platform == Constant.kHuya) {
      if (code != "0") {
        return result.errorMessage.isNotEmpty ? result.errorMessage : "弹幕发送失败";
      }
    }
    return result.errorMessage.isNotEmpty ? result.errorMessage : "弹幕发送失败";
  }

  /// 接收到WebSocket信息
  void onWSMessage(LiveMessage msg) {
    if (msg.type == LiveMessageType.chat) {
      if (messages.length > 200 && !disableAutoScroll.value) {
        messages.removeAt(0);
      }

      // 关键词屏蔽检查（自己的消息不屏蔽）
      if (!msg.isSelf) {
        for (var keyword in AppSettingsController.instance.shieldList) {
          Pattern? pattern;
          if (Utils.isRegexFormat(keyword)) {
            String removedSlash = Utils.removeRegexFormat(keyword);
            try {
              pattern = RegExp(removedSlash);
            } catch (e) {
              // should avoid this during add keyword
              Log.d("关键词：$keyword 正则格式错误");
            }
          } else {
            pattern = keyword;
          }
          if (pattern != null && msg.message.contains(pattern)) {
            Log.d("关键词：$keyword\n已屏蔽消息内容：${msg.message}");
            return;
          }
        }
      }

      messages.add(msg);

      WidgetsBinding.instance.addPostFrameCallback(
        (_) => chatScrollToBottom(),
      );
      if (!liveStatus.value || isBackground) {
        return;
      }

      addDanmaku([
        DanmakuContentItem(
          msg.message,
          color: Color.fromARGB(
            255,
            msg.color.r,
            msg.color.g,
            msg.color.b,
          ),
          selfSend: msg.isSelf,
        ),
      ]);
    } else if (msg.type == LiveMessageType.online) {
      online.value = msg.data;
    } else if (msg.type == LiveMessageType.superChat) {
      superChats.add(msg.data);
    }
  }

  /// 添加一条系统消息
  void addSysMsg(String msg) {
    messages.add(
      LiveMessage(
        type: LiveMessageType.chat,
        userName: "LiveSysMessage",
        message: msg,
        color: LiveMessageColor.white,
      ),
    );
  }

  /// 接收到WebSocket关闭信息
  void onWSClose(String msg) {
    addSysMsg(msg);
  }

  /// WebSocket准备就绪
  void onWSReady() {
    addSysMsg("弹幕服务器连接正常");
  }

  bool guestVerifyPrompting = false;
  int guestVerifyReplays = 0;

  /// 加载直播间信息
  void loadData() async {
    presence.value = RoomPresence.guest;
    try {
      SmartDialog.showLoading(msg: "");
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      hydrateShareUrlFromFollow();
      final liveSite = site.liveSite;
      if (liveSite is DouyinSite) {
        // 默认游客身份读取：不带 sessionid，不受房间黑名单影响
        detail.value = await liveSite.getRoomDetail(
          roomId: "$roomId;$shareUrl",
          asAccount: false,
        );
      } else {
        detail.value = await liveSite.getRoomDetail(roomId: roomId);
      }
      Log.logPrint("直播间信息读取完成 roomId=${detail.value?.roomId}");

      if (site.id == Constant.kDouyin) {
        // 1.6.0之前收藏的WebRid
        // 1.6.0收藏的RoomID
        // 1.6.0之后改回WebRid
        if (detail.value!.roomId != roomId) {
          var oldId = roomId;
          rxRoomId.value = detail.value!.roomId;
          rxShareUrl.value = shareUrl;
          if (followed.value) {
            // 更新关注列表
            DBService.instance.deleteFollow("${site.id}_$oldId");
            DBService.instance.addFollow(
              FollowUser(
                id: "${site.id}_${detail.value!.roomId}",
                roomId: detail.value!.roomId,
                siteId: site.id,
                userName: detail.value!.userName,
                face: detail.value!.userAvatar,
                addTime: DateTime.now(),
                shareUrl: shareUrl,
              ),
            );
          } else {
            followed.value =
                DBService.instance.getFollowExist("${site.id}_$roomId");
          }
        }
      }

      getSuperChatMessage();

      addHistory();
      // 确认房间关注状态
      followed.value = DBService.instance.getFollowExist("${site.id}_$roomId");
      online.value = detail.value!.online;
      liveStatus.value = detail.value!.status || detail.value!.isRecord;
      if (liveStatus.value) {
        getPlayQualites();
      }
      if (detail.value!.isRecord) {
        addSysMsg("当前主播未开播，正在轮播录像");
      }
      if (canStartDanmaku(detail.value)) {
        addSysMsg("开始连接弹幕服务器");
        initDanmau();
        liveDanmaku.start(detail.value?.danmakuData);
        unawaited(_enterGuardRoom());
      } else {
        addSysMsg("当前主播未开播，不连接弹幕服务器");
      }
      startLiveDurationTimer(); // 启动开播时长定时器
    } on DouyinGuestVerifyRequired catch (e) {
      Log.logPrint(e);
      if (guestVerifyReplays >= 1) {
        loadError.value = true;
        error = e;
        SmartDialog.showToast("验证未生效，请手动重试");
        return;
      }
      if (guestVerifyPrompting) return;
      guestVerifyPrompting = true;
      final result = await Get.toNamed<bool>(
        RoutePath.kDouyinGuestVerify,
        arguments: e.webRid,
      );
      guestVerifyPrompting = false;
      SmartDialog.dismiss(status: SmartStatus.loading);
      if (result == true && guestVerifyReplays < 1) {
        guestVerifyReplays++;
        loadData();
        return;
      }
      loadError.value = true;
      error = e;
    } catch (e) {
      Log.logPrint(e);
      loadError.value = true;
      error = e;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  /// 初始化播放器
  void getPlayQualites() async {
    qualites.clear();
    currentQuality = -1;

    try {
      var playQualites =
          await site.liveSite.getPlayQualites(detail: detail.value!);

      if (playQualites.isEmpty) {
        SmartDialog.showToast("无法读取播放清晰度");
        return;
      }
      Log.logPrint("播放清晰度读取完成 ${playQualites.length}个");
      qualites.value = playQualites;
      var qualityLevel = await getQualityLevel();
      if (qualityLevel == 2) {
        //最高
        currentQuality = 0;
      } else if (qualityLevel == 0) {
        //最低
        currentQuality = playQualites.length - 1;
      } else {
        //中间值
        int middle = (playQualites.length / 2).floor();
        currentQuality = middle;
      }

      getPlayUrl();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放清晰度");
    }
  }

  Future<int> getQualityLevel() async {
    var qualityLevel = AppSettingsController.instance.qualityLevel.value;
    try {
      var connectivityResult = await (Connectivity().checkConnectivity());
      if (connectivityResult == ConnectivityResult.mobile) {
        qualityLevel =
            AppSettingsController.instance.qualityLevelCellular.value;
      }
    } catch (e) {
      Log.logPrint(e);
    }
    return qualityLevel;
  }

  void getPlayUrl() async {
    playUrls.clear();
    currentQualityInfo.value = qualites[currentQuality].quality;
    currentLineInfo.value = "";
    currentLineIndex = -1;
    try {
      var playUrl = await site.liveSite
          .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
      if (playUrl.urls.isEmpty) {
        SmartDialog.showToast("无法读取播放地址");
        return;
      }
      playUrls.value = playUrl.urls;
      playHeaders = playUrl.headers;
      currentLineIndex = 0;
      currentLineInfo.value = "线路${currentLineIndex + 1}";
      //重置错误次数
      mediaErrorRetryCount = 0;
      initPlaylist();
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法读取播放地址");
    }
  }

  void changePlayLine(int index) {
    currentLineIndex = index;
    //重置错误次数
    mediaErrorRetryCount = 0;
    setPlayer();
  }

  Future<void> initPlaylist() async {
    currentLineInfo.value = "线路${currentLineIndex + 1}";
    errorMsg.value = "";

    final mediaList = playUrls.map((url) {
      var finalUrl = url;
      if (AppSettingsController.instance.playerForceHttps.value) {
        finalUrl = finalUrl.replaceAll("http://", "https://");
      }
      return Media(finalUrl, httpHeaders: playHeaders);
    }).toList();

    // 初始化播放器并设置 ao 参数
    await initializePlayer();

    await player.open(Playlist(mediaList, index: currentLineIndex));
    // 看门狗一次性触发后会自行 cancel，每次 open 新流后重新 arm（幂等）。
    _playbackWatchdog.start();

    // 后台状态下被重开（断线重试等）时，新流会自行播放，需重新应用后台策略
    if ((Platform.isAndroid || Platform.isIOS) && isBackground && !pipActive) {
      await onBackgroundPlaybackPolicyChanged();
    }
  }

  // 不能用 player.jump：jump 内部的 play() 在 EOF 时会先 seek，
  // 旧版 libmpv 在 EOF 状态 seek 会断言失败导致原生崩溃
  void setPlayer() {
    initPlaylist();
  }

  /// 弹幕连接是否因进入后台（非 PiP）被挂起
  bool _danmakuSuspended = false;

  /// 音频前台服务是否在运行
  bool _audioServiceActive = false;

  /// 关屏听声：Android 且设置开关已开启
  bool get _backgroundAudioEnabled =>
      Platform.isAndroid &&
      AppSettingsController.instance.backgroundAudioPlay.value;

  /// 前后台 / PiP 状态变化后的播放策略
  /// PiP：Activity 虽 paused，但视频必须继续，不暂停、不开音频服务
  /// 后台 + 开关：关视频轨、停弹幕，启动前台服务继续播放声音
  /// 后台 + 未开启：完全暂停
  @override
  Future<void> onBackgroundPlaybackPolicyChanged() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return;
    }
    if (pipActive) {
      return;
    }

    if (!isBackground) {
      if (_audioServiceActive) {
        _audioServiceActive = false;
        await BackgroundAudioService.instance.stop();
      }
      await (player.platform as NativePlayer).setProperty('vid', 'auto');
      await player.play();
      if (_danmakuSuspended) {
        _danmakuSuspended = false;
        final data = detail.value?.danmakuData;
        if (data != null) {
          unawaited(liveDanmaku.start(data));
        }
      }
    } else if (_backgroundAudioEnabled) {
      if (!_danmakuSuspended) {
        _danmakuSuspended = true;
        liveDanmaku.stop();
      }
      await (player.platform as NativePlayer).setProperty('vid', 'no');
      await player.play();
      if (!_audioServiceActive) {
        _audioServiceActive = true;
        await BackgroundAudioService.instance.start(
          title: detail.value?.title ?? "Simple Live",
          subtitle: detail.value?.userName ?? "",
        );
      }
    } else {
      if (!_danmakuSuspended) {
        _danmakuSuspended = true;
        liveDanmaku.stop();
      }
      await player.pause();
    }
  }

  Future<void> _stopAudioServiceIfActive() async {
    if (_audioServiceActive) {
      _audioServiceActive = false;
      await BackgroundAudioService.instance.stop();
    }
  }

  @override
  void mediaEnd() async {
    super.mediaEnd();
    if (site.id == Constant.kDouyu) {
      // 斗鱼地址 expire=300，CDN 每 5 分钟准点断流，旧地址立即作废，
      // 重放 / 切到同时签发的备用线路必然失败，直接重新签发。
      _recoverDouyuStream();
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放结束，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    Log.d("播放结束");
    // 遍历线路，如果全部链接都断开就是直播结束了
    if (playUrls.length - 1 == currentLineIndex) {
      liveStatus.value = false;
      unawaited(_stopAudioServiceIfActive());
    } else {
      changePlayLine(currentLineIndex + 1);

      //setPlayer();
    }
  }

  /// 斗鱼断流恢复是否正在进行
  bool _recovering = false;

  /// 上次恢复时间，10 秒内的重复 EOF/error 不重入
  DateTime? _lastStreamRecoverAt;

  /// 斗鱼 CDN 断流后重新签发播放地址。循环重试，失败后间隔退避，直到
  /// 成功、确认下播或页面关闭。恢复期间看门狗停止，新流 open 后重启。
  void _recoverDouyuStream() async {
    if (_recovering) {
      return;
    }
    final last = _lastStreamRecoverAt;
    if (last != null &&
        DateTime.now().difference(last) < const Duration(seconds: 10)) {
      return;
    }
    _recovering = true;
    _lastStreamRecoverAt = DateTime.now();
    _playbackWatchdog.cancel();

    addSysMsg("直播中断，正在重新连接");

    const maxAttempts = 8;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (attempt == 1) {
          final live = await site.liveSite.getLiveStatus(roomId: roomId);
          if (!live) {
            liveStatus.value = false;
            unawaited(_stopAudioServiceIfActive());
            _recovering = false;
            return;
          }
        }

        final playUrl = await site.liveSite.getPlayUrls(
            detail: detail.value!, quality: qualites[currentQuality]);
        if (playUrl.urls.isEmpty) {
          throw Exception("server returned empty urls");
        }
        playUrls.value = playUrl.urls;
        playHeaders = playUrl.headers;
        currentLineIndex = 0;
        mediaErrorRetryCount = 0;
        await initPlaylist();
        _recovering = false;
        return;
      } catch (e) {
        Log.logPrint(e);
        if (attempt < maxAttempts) {
          await Future.delayed(
              Duration(seconds: attempt < 3 ? 3 : 15));
        }
      }
    }

    _recovering = false;
    errorMsg.value = "播放失败，请手动刷新";
    SmartDialog.showToast("重连失败，请手动刷新");
  }

  int mediaErrorRetryCount = 0;
  @override
  void mediaError(String error) async {
    super.mediaEnd();
    if (site.id == Constant.kDouyu) {
      _recoverDouyuStream();
      return;
    }
    if (mediaErrorRetryCount < 2) {
      Log.d("播放失败，尝试第${mediaErrorRetryCount + 1}次刷新");
      if (mediaErrorRetryCount == 1) {
        //延迟一秒再刷新
        await Future.delayed(const Duration(seconds: 1));
      }
      mediaErrorRetryCount += 1;
      //刷新一次
      setPlayer();
      return;
    }

    if (playUrls.length - 1 == currentLineIndex) {
      errorMsg.value = "播放失败";
      SmartDialog.showToast("播放失败:$error");
      unawaited(_stopAudioServiceIfActive());
    } else {
      //currentLineIndex += 1;
      //setPlayer();
      changePlayLine(currentLineIndex + 1);
    }
  }

  /// 读取SC
  void getSuperChatMessage() async {
    try {
      var sc =
          await site.liveSite.getSuperChatMessage(roomId: detail.value!.roomId);
      superChats.addAll(sc);
    } catch (e) {
      Log.logPrint(e);
      addSysMsg("SC读取失败");
    }
  }

  /// 移除掉已到期的SC
  void removeSuperChats() async {
    var now = DateTime.now().millisecondsSinceEpoch;
    superChats.value = superChats
        .where((x) => x.endTime.millisecondsSinceEpoch > now)
        .toList();
  }

  /// 添加历史记录
  void addHistory() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var history = DBService.instance.getHistory(id);
    if (history != null) {
      history.updateTime = DateTime.now();
    }
    history ??= History(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      updateTime: DateTime.now(),
    );

    DBService.instance.addOrUpdateHistory(history);
  }

  /// 关注用户
  void followUser() {
    if (detail.value == null) {
      return;
    }
    var id = "${site.id}_$roomId";
    var user = FollowUser(
      id: id,
      roomId: roomId,
      siteId: site.id,
      userName: detail.value?.userName ?? "",
      face: detail.value?.userAvatar ?? "",
      addTime: DateTime.now(),
      shareUrl: shareUrl,
    );
    DBService.instance.addFollow(
      user,
    );
    followed.value = true;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    syncController.addUserData(user);
  }

  /// 取消关注用户
  void removeFollowUser() async {
    if (detail.value == null) {
      return;
    }
    if (!await Utils.showAlertDialog("确定要取消关注该用户吗？", title: "取消关注")) {
      return;
    }

    var id = "${site.id}_$roomId";
    DBService.instance.deleteFollow(id);
    followed.value = false;
    EventBus.instance.emit(Constant.kUpdateFollow, id);
    syncController.delUserData(site.id, roomId);
  }

  void share() {
    if (detail.value == null) {
      return;
    }
    SharePlus.instance.share(ShareParams(uri: Uri.parse(detail.value!.url)));
  }

  void copyUrl() {
    if (detail.value == null) {
      return;
    }
    Utils.copyToClipboard(detail.value!.url);
    SmartDialog.showToast("已复制直播间链接");
  }

  /// 复制新生成的直播流
  void copyPlayUrl() async {
    // 未开播不复制
    if (!liveStatus.value) {
      return;
    }
    var playUrl = await site.liveSite
        .getPlayUrls(detail: detail.value!, quality: qualites[currentQuality]);
    if (playUrl.urls.isEmpty) {
      SmartDialog.showToast("无法读取播放地址");
      return;
    }
    Utils.copyToClipboard(playUrl.urls.first);
    SmartDialog.showToast("已复制播放直链");
  }

  /// 底部打开播放器设置
  void showDanmuSettingsSheet() {
    Utils.showBottomSheet(
      title: "弹幕设置",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          DanmuSettingsView(
            danmakuController: danmakuController,
            onTapDanmuShield: () {
              Get.back();
              showDanmuShield();
            },
          ),
        ],
      ),
    );
  }

  void showVolumeSlider(BuildContext targetContext) {
    // 获取音量
    var id = "${site.id}_$roomId";
    var volumeVal = DBService.instance.getVolume(id);
    double volume = volumeVal!.toDouble();
    player.setVolume(volume);
    AppSettingsController.instance.setPlayerVolume(volume);
    SmartDialog.showAttach(
      targetContext: targetContext,
      alignment: Alignment.topCenter,
      displayTime: const Duration(seconds: 3),
      maskColor: const Color(0x00000000),
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            borderRadius: AppStyle.radius12,
            color: Theme.of(context).cardColor,
          ),
          padding: AppStyle.edgeInsetsA4,
          child: Obx(
            () => SizedBox(
              width: 200,
              child: Slider(
                min: 0,
                max: 300,
                value: AppSettingsController.instance.playerVolume.value,
                onChanged: (newValue) {
                  player.setVolume(newValue);
                  addOrUpdateVolume(newValue);
                  AppSettingsController.instance.setPlayerVolume(newValue);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void showQualitySheet() {
    Utils.showBottomSheet(
      title: "切换清晰度",
      child: RadioGroup(
        groupValue: currentQuality,
        onChanged: (e) {
          Get.back();
          currentQuality = e ?? 0;
          getPlayUrl();
        },
        child: ListView.builder(
          itemCount: qualites.length,
          itemBuilder: (_, i) {
            var item = qualites[i];
            return RadioListTile(
              value: i,
              title: Text(item.quality),
            );
          },
        ),
      ),
    );
  }

  void showPlayUrlsSheet() {
    Utils.showBottomSheet(
      title: "切换线路",
      child: RadioGroup(
        groupValue: currentLineIndex,
        onChanged: (e) {
          Get.back();
          //currentLineIndex = i;
          //setPlayer();
          changePlayLine(e ?? 0);
        },
        child: ListView.builder(
          itemCount: playUrls.length,
          itemBuilder: (_, i) {
            return RadioListTile(
              value: i,
              title: Text("线路${i + 1}"),
              secondary: Text(
                playUrls[i].contains(".flv") ? "FLV" : "HLS",
              ),
            );
          },
        ),
      ),
    );
  }

  void showPlayerSettingsSheet() {
    Utils.showBottomSheet(
      title: "画面尺寸",
      child: Obx(
        () => RadioGroup(
          groupValue: AppSettingsController.instance.scaleMode.value,
          onChanged: (e) {
            AppSettingsController.instance.setScaleMode(e ?? 0);
            updateScaleMode();
          },
          child: ListView(
            padding: AppStyle.edgeInsetsV12,
            children: const [
              RadioListTile(
                value: 0,
                title: Text("适应"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 1,
                title: Text("拉伸"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 2,
                title: Text("铺满"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 3,
                title: Text("16:9"),
                visualDensity: VisualDensity.compact,
              ),
              RadioListTile(
                value: 4,
                title: Text("4:3"),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void showDanmuShield() {
    TextEditingController keywordController = TextEditingController();

    void addKeyword() {
      if (keywordController.text.isEmpty) {
        SmartDialog.showToast("请输入关键词");
        return;
      }

      AppSettingsController.instance
          .addShieldList(keywordController.text.trim());
      keywordController.text = "";
    }

    Utils.showBottomSheet(
      title: "关键词屏蔽",
      child: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          TextField(
            controller: keywordController,
            decoration: InputDecoration(
              contentPadding: AppStyle.edgeInsetsH12,
              border: const OutlineInputBorder(),
              hintText: "请输入关键词",
              suffixIcon: TextButton.icon(
                onPressed: addKeyword,
                icon: const Icon(Icons.add),
                label: const Text("添加"),
              ),
            ),
            onSubmitted: (e) {
              addKeyword();
            },
          ),
          AppStyle.vGap12,
          Obx(
            () => Text(
              "已添加${AppSettingsController.instance.shieldList.length}个关键词（点击移除）",
              style: Get.textTheme.titleSmall,
            ),
          ),
          AppStyle.vGap12,
          Obx(
            () => Wrap(
              runSpacing: 12,
              spacing: 12,
              children: AppSettingsController.instance.shieldList
                  .map(
                    (item) => InkWell(
                      borderRadius: AppStyle.radius24,
                      onTap: () {
                        AppSettingsController.instance.removeShieldList(item);
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          borderRadius: AppStyle.radius24,
                        ),
                        padding: AppStyle.edgeInsetsH12.copyWith(
                          top: 4,
                          bottom: 4,
                        ),
                        child: Text(
                          item,
                          style: Get.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void showFollowUserSheet() {
    Utils.showBottomSheet(
      title: "关注列表",
      child: Obx(
        () => Stack(
          children: [
            RefreshIndicator(
              onRefresh: () => FollowService.instance.loadData(manual: true),
              child: ListView.builder(
                itemCount: FollowService.instance.liveList.length,
                itemBuilder: (_, i) {
                  var item = FollowService.instance.liveList[i];
                  return Obx(
                    () => FollowUserItem(
                      item: item,
                      playing: rxSite.value.id == item.siteId &&
                          rxRoomId.value == item.roomId,
                      onTap: () {
                        Get.back();
                        resetRoom(
                          Sites.allSites[item.siteId]!,
                          item.roomId,
                          item.shareUrl,
                        );
                      },
                    ),
                  );
                },
              ),
            ),
            if (Platform.isLinux || Platform.isWindows || Platform.isMacOS)
              Positioned(
                right: 12,
                bottom: 12,
                child: Obx(
                  () => DesktopRefreshButton(
                    refreshing: FollowService.instance.updating.value,
                    onPressed: () =>
                        FollowService.instance.loadData(manual: true),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void showAutoExitSheet() {
    if (AppSettingsController.instance.autoExitEnable.value &&
        !delayAutoExit.value) {
      SmartDialog.showToast("已设置了全局定时关闭");
      return;
    }
    Utils.showBottomSheet(
      title: "定时关闭",
      child: ListView(
        children: [
          Obx(
            () => SwitchListTile(
              title: Text(
                "启用定时关闭",
                style: Get.textTheme.titleMedium,
              ),
              value: autoExitEnable.value,
              onChanged: (e) {
                autoExitEnable.value = e;

                setAutoExit();
                //controller.setAutoExitEnable(e);
              },
            ),
          ),
          Obx(
            () => ListTile(
              enabled: autoExitEnable.value,
              title: Text(
                "自动关闭时间：${autoExitMinutes.value ~/ 60}小时${autoExitMinutes.value % 60}分钟",
                style: Get.textTheme.titleMedium,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                var value = await showTimePicker(
                  context: Get.context!,
                  initialTime: TimeOfDay(
                    hour: autoExitMinutes.value ~/ 60,
                    minute: autoExitMinutes.value % 60,
                  ),
                  initialEntryMode: TimePickerEntryMode.inputOnly,
                  builder: (_, child) {
                    return MediaQuery(
                      data: Get.mediaQuery.copyWith(
                        alwaysUse24HourFormat: true,
                      ),
                      child: child!,
                    );
                  },
                );
                if (value == null || (value.hour == 0 && value.minute == 0)) {
                  return;
                }
                var duration =
                    Duration(hours: value.hour, minutes: value.minute);
                autoExitMinutes.value = duration.inMinutes;
                AppSettingsController.instance
                    .setRoomAutoExitDuration(autoExitMinutes.value);
                //setAutoExitDuration(duration.inMinutes);
                setAutoExit();
              },
            ),
          ),
        ],
      ),
    );
  }

  void openNaviteAPP() async {
    var naviteUrl = "";
    var webUrl = "";
    if (site.id == Constant.kBiliBili) {
      naviteUrl = "bilibili://live/${detail.value?.roomId}";
      webUrl = "https://live.bilibili.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyin) {
      var args = detail.value?.danmakuData as DouyinDanmakuArgs;
      naviteUrl = "snssdk1128://webcast_room?room_id=${args.roomId}";
      webUrl = "https://live.douyin.com/${args.webRid}";
    } else if (site.id == Constant.kHuya) {
      var args = detail.value?.danmakuData as HuyaDanmakuArgs;
      naviteUrl =
          "yykiwi://homepage/index.html?banneraction=https%3A%2F%2Fdiy-front.cdn.huya.com%2Fzt%2Ffrontpage%2Fcc%2Fupdate.html%3Fhyaction%3Dlive%26channelid%3D${args.subSid}%26subid%3D${args.subSid}%26liveuid%3D${args.subSid}%26screentype%3D1%26sourcetype%3D0%26fromapp%3Dhuya_wap%252Fclick%252Fopen_app_guide%26&fromapp=huya_wap/click/open_app_guide";
      webUrl = "https://www.huya.com/${detail.value?.roomId}";
    } else if (site.id == Constant.kDouyu) {
      naviteUrl =
          "douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D${detail.value?.roomId}";
      webUrl = "https://www.douyu.com/${detail.value?.roomId}";
    }
    try {
      await launchUrlString(naviteUrl, mode: LaunchMode.externalApplication);
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("无法打开APP，将使用浏览器打开");
      await launchUrlString(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  void resetRoom(Site site, String roomId, String shareUrl) async {
    if (this.site == site && this.roomId == roomId) {
      return;
    }

    // 参数变更前先退房停心跳：抖音账号态真实退房，同时避免心跳 getter 读到新房 id
    if (this.site.id == Constant.kDouyin &&
        presence.value == RoomPresence.account) {
      await _exitGuardRoom();
    }
    presence.value = RoomPresence.guest;

    rxSite.value = site;
    rxRoomId.value = roomId;
    rxShareUrl.value = shareUrl;
    // 清除全部消息
    liveDanmaku.stop();
    messages.clear();
    superChats.clear();
    danmakuController?.clear();
    // 重置缩放
    resetZoom();

    // 重新设置 LiveDanmaku
    _danmakuSuspended = false;
    liveDanmaku = site.liveSite.getDanmaku();

    // 停止播放
    await player.stop();

    // 切房间后焦点窗口重建，预防性重置 IME 会话，避免中文输入偶发僵死
    if (Platform.isWindows && Get.isRegistered<WindowsImeWatchdog>()) {
      Get.find<WindowsImeWatchdog>().cycleSession();
    }

    // 刷新信息
    guestVerifyReplays = 0;
    loadData();
  }

  void copyErrorDetail() {
    Utils.copyToClipboard('''直播平台：${rxSite.value.name}
房间号：${rxRoomId.value}
错误信息：
${error?.toString()}
----------------
${error is Error ? (error as Error).stackTrace : ""}''');
    SmartDialog.showToast("已复制错误信息");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    if (state == AppLifecycleState.paused) {
      Log.d("进入后台");
      //进入后台，关闭弹幕
      danmakuController?.clear();
      isBackground = true;
      unawaited(onBackgroundPlaybackPolicyChanged());
    } else
    //返回前台
    if (state == AppLifecycleState.resumed) {
      Log.d("返回前台");
      isBackground = false;
      unawaited(onBackgroundPlaybackPolicyChanged());
    }
  }

  // 用于启动开播时长计算和更新的函数
  void startLiveDurationTimer() {
    // 如果不是直播状态或者 showTime 为空，则不启动定时器
    if (!(detail.value?.status ?? false) || detail.value?.showTime == null) {
      liveDuration.value = "00:00:00"; // 未开播时显示 00:00:00
      _liveDurationTimer?.cancel();
      return;
    }

    try {
      int startTimeStamp = int.parse(detail.value!.showTime!);
      // 取消之前的定时器
      _liveDurationTimer?.cancel();
      // 创建新的定时器，每秒更新一次
      _liveDurationTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        int currentTimeStamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        int durationInSeconds = currentTimeStamp - startTimeStamp;

        int hours = durationInSeconds ~/ 3600;
        int minutes = (durationInSeconds % 3600) ~/ 60;
        int seconds = durationInSeconds % 60;

        String formattedDuration =
            '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
        liveDuration.value = formattedDuration;
      });
    } catch (e) {
      liveDuration.value = "--:--:--"; // 错误时显示 --:--:--
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _playbackWatchdog.cancel();
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    unawaited(_exitGuardRoom());

    liveDanmaku.stop();
    if (_audioServiceActive) {
      _audioServiceActive = false;
      unawaited(BackgroundAudioService.instance.stop());
    }
    BackgroundAudioService.instance.setStopRequestedHandler(null);
    danmakuController = null;
    _liveDurationTimer?.cancel();
    super.onClose();
  }

  void addOrUpdateVolume(double newValue) async {
    var id = "${site.id}_$roomId";
    DBService.instance.addOrUpdateVolume(id, newValue);
  }
}
