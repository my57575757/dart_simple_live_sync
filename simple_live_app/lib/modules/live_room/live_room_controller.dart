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
import 'package:simple_live_app/app/multiwindow/presence/douyin_presence_gateway.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_apply_target.dart';
import 'package:simple_live_app/app/multiwindow/presence/local_presence_client.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_claimant.dart';
import 'package:simple_live_app/app/multiwindow/presence/presence_client.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/live_room/douyin_guest_verify/douyin_guest_verify_gate.dart';
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
import 'package:simple_live_app/widgets/desktop_refresh_button.dart';
import 'package:simple_live_app/widgets/follow_user_item.dart';
import 'package:simple_live_app/widgets/native_edit_field.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:url_launcher/url_launcher_string.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:simple_live_app/modules//sync/local_sync/local_sync_controller.dart';

/// 抖音房间在场状态：游客 / 进入中 / 账号已进入
enum RoomPresence { guest, entering, account }

class LiveRoomController extends PlayerController
    with WidgetsBindingObserver
    implements PresenceApplyTarget {
  final syncController = LocalSyncController("localhost");

  final Site pSite;
  final String pRoomId;
  final String pShareUrl;
  late LiveDanmaku liveDanmaku;
  final String? tabId;
  LiveRoomController({
    required this.pSite,
    required this.pRoomId,
    required this.pShareUrl,
    this.tabId,
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
    final followShareUrl =
        DBService.instance.getFollowShareUrl("${site.id}_$roomId");
    if (followShareUrl != null && followShareUrl.isNotEmpty) {
      rxShareUrl.value = followShareUrl;
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

  /// Windows 标签壳下抖音账号态走全局网关；Android / 路由模式为 null
  PresenceClient? _presenceClient;
  DouyinPresenceTab? _presenceTab;

  /// 子窗 bili/huya 写动作走主窗 GuardServerService 代理（无仲裁语义，
  /// 只 send 不 claim/release）。
  PresenceClient? _writeClient;

  /// 测试用：注入假 write client 验证子窗 bili/huya 发送分流。
  @visibleForTesting
  void debugBindWriteClient(PresenceClient client) {
    _writeClient = client;
  }

  /// 测试用：读取当前 presence client（验证切房重绑）。
  @visibleForTesting
  PresenceClient? get debugPresenceClient => _presenceClient;

  /// 测试用：读取当前 write client（验证切房重绑）。
  @visibleForTesting
  PresenceClient? get debugWriteClient => _writeClient;

  /// 跨窗迁移关闭：onClose 时不再发 presence leave（栈/心跳在主端延续）
  bool _movedAway = false;

  void markMovedAway() {
    _movedAway = true;
  }

  /// presence 状态切换世代：每次 apply* 切换递增；续体在每个 await 后发现
  /// 世代已变（让位降级在途时被回退接管/重进/suspended/关闭/刷新抢先）即放弃
  /// 落 side effect，避免迟到续体把账号弹幕覆盖回游客。
  int _presenceGeneration = 0;

  DouyinPresenceGateway? _resolveGateway() {
    if (tabId == null) {
      return null;
    }
    if (!Get.isRegistered<DouyinPresenceGateway>()) {
      return null;
    }
    return Get.find<DouyinPresenceGateway>();
  }

  /// 接线入口（onInit 与测试共用）：仅抖音标签绑定到网关
  void bindPresenceGateway(DouyinPresenceGateway gateway) {
    if (site.id != Constant.kDouyin || tabId == null) {
      return;
    }
    _presenceTab = _ControllerPresenceTab(this);
    gateway.bindTab(_presenceTab!);
    _presenceClient = LocalPresenceClient(gateway, _presenceTab!);
  }

  /// 测试用：注入假 PresenceClient 验证 not_holder 重发等控制器逻辑。
  @visibleForTesting
  void debugBindPresenceClient(PresenceClient client) {
    _presenceClient = client;
  }

  /// 子窗弹幕发送 UI 本里程碑不开放（通道已铺好，输入 UI 留 M5）
  bool get _isSubWindow =>
      Platform.isWindows && MultiWindowRole.isSubWindow;

  /// 子窗抖音标签：借用主窗登录身份参与 presence
  bool get _isSubWindowDouyin =>
      _isSubWindow && site.id == Constant.kDouyin;

  /// 子引擎 presence 接线入口（onInit 与测试共用）：向主端登记死亡对账
  /// 索引并持有 per-tab IPC client。返回 true 表示已走子端通道，
  /// 调用方不再尝试本地网关绑定（子引擎不注册网关）。
  bool bindSubWindowPresence() {
    if (!_isSubWindowDouyin ||
        tabId == null ||
        !Get.isRegistered<IpcPresenceCoordinator>()) {
      return false;
    }
    final coordinator = Get.find<IpcPresenceCoordinator>();
    // best-effort：主窗不可达不阻塞子端进房（主窗关闭=整个应用退出）
    unawaited(coordinator.registerRemoteTab(
      tabId: tabId!,
      siteId: site.id,
      roomId: roomId,
      shareUrl: shareUrl,
    ));
    _presenceClient = coordinator.clientForTab(
      tabId: tabId!,
      siteId: site.id,
      args: presenceClaimArgs,
    );
    return true;
  }

  /// 子窗 bili/huya 写动作（弹幕/点赞）走主窗 GuardServerService 代理：
  /// 无仲裁语义，只 send 不 claim/release。douyu/twitch 走 liveDanmaku
  /// （凭据借用后重启连接），不挂 write client。
  bool bindSubWindowWriteClient() {
    if (!_isSubWindow ||
        tabId == null ||
        !Get.isRegistered<IpcPresenceCoordinator>()) {
      return false;
    }
    if (site.id != Constant.kBiliBili && site.id != Constant.kHuya) {
      return false;
    }
    _writeClient = Get.find<IpcPresenceCoordinator>().clientForTab(
      tabId: tabId!,
      args: presenceClaimArgs,
      siteId: site.id,
    );
    return true;
  }

  /// claim 当刻读取的进房参数：guard 房间标识随游客详情刷新可能变化
  PresenceClaimArgs presenceClaimArgs() => PresenceClaimArgs(
        roomId: roomId,
        shareUrl: shareUrl,
        guardRoomId: _guardRoomId,
        guardWebRid: _guardWebRid,
        guardExtra: Map<String, Object?>.from(_guardExtraArgs()),
      );

  /// 子窗刷新/切房 leave 完成后：重建主端死亡对账索引并清借用凭据。
  /// release 同时摘除索引与仲裁标签，而注册只在 onInit 一次；不补注册
  /// 则标签存活期内账号态永久不可用（后续 claim 被主端裸拒）。
  /// 读入参数取控制器当刻身份：resetRoom 换房后即为新房间/新站点。
  Future<void> _reRegisterSubWindowTabAfterLeave() async {
    final tabId = this.tabId;
    if (tabId == null || !Get.isRegistered<IpcPresenceCoordinator>()) {
      return;
    }
    await Get.find<IpcPresenceCoordinator>().refreshRemoteTab(
      tabId: tabId,
      siteId: site.id,
      roomId: roomId,
      shareUrl: shareUrl,
    );
  }

  /// 测试接缝：刷新/切房后的子窗 presence 重建（生产仅 refresh/reset 调用）
  @visibleForTesting
  Future<void> debugReRegisterSubWindowAfterLeave() =>
      _reRegisterSubWindowTabAfterLeave();

  /// 子窗切房后动态重绑 per-tab client（缺口 E）：旧 client 一律置空再按
  /// 新站点挂 presence（抖音 claim）或 write（bili/huya 代理写动作）。
  /// 主窗/Android 不受影响（保留 onInit 的网关绑定）。
  void _rebindSubWindowClients() {
    if (!_isSubWindow) return;
    _presenceClient = null;
    _writeClient = null;
    if (!bindSubWindowPresence()) {
      bindSubWindowWriteClient();
    }
  }

  /// 测试接缝：切房后子窗 client 动态重绑（生产仅 resetRoom 调用）
  @visibleForTesting
  void debugRebindSubWindowClients() => _rebindSubWindowClients();

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

    BackgroundAudioService.instance.setStopRequestedHandler(tabId ?? 'android',
        () async {
      _audioServiceActive = false;
      BackgroundAudioService.instance.markStopped();
      await player.pause();
    });

    // 子引擎抖音标签绑 IPC presence 通道；bili/huya 子窗绑 write 代理；
    // 主窗/Android 维持本地网关直连
    if (!bindSubWindowPresence()) {
      if (!bindSubWindowWriteClient()) {
        final gateway = _resolveGateway();
        if (gateway != null) {
          bindPresenceGateway(gateway);
        }
      }
    }

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
          await _handleAutoExit();
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
          await _handleAutoExit();
        }
      }
    });
  }

  /// 定时关闭到时（R14 裁决）：Windows 多标签模式关闭【全部】直播间标签
  /// （回首页、全部静音，进程不退）；仅当本定时器宿主标签仍在 store.tabs 中
  /// 时才执行——宽限期内用户已手动关掉本标签时，幽灵 Timer/二次进入一律
  /// no-op，且不得误关其他标签。全关后才释放 wakelock，避免后台标签到点
  /// 全局关 wakelock 导致正在观看的标签息屏。
  /// 无标签壳（Android / 路由模式）保持释放 wakelock 后退出进程。
  Future<void> _handleAutoExit() async {
    if (Platform.isWindows &&
        tabId != null &&
        Get.isRegistered<TabStore>()) {
      final store = Get.find<TabStore>();
      if (store.tabs.any((t) => t.tabId == tabId)) {
        final navigator = Get.key.currentState;
        if (navigator != null && navigator.canPop()) {
          Get.back();
        }
        await store.closeAll();
        await WakelockPlus.disable();
      }
      return;
    }
    await WakelockPlus.disable();
    exit(0);
  }
  // 弹窗逻辑

  void refreshRoom() {
    if (site.id == Constant.kDouyin) {
      final leave = _leaveDouyinPresence(unconditional: false);
      if (_isSubWindowDouyin) {
        // release 摘除主端索引后必须重注册，否则该标签账号态永久失效
        unawaited(leave.then((_) => _reRegisterSubWindowTabAfterLeave()));
      } else {
        unawaited(leave);
      }
    }
    //messages.clear();
    superChats.clear();
    ++_presenceGeneration;
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
    // 子窗抖音本地恒未登录：借用主窗身份直接 claim，失败文案由回执承接
    if (!danmakuLogined && !_isSubWindowDouyin) {
      await showDanmakuLoginDialog();
      return false;
    }
    final client = _presenceClient;
    final future = client == null
        ? _doEnterAsAccount()
        : _doEnterViaGateway(client);
    _enteringFuture = future;
    try {
      return await future;
    } finally {
      _enteringFuture = null;
    }
  }

  Future<bool> _doEnterViaGateway(PresenceClient client) async {
    presence.value = RoomPresence.entering;
    final result = await client.claim();
    if (result.granted) {
      // applyAccountEnter 可能在弹幕重连处抛错，而网关已置 holder+ready，
      // 后续 claim 短路不再 apply：账号态以服务端/心跳为准，此处必须落
      // account，否则控制器永久停在 entering。
      presence.value = RoomPresence.account;
      return true;
    }
    presence.value = RoomPresence.guest;
    SmartDialog.showToast(presenceFailureText(result.reason));
    return false;
  }

  /// claim/IPC 失败原因 → toast 文案（spec §5.1 逐字）。
  /// 主窗本地只会见到 detailFailed/enterFailed；其余为子窗 IPC 路径。
  String presenceFailureText(PresenceFailureReason? reason) {
    switch (reason) {
      case PresenceFailureReason.notLoggedIn:
        return '主窗口未登录抖音，请先在主窗口登录';
      case PresenceFailureReason.notConfigured:
        return '主窗口未配置弹幕签名服务，请在主窗口完成配置';
      case PresenceFailureReason.detailFailed:
        return '无法以账号身份读取该房间（可能被主播限制）';
      case PresenceFailureReason.enterFailed:
        return '进入直播间失败，已保持游客观看';
      case PresenceFailureReason.ipcFailed:
        return '主窗口服务无响应，请重试';
      case null:
        return '进入直播间失败，已保持游客观看';
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
    final LiveRoomDetail accountDetail;
    try {
      accountDetail = await fetchAccountDetail();
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

    await applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: entered.status,
      reentered: false,
    );
    _startGuardHeartbeat(entered.accountId);
    return true;
  }

  /// 账号详情（网关端口与旧路径共用）
  @override
  Future<LiveRoomDetail> fetchAccountDetail() {
    return (site.liveSite as DouyinSite).getRoomDetail(
      roomId: "$roomId;$shareUrl",
      asAccount: true,
    );
  }

  /// 账号进场成功后的弹幕/详情/状态切换（旧路径与网关 applyAccountEnter 共用）
  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    final generation = ++_presenceGeneration;
    await liveDanmaku.stop();
    if (generation != _presenceGeneration) return;
    detail.value = accountDetail;
    online.value = accountDetail.online;
    liveStatus.value = accountDetail.status || accountDetail.isRecord;
    initDanmau();
    await liveDanmaku.start(accountDetail.danmakuData);
    if (generation != _presenceGeneration) return;
    _applyGuardStatus(guardStatus);
    presence.value = RoomPresence.account;
    addSysMsg(reentered ? "已自动在本标签恢复登录进入" : "已进入直播间");
  }

  /// 跨窗迁入主窗：自取账号详情后复用进场复刻流程（网关 rehome 本地路径调用）
  Future<void> applyReentered(Map<String, dynamic> guardStatus) async {
    final accountDetail = await fetchAccountDetail();
    await applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: guardStatus,
      reentered: true,
    );
  }

  /// 被更新打开的标签让位：播放不中断，游客详情重连弹幕（best-effort）
  @override
  Future<void> applyYieldToGuest() async {
    final generation = ++_presenceGeneration;
    guardJoined.value = false;
    guardStarRoom.value = false;
    guardBadgeActive.value = false;
    presence.value = RoomPresence.guest;
    addSysMsg("已在更新打开的直播间标签中登录进入，本标签保持游客观看；该标签关闭后将自动切回。");
    try {
      final guestDetail = await (site.liveSite as DouyinSite).getRoomDetail(
        roomId: "$roomId;$shareUrl",
        asAccount: false,
      );
      if (generation != _presenceGeneration) return;
      await liveDanmaku.stop();
      if (generation != _presenceGeneration) return;
      detail.value = guestDetail;
      online.value = guestDetail.online;
      liveStatus.value = guestDetail.status || guestDetail.isRecord;
      initDanmau();
      await liveDanmaku.start(guestDetail.danmakuData);
    } catch (e) {
      // best-effort：游客取页/弹幕重连失败不影响播放，账号弹幕随服务端断开自然终止。
      // 不弹全局验证页（可能为后台标签），避免打断当前激活标签。
      Log.logPrint("presence: 让位后游客重连失败: $e");
    }
  }

  /// 外部端抢占：不切弹幕、不抢回；置 guest 使后续写动作走 claim 重进
  @override
  Future<void> applySuspended() async {
    // 不切弹幕、不抢回；使在途的让位/进场续体失效
    ++_presenceGeneration;
    presence.value = RoomPresence.guest;
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

  /// 抖音账号态离开：网关标签走 release（持有者发 exit + 次新回退接管；
  /// 已被让位 / suspended 的标签仅出栈）；Android 与无网关时维持各调用点
  /// 原有退房语义（onClose 全平台退房；refresh/reset 仅抖音账号态退房）。
  /// [unconditional]=true 仅用于 onClose。
  Future<void> _leaveDouyinPresence({required bool unconditional}) async {
    final client = _presenceClient;
    if (client != null) {
      final inStack = client.isClaimed;
      if (unconditional ||
          presence.value == RoomPresence.account ||
          inStack) {
        await client.release();
      }
      return;
    }
    if (unconditional) {
      await _exitGuardRoom();
    } else if (site.id == Constant.kDouyin &&
        presence.value == RoomPresence.account) {
      await _exitGuardRoom();
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
      final presenceClient = _presenceClient;
      final guard = GuardServerService.instance;

      if (site.id == Constant.kDouyin && presenceClient != null) {
        // 主窗标签 / 子窗标签抖音发送统一走 presence 串行域，不再直连
        // GuardServerService、不在控制器起心跳（消除发送瞬间 holder 切换）。
        result = await _sendDanmakuViaPresence(presenceClient, content);
      } else if (_isSubWindow &&
          (site.id == Constant.kBiliBili || site.id == Constant.kHuya) &&
          _writeClient != null) {
        // 子窗 bili/huya：经主窗 GuardServerService 代理发送（无仲裁语义）。
        // _sendDanmakuViaPresence 含一次 not_holder 重试；bili/huya 无
        // holder 语义，重试安全（幂等由服务端决定）。
        result = await _sendDanmakuViaPresence(_writeClient!, content);
      } else {
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
                errorMessage:
                    msg is String && msg.isNotEmpty ? msg : "网络请求失败",
              );
            }
          }

          result = await sendOnce(accountId);
          if (result.success && _presenceClient == null) {
            // 网关模式下唯一心跳由网关维护；仅 Android / bili/huya 直连路径
            // 才在控制器起 Timer。
            _startGuardHeartbeat(accountId);
          }
        } else {
          result = await liveDanmaku.sendMessage(content);
        }
      }
      if (!result.success) {
        if (site.id == Constant.kDouyu &&
            result.errorCode == "session_expired") {
          await reloginDouyu();
        } else {
          SmartDialog.showToast(
            danmakuErrorText(site.id, result),
          );
        }
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

  /// 抖音 presence 通道发送：not_holder（持有者在他端切换/挂起）时
  /// 先强制回 guest 再重新 claim，重发**一次**；仍失败由文案层提示。
  Future<DanmakuSendResult> _sendDanmakuViaPresence(
    PresenceClient client,
    String content,
  ) async {
    var r = await client.sendDanmaku(content);
    if (!r.success && r.code == kPresenceCodeNotHolder) {
      presence.value = RoomPresence.guest;
      if (await ensureAccountPresence()) {
        r = await client.sendDanmaku(content);
      }
    }
    return DanmakuSendResult(
      success: r.success,
      errorCode: r.success ? '' : (r.code ?? 'guard'),
      errorMessage: r.message ?? '',
    );
  }

  /// 斗鱼弹幕登录态（7 天）过期：弹窗引导重新登录，成功后用新 cookie 重启弹幕
  Future<void> reloginDouyu() async {
    final go = await Utils.showAlertDialog(
      "斗鱼登录态已过期，是否重新登录？",
      title: "登录已过期",
    );
    if (!go) return;
    await DouyuAccountService.instance.startWebLogin();
    if (!DouyuAccountService.instance.logined.value) return;
    await _restartDouyuDanmaku();
  }

  Future<void> _restartDouyuDanmaku() async {
    final oldArgs = detail.value?.danmakuData;
    final roomIdInt = oldArgs is DouyuDanmakuArgs
        ? oldArgs.roomId
        : int.tryParse(roomId.toString()) ?? 0;
    final newArgs = DouyuDanmakuArgs(
      roomId: roomIdInt,
      cookie: DouyuAccountService.instance.cookie,
    );
    await liveDanmaku.stop();
    liveDanmaku = site.liveSite.getDanmaku();
    initDanmau();
    await liveDanmaku.start(newArgs);
  }

  /// M5 Task 3：凭据下发后按需重启该站弹幕连接（douyu/twitch）。
  ///
  /// 仅 douyu/twitch：bili/huya 写路径走代理（Task 4/5），抖音走 presence
  /// applyAccountEnter 自带账号弹幕切换。凭据非空且弹幕已随房间详情启动时，
  /// 按 reloginDouyu 同构路径 stop → getDanmaku() → start(新 args 带凭据)；
  /// 凭据空则不重启，保持 Guest（发送报 not_login，现有文案）。
  Future<void> applyBorrowedCredentials(String siteId) async {
    if (siteId != Constant.kDouyu && siteId != Constant.kTwitch) return;
    final detailValue = detail.value;
    if (detailValue == null || !canStartDanmaku(detailValue)) return;
    if (siteId == Constant.kDouyu) {
      if (DouyuAccountService.instance.cookie.isEmpty) return;
      await _restartDouyuDanmaku();
      return;
    }
    if (TwitchAccountService.instance.oauthToken.isEmpty) return;
    final oldArgs = detailValue.danmakuData;
    final newArgs = TwitchDanmakuArgs(
      channel: oldArgs is TwitchDanmakuArgs ? oldArgs.channel : roomId,
      oauthToken: TwitchAccountService.instance.oauthToken,
      userLogin: TwitchAccountService.instance.userLogin,
    );
    await liveDanmaku.stop();
    liveDanmaku = site.liveSite.getDanmaku();
    initDanmau();
    await liveDanmaku.start(newArgs);
  }

  /// 点赞/送灯牌是否可用：仅抖音、B站，且已配置签名服务并登录；
  /// 子窗抖音/bili 恒放行（借用主窗身份，由主窗代理鉴权）
  bool get guardActionEnabled =>
      (GuardServerService.instance.configured &&
          (site.id == "douyin" || site.id == "bilibili") &&
          danmakuLogined) ||
      _isSubWindowDouyin ||
      (_isSubWindow && site.id == "bilibili");

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
      final presenceClient = _presenceClient;
      if (site.id == Constant.kDouyin && presenceClient != null) {
        await _sendActionViaPresence(presenceClient, action);
        return;
      }
      if (_isSubWindow &&
          site.id == Constant.kBiliBili &&
          _writeClient != null) {
        // 子窗 bili 互动动作经主窗代理（huya 无互动 UI，不开此分支）
        await _sendActionViaPresence(_writeClient!, action);
        return;
      }
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
        _applyGuardActionSuccessFlags(action);
        // 主动操作已在服务端抢占房间，恢复本端心跳保活
        if (_presenceClient == null) {
          _startGuardHeartbeat(accountId);
        }
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

  /// 抖音 presence 通道互动动作 + not_holder 一次重claim重发。
  Future<void> _sendActionViaPresence(
    PresenceClient client,
    String action,
  ) async {
    var r = await client.sendAction(action);
    if (!r.success && r.code == kPresenceCodeNotHolder) {
      presence.value = RoomPresence.guest;
      if (await ensureAccountPresence()) {
        r = await client.sendAction(action);
      }
    }
    if (r.success) {
      _applyGuardActionSuccessFlags(action);
    } else {
      SmartDialog.showToast(
        r.message ??
            (r.code == kPresenceCodeNotHolder ? '登录状态已切换，请重试' : '操作失败'),
      );
    }
  }

  void _applyGuardActionSuccessFlags(String action) {
    if (action == 'join_club') {
      guardJoined.value = true;
      guardBadgeActive.value = true;
    }
    if (action == 'light_up') guardBadgeActive.value = true;
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
    final confirmed = await Get.dialog<bool>(
      _buildSendBadgeConfirmDialog(isStarRoom),
    );
    if (confirmed == true) {
      await _sendGuardAction("fans_badge");
    }
  }

  /// 查询粉丝团每日任务；任何失败返回 null，由调用方降级为普通确认弹窗
  Future<Map<String, dynamic>?> _queryDailyTasks() async {
    final guard = GuardServerService.instance;
    var accountId = await guard.ensureAccount(site.id);
    if (accountId == null) return null;

    Future<Map<String, dynamic>> runOnce(String id,
        {bool retried = false}) async {
      try {
        return await guard.getDailyTasks(
          accountId: id,
          roomId: _guardRoomId,
          webRid: _guardWebRid,
        );
      } on DioException catch (e) {
        if (e.response?.statusCode == 404 && !retried) {
          final newId = await guard.reregister(site.id);
          if (newId != null) return runOnce(newId, retried: true);
        }
        rethrow;
      }
    }

    SmartDialog.showLoading(msg: "查询每日任务...");
    try {
      return await runOnce(accountId);
    } catch (e) {
      Log.logPrint("每日任务查询失败: $e");
      return null;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
    }
  }

  Widget _buildSendBadgeConfirmDialog(bool isStarRoom) {
    final priceText = site.id == "douyin"
        ? (isStarRoom ? "星守护房间将送出点点星光（8 抖币）" : "送出粉丝团灯牌（1 抖币）")
        : "免费";
    return AlertDialog(
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
    );
  }

  Widget _buildDailyTasksDialog(
      Map<String, dynamic> tasks, String primaryAction) {
    final isStarRoom = primaryAction == "fans_badge" &&
        site.id == "douyin" &&
        guardStarRoom.value;
    final theme = Theme.of(Get.context!);
    final level = _taskInt(tasks["level"]);
    final intimacy = _taskInt(tasks["intimacy"]);
    final nextIntimacy = _taskInt(tasks["nextIntimacy"]);
    final medalName = tasks["medalName"]?.toString() ?? "";
    final items = (tasks["tasks"] as List?)
            ?.whereType<Map>()
            .toList(growable: false) ??
        const <Map>[];

    return AlertDialog(
      title: Text(isStarRoom ? "每日任务 · 点点星光" : "每日任务"),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.workspace_premium, size: 20),
                const SizedBox(width: 6),
                Text(
                  "Lv.$level${medalName.isNotEmpty ? " · $medalName" : ""}",
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (nextIntimacy > 0)
                  Text(
                    "$intimacy/$nextIntimacy",
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
            if (nextIntimacy > 0) ...[
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: (intimacy / nextIntimacy).clamp(0.0, 1.0),
                ),
              ),
            ],
            const SizedBox(height: 8),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (_, i) => _buildTaskRow(
                  items[i].cast<String, dynamic>(),
                  theme,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text("取消"),
        ),
        TextButton(
          onPressed: () => Get.back(result: true),
          child: Text(isStarRoom ? "送出星光" : "送出灯牌"),
        ),
      ],
    );
  }

  int _taskInt(dynamic value) =>
      value is num ? value.toInt() : int.tryParse(value?.toString() ?? "") ?? 0;

  Widget _buildTaskRow(Map<String, dynamic> task, ThemeData theme) {
    final done = task["done"] == true;
    final title = task["title"]?.toString() ?? "";
    final progress = task["progress"]?.toString() ?? "";
    final reward = task["reward"]?.toString() ?? "";
    final trailing = [progress, reward].where((s) => s.isNotEmpty).join("  ");
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(
            done ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 19,
            color: done ? Colors.green : theme.disabledColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: done
                  ? theme.textTheme.bodyMedium
                      ?.copyWith(color: theme.disabledColor)
                  : theme.textTheme.bodyMedium,
            ),
          ),
          if (trailing.isNotEmpty)
            Text(trailing, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> joinFansClub() async {
    // 已入团：抖音勋章熄灭先引导点亮；否则展示每日任务，确认后送灯牌
    if (guardJoined.value) {
      if (site.id == "douyin" && !guardBadgeActive.value) {
        SmartDialog.showToast("粉丝团勋章已熄灭，需重新点亮");
        await lightUpFansBadge();
        return;
      }
      final isStarRoom = site.id == "douyin" && guardStarRoom.value;
      final tasks = await _queryDailyTasks();
      final confirmed = await Get.dialog<bool>(
        tasks != null
            ? _buildDailyTasksDialog(tasks, "fans_badge")
            : _buildSendBadgeConfirmDialog(isStarRoom),
      );
      if (confirmed == true) {
        await _sendGuardAction("fans_badge");
      }
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
    final fieldController = NativeEditFieldController();
    final keyFocusNode = FocusNode();
    return Get.dialog<String>(
      barrierColor: Colors.black26,
      KeyboardListener(
        focusNode: keyFocusNode,
        onKeyEvent: (event) {
          if (!Platform.isWindows &&
              event is KeyDownEvent &&
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
              child: NativeEditField(
                controller: fieldController,
                autofocus: true,
                hintText: '发个弹幕呗…',
                background: const Color(0xCC000000),
                textColor: Colors.white,
                hintColor: Colors.white38,
                borderColor: Colors.white24,
                radius: 8,
                horizontalPadding: 16,
                onSubmitted: (v) => Get.back(result: v),
                // Windows 下 Esc 由原生 popup 转成 closed：关闭弹框（不发送）。
                onClosed: () {
                  if (Get.isDialogOpen ?? false) {
                    Get.back();
                  }
                },
              ),
            ),
          ),
        ),
      ),
    ).whenComplete(() {
      keyFocusNode.dispose();
      fieldController.dispose();
    });
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
    if (_isSubWindowDouyin) {
      // 子窗不提供登录入口、不导航账号管理（spec §6.6.2）
      await Utils.showMessageDialog(
        '子窗口借用主窗口的登录身份，请在主窗口登录抖音并配置弹幕签名服务',
        title: '未登录',
      );
      return;
    }
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
    if (code == kPresenceCodeNotHolder) {
      return "登录状态已切换，请重试";
    }
    if (code == "rate_limit") {
      return "发言太快，请稍后再试";
    }
    if (code == "session_expired") {
      return "登录态已过期，请在账号管理中重新登录";
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

  int guestVerifyReplays = 0;

  /// 本控制器是否对应一个【非激活】标签（后台打开、尚未被用户切到）。
  /// 后台标签加载不得弹全局 loading：遮罩挂根 Overlay 且不穿透指针，
  /// 会打断用户在列表上连续右键后台开窗；Android/路由模式 tabId==null，
  /// 恒按前台处理，行为与原状一致。仅按调用时刻判定一次，加载中途
  /// 激活标签也不补 HUD。
  bool _isBackgroundTab() {
    return tabId != null &&
        Get.isRegistered<TabStore>() &&
        Get.find<TabStore>().activeTabId.value != tabId;
  }

  /// 加载直播间信息
  void loadData() async {
    presence.value = RoomPresence.guest;
    // 仅前台标签（或 Android）弹全局 loading；show/dismiss 必须按本调用的
    // 同一开关配对，避免多个后台标签并发时 SmartDialog 单例计数失衡。
    final bool showGlobalLoading = !_isBackgroundTab();
    try {
      if (showGlobalLoading) {
        SmartDialog.showLoading(msg: "");
      }
      loadError.value = false;
      error = null;
      update();
      addSysMsg("正在读取直播间信息");
      hydrateShareUrlFromFollow();
      final liveSite = site.liveSite;
      // 斗鱼登录态（JWT）过期时先用云端最新 cookie 续命，保证后续房间详情/弹幕带新登录态
      if (site.id == Constant.kDouyu &&
          DouyuAccountService.instance.logined.value) {
        await DouyuAccountService.instance.cloudRefreshDouyuIfExpired();
      }
      if (liveSite is DouyinSite) {
        // 默认游客身份读取：不带 sessionid，不受房间黑名单影响
        detail.value = await liveSite.getRoomDetail(
          roomId: "$roomId;$shareUrl",
          asAccount: false,
        );
      } else {
        detail.value = await liveSite.getRoomDetail(roomId: roomId);
      }

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
      // 打开验证页前必须先关全局 loading：SmartDialog 遮罩在 Navigator 之上，
      // 会罩住验证页导致滑块无法操作（表现为无限转圈/卡死）
      if (showGlobalLoading) {
        SmartDialog.dismiss(status: SmartStatus.loading);
      }
      // 全局去重：进房与关注列表后台刷新共用同一验证页，只弹一次
      final result = await DouyinGuestVerifyGate.instance.open(e.webRid);
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
      if (showGlobalLoading) {
        SmartDialog.dismiss(status: SmartStatus.loading);
      }
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
    final wasDouyin = this.site.id == Constant.kDouyin;
    if (wasDouyin) {
      await _leaveDouyinPresence(unconditional: false);
    }
    ++_presenceGeneration;
    presence.value = RoomPresence.guest;

    rxSite.value = site;
    rxRoomId.value = roomId;
    rxShareUrl.value = shareUrl;
    // 子窗跨房/跨站切房：leave 的 release 摘除索引后按新身份重建
    // （douyin→非抖音主端仅完成凭据清理；非抖音→douyin 无 leave 也须补建索引）
    if ((_isSubWindow && wasDouyin) || _isSubWindowDouyin) {
      await _reRegisterSubWindowTabAfterLeave();
    }
    // 子窗 client 动态重绑（缺口 E）：与是否走了 _reRegisterSubWindowTabAfterLeave
    // 无关，非抖音→抖音、抖音→bili、bili→huya 等全部要换 client
    _rebindSubWindowClients();
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
    ++_presenceGeneration;
    WidgetsBinding.instance.removeObserver(this);
    _playbackWatchdog.cancel();
    scrollController.removeListener(scrollListener);
    autoExitTimer?.cancel();

    if (!_movedAway) {
      unawaited(_leaveDouyinPresence(unconditional: true));
    }

    liveDanmaku.stop();
    if (_audioServiceActive) {
      _audioServiceActive = false;
      unawaited(BackgroundAudioService.instance.stop());
    }
    BackgroundAudioService.instance
        .setStopRequestedHandler(tabId ?? 'android', null);
    danmakuController = null;
    _liveDurationTimer?.cancel();
    super.onClose();
  }

  void addOrUpdateVolume(double newValue) async {
    var id = "${site.id}_$roomId";
    DBService.instance.addOrUpdateVolume(id, newValue);
  }
}

/// DouyinPresenceTab 的控制器适配器：网关只经此端口碰控制器状态，
/// M4 主引擎侧的远端代理实现同一接口。
class _ControllerPresenceTab implements DouyinPresenceTab {
  _ControllerPresenceTab(this._c);

  final LiveRoomController _c;

  @override
  String get tabId => _c.tabId!;

  @override
  bool get isClosed => _c.isClosed;

  @override
  Future<LiveRoomDetail> fetchAccountDetail() => _c.fetchAccountDetail();

  @override
  String get guardRoomId => _c._guardRoomId;

  @override
  String get guardWebRid => _c._guardWebRid;

  @override
  Map<String, dynamic> guardExtraArgs() => _c._guardExtraArgs();

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) {
    return _c.applyAccountEnter(
      accountDetail: accountDetail,
      guardStatus: guardStatus,
      reentered: reentered,
    );
  }

  @override
  Future<void> applyReentered(Map<String, dynamic> guardStatus) =>
      _c.applyReentered(guardStatus);

  @override
  Future<void> applyYieldToGuest() => _c.applyYieldToGuest();

  @override
  Future<void> applySuspended() => _c.applySuspended();
}
