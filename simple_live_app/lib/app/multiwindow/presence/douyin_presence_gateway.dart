import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'presence_arbiter.dart';
import 'presence_batch_releaser.dart';
import 'presence_claimant.dart';
import 'presence_client.dart';

/// 抖音登录心跳全局仲裁者（每引擎一个；M3 仅主引擎在 kShell binding 实例化）。
///
/// 互斥粒度 = 账号 × 房间：同房间只承认一个 presence（先入者），
/// 不同房间各自记账、各自广播，互不抢占。心跳按房间分组，
/// 每组一个 Timer——异房标签进场不会掐断对方续租。
///
/// 账号态 HTTP（ensureAccount/enterRoom/heartbeat/exitRoom/reregister）
/// 与 404 重注册全部收口于此；账号详情取数经 DouyinPresenceTab 端口。
///
/// 所有变更操作经 [_serialized] 串行：claim 的 HTTP 在途时到达的
/// release/batchRelease 会排队到进场完成之后执行，避免迟到的成功结果
/// 把已关闭标签变成孤儿 holder。
class DouyinPresenceGateway extends GetxService
    implements PresenceBatchReleaser {
  DouyinPresenceGateway(
    this._guard, {
    this.heartbeatInterval = const Duration(seconds: 20),
    Duration? watchdogInterval,
    bool Function()? isAccountLoggedIn,
  })  : _isAccountLoggedIn = isAccountLoggedIn,
        watchdogInterval = watchdogInterval ?? heartbeatInterval * 2;

  final GuardServerService _guard;
  final Duration heartbeatInterval;

  /// 心跳看门狗巡检间隔：默认两个心跳周期。心跳 Timer 一旦丢失（claim 在途
  /// 取消、suspend 收口、异常重建漏挂），客户端就停止续租，服务端租约到期
  /// 后回收房间会话，挂机静默失效且没有任何报错。
  final Duration watchdogInterval;
  final bool Function()? _isAccountLoggedIn;

  final Map<String, DouyinPresenceTab> _tabs = {};
  final Map<String, String> _accountIds = {};

  /// 房间分组仲裁器：组键 = 房间（与服务端房间会话键一致）。
  final Map<String, PresenceArbiter> _groups = {};

  /// tabId → 所属房间组键
  final Map<String, String> _tabGroup = {};

  /// 已完整进场成功且持有心跳的 tabId。holder 不在其中时（回退接管失败、
  /// 被外部端抢占 suspended），claim 必须重走完整进场序列而不能短路。
  final Set<String> _ready = <String>{};

  /// 每次完整进场成功的 guard status：迁移复刻（applyReentered）用。
  /// release/detach/batch 随 tab 清除；rehome 保留（tabId 延续）。
  final Map<String, Map<String, Object?>> _lastEnterStatus = {};

  /// rehome 后尚未在新端口复刻成功的 tab：claim 短路分支补放一次。
  final Set<String> _pendingApplyReplay = <String>{};

  /// 每个房间组一个心跳 Timer：异房组互不掐断对方续租。
  final Map<String, Timer> _heartbeatTimers = {};

  /// 每个房间组一个心跳拍在途标志：heartbeat RTT 超过间隔时跳过重叠拍，
  /// 杜绝并发续租（#5）
  final Map<String, bool> _beatInFlight = {};

  /// 心跳看门狗 Timer：自续期单次 Timer，负责补挂丢失的房间组心跳
  Timer? _watchdogTimer;

  /// 变更操作串行链
  Future<void> _chain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() body) {
    final completer = Completer<T>();
    _chain.whenComplete(() {
      body().then(completer.complete, onError: completer.completeError);
    });
    final done = completer.future;
    // 单个动作失败不允许打断后续动作入链
    _chain = done.then<void>((_) {}, onError: (_) {});
    return done;
  }

  /// 全局唯一持有者视图：仅当只有一个房间持有 presence 时返回它；
  /// 多房间并存时为 null（按房间查询用 holderTabIdFor）。
  String? get holderTabId {
    final holders = <String>{};
    for (final arbiter in _groups.values) {
      final holder = arbiter.holder;
      if (holder != null) holders.add(holder);
    }
    return holders.length == 1 ? holders.first : null;
  }

  /// 指定标签所在房间的持有者（该标签自己不在栈时返回同房他标签）。
  String? holderTabIdFor(String tabId) {
    final groupKey = _tabGroup[tabId];
    if (groupKey == null) return null;
    return _groups[groupKey]?.holder;
  }

  /// 指定房间（webRid）的持有者
  String? holderTabIdOfRoom(String roomKey) => _groups[roomKey]?.holder;

  /// 按房间分组的仲裁器视图（只读）
  Map<String, PresenceArbiter> get groups => Map.unmodifiable(_groups);

  /// 房间组键：与服务端房间会话键一致（webRid），回退 roomId；
  /// 两者皆空时退化为 tabId 占位组
  String _groupKeyOf(DouyinPresenceTab tab) {
    final webRid = tab.guardWebRid.trim();
    if (webRid.isNotEmpty) return webRid;
    final roomId = tab.guardRoomId.trim();
    if (roomId.isNotEmpty) return roomId;
    return 'tab:${tab.tabId}';
  }

  PresenceArbiter _arbiterFor(String groupKey) =>
      _groups.putIfAbsent(groupKey, () => PresenceArbiter());

  /// 归组：占位组（房间标识皆空）时跟随最新可得的房间标识
  String _resolveGroup(String tabId, DouyinPresenceTab tab) {
    final groupKey = _groupKeyOf(tab);
    final existing = _tabGroup[tabId];
    if (existing == null) return groupKey;
    if (existing.startsWith('tab:') && !groupKey.startsWith('tab:')) {
      return groupKey;
    }
    return existing;
  }

  /// 控制器 onInit 绑定标签端口（同 tabId 重复绑定幂等）
  void bindTab(DouyinPresenceTab tab) {
    _tabs[tab.tabId] = tab;
  }

  bool hasClaim(String tabId) {
    final groupKey = _tabGroup[tabId];
    if (groupKey == null) return false;
    return _groups[groupKey]?.isClaimed(tabId) ?? false;
  }

  /// 显式进入 / 抢占（点「进入直播间」、发弹幕、点赞等）；
  /// holdOnly=true 为挂机：只建立账号在房+心跳，不读账号详情、不开账号视角
  Future<PresenceClaimResult> claim(DouyinPresenceTab tab,
          {bool holdOnly = false}) =>
      _serialized(() => _claim(tab, holdOnly: holdOnly));

  Future<PresenceClaimResult> _claim(DouyinPresenceTab tab,
      {bool holdOnly = false}) async {
    bindTab(tab);
    final groupKey = _resolveGroup(tab.tabId, tab);
    _tabGroup[tab.tabId] = groupKey;
    final arbiter = _arbiterFor(groupKey);
    if (arbiter.holder == tab.tabId && _ready.contains(tab.tabId)) {
      if (_pendingApplyReplay.remove(tab.tabId)) {
        // best-effort，不阻塞 granted：失败由补放函数自行重新置位。
        // 入串行链后排在 claim 之后、任何后续 release/rehome 之前（MINOR-1）。
        unawaited(_serialized(() => _replayEnter(tab)));
      }
      // 短路前先确认该房间组的心跳仍在：否则本次「进入直播间」看着成功，
      // 实际账号已不再续租，挂机会在租约到期后无声失效。
      _ensureGroupHeartbeat(groupKey, tab);
      return const PresenceClaimResult.granted();
    }
    final previousHolder = _currentHolderTab(groupKey);
    final selfWasHolder = arbiter.holder == tab.tabId;
    // enter 成功前先停同房间组的心跳：否则旧 holder 的下一拍会在服务端把
    // 浏览器页面抢回旧房间，造成同房两个标签 flip-flop。异房组心跳不动。
    _heartbeatTimers[groupKey]?.cancel();

    final result = await _performEnter(tab, holdOnly: holdOnly);
    final entered = result.outcome;
    if (entered == null) {
      // 仲裁尚未迁移，旧 holder 没有被让位：恢复其心跳。
      // 本标签自己就是 holder（回退失败/suspended 后重进）时不恢复——
      // 它本就没有有效心跳，恢复会造成未进场先续租。
      if (previousHolder != null &&
          !selfWasHolder &&
          _ready.contains(previousHolder.tabId)) {
        final id = _accountIds[previousHolder.tabId];
        if (id != null) {
          _startHeartbeat(previousHolder, id, groupKey);
        }
      }
      return PresenceClaimResult.failure(
        reason: result.reason ?? PresenceFailureReason.enterFailed,
        message: result.message,
      );
    }

    // HTTP 成功后才迁移仲裁状态
    arbiter.claim(tab.tabId);
    _accountIds[tab.tabId] = entered.accountId;
    _lastEnterStatus[tab.tabId] =
        Map<String, Object?>.from(entered.status);
    if (previousHolder != null) {
      _ready.remove(previousHolder.tabId);
    }
    _ready.add(tab.tabId);
    if (tab.isClosed) {
      // 在途进房期间标签已被单关（控制器销毁、其 release 在串行链上紧随
      // 其后）：不再 apply / 启心跳，避免拉起无人回收的弹幕连接；服务端
      // 进场由随后的 release 发 exit 收口并触发幸存者接管。
      Log.logPrint('presence: 进房在途时标签已关闭，跳过 apply: ${tab.tabId}');
    } else {
      if (entered.detail != null) {
        _pendingApplyReplay.remove(tab.tabId);
        try {
          await tab.applyAccountEnter(
            accountDetail: entered.detail!,
            guardStatus: entered.status,
            reentered: false,
          );
        } catch (e) {
          // 服务端已进场，以仲裁/心跳为准；弹幕侧重连失败只记日志
          Log.logPrint('presence: applyAccountEnter 失败: $e');
        }
      } else {
        // 账号视角未开（挂机/详情降级）：标记待补放，下次短路 claim
        // 补 applyReentered 开视角
        _pendingApplyReplay.add(tab.tabId);
      }
      _startHeartbeat(tab, entered.accountId, groupKey);
    }

    if (previousHolder != null &&
        !selfWasHolder &&
        !tab.isClosed &&
        !previousHolder.isClosed) {
      // best-effort：不阻塞 claim 返回；播放不中断，游客详情/弹幕重连失败
      // 只记日志（spec 7.5）
      unawaited(
        previousHolder
            .applyYieldToGuest()
            .catchError((Object e, StackTrace s) {
          Log.logPrint('presence: 让位降级失败: $e');
        }),
      );
    }
    return const PresenceClaimResult.granted();
  }

  /// 关闭标签（close 语义）：持有者发 exitRoom，次新标签自动接管
  Future<void> release(String tabId) =>
      _serialized(() => _remove(tabId, emitExit: true));

  /// 跨窗移出（detach 语义，M4 接线）：持有者停心跳、不发 exitRoom
  Future<void> detach(String tabId) =>
      _serialized(() => _remove(tabId, emitExit: false));

  /// tabId 是否在网关有端口（含栈中非 holder、suspended；非抖音/纯游客 false）
  bool isTrackedTab(String tabId) => _tabs.containsKey(tabId);

  /// 当前端口缓存的 guard 三元组（主→子迁移时复制给新 RemotePresenceTab）
  ({String roomId, String webRid, Map<String, Object?> extra})?
      currentGuardArgsFor(String tabId) {
    final tab = _tabs[tabId];
    if (tab == null) return null;
    return (
      roomId: tab.guardRoomId,
      webRid: tab.guardWebRid,
      extra: tab.guardExtraArgs(),
    );
  }

  /// 跨窗迁移：仲裁栈/holder/accountId/_ready/服务端会话/心跳节奏全不动，
  /// 仅把 tabId 的端口换成 [newPort]（null=端口已由 bindTab 换好的主窗路径），
  /// 重挂心跳 Timer（cancel+periodic，零 HTTP）并在新端口复刻账号态。
  Future<void> rehome(String tabId, {DouyinPresenceTab? newPort}) =>
      _serialized(() => _rehome(tabId, newPort));

  Future<void> _rehome(String tabId, DouyinPresenceTab? newPort) async {
    // 必须先判定在跟踪：未知 tab 整体 no-op，不得借换端口绑定进网关
    final existing = _tabs[tabId];
    if (existing == null) return; // 非抖音/纯游客：网关无事可做
    if (newPort != null) {
      _tabs[tabId] = newPort;
    }
    final tab = _tabs[tabId]!;
    // 跨窗迁移不改变房间归属：组键沿用原值
    final groupKey = _tabGroup[tabId];
    if (groupKey == null) return;
    final arbiter = _groups[groupKey];
    if (arbiter == null) return;
    final holderReady = arbiter.holder == tabId && _ready.contains(tabId);
    if (!holderReady) return; // guest/suspended：新窗本就是游客态
    final accountId = _accountIds[tabId];
    if (accountId != null) {
      _startHeartbeat(tab, accountId, groupKey); // 零 HTTP：旧 Timer cancel、新 Timer 起
    }
    if (tab.isClosed) return;
    final status = _lastEnterStatus[tabId];
    if (status == null) return;
    _pendingApplyReplay.add(tabId);
    try {
      await tab.applyReentered(Map<String, dynamic>.from(status));
      _pendingApplyReplay.remove(tabId);
    } catch (e) {
      // 不回滚：会话/心跳仍健康；下次 claim 短路补放，再失败由用户写动作驱动
      Log.logPrint('presence: 迁移复刻账号态失败: $e');
    }
  }

  Future<void> _replayEnter(DouyinPresenceTab tab) async {
    final status = _lastEnterStatus[tab.tabId];
    if (status == null) {
      _pendingApplyReplay.remove(tab.tabId);
      return;
    }
    try {
      await tab.applyReentered(Map<String, dynamic>.from(status));
      _pendingApplyReplay.remove(tab.tabId);
    } catch (e) {
      _pendingApplyReplay.add(tab.tabId);
      Log.logPrint('presence: claim 短路补放复刻失败: $e');
    }
  }

  Future<void> _remove(String tabId, {required bool emitExit}) async {
    final tab = _tabs[tabId];
    final accountId = _accountIds[tabId];
    final groupKey = _tabGroup[tabId];
    if (groupKey == null) {
      // 未知 tab：不在任何房间组里，无仲裁状态可迁移，只清残留
      _tabs.remove(tabId);
      _accountIds.remove(tabId);
      _ready.remove(tabId);
      _lastEnterStatus.remove(tabId);
      _pendingApplyReplay.remove(tabId);
      return;
    }
    final arbiter = _arbiterFor(groupKey);
    // 必须在 arbiter 摘栈前快照：detach 唯一持有者且无 fallback 时
    // transition 的 exits/enters 均为 null，会命中下方早退导致 Timer 残留（#4）
    final wasHolder = arbiter.holder == tabId;
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _tabGroup.remove(tabId);
    _accountIds.remove(tabId);
    _ready.remove(tabId);
    _lastEnterStatus.remove(tabId);
    _pendingApplyReplay.remove(tabId);
    if (wasHolder) {
      _heartbeatTimers[groupKey]?.cancel();
      _heartbeatTimers.remove(groupKey);
    }
    if (transition == null) {
      return; // 未知 tab
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 非持有者仅出栈 / detach 唯一持有者无 fallback：心跳已在上方取消
    }
    _heartbeatTimers[groupKey]?.cancel();

    // 同一服务端浏览器页面会话：先 exit（页面回首页）再让 fallback enter，
    // 顺序反了 exit 可能作用于 fallback 刚进入的房间。
    if (emitExit && transition.exits != null && tab != null) {
      await _exitRoom(tab, accountId);
    }
    if (transition.enters != null) {
      await _applyFallback(transition.enters!, groupKey);
    }
  }

  /// 批量关闭（关闭其他/右侧/全部）：按房间分组一次性摘栈，每组至多一次 exit、
  /// 至多一次幸存者接管。必须在这批标签的控制器被销毁**之前**调用：
  /// 摘栈后控制器 onClose 的 release 全部命中未知 tab no-op。
  @override
  Future<void> batchRelease(Set<String> tabIds) =>
      _serialized(() => _batchRelease(tabIds));

  Future<void> _batchRelease(Set<String> tabIds) async {
    if (tabIds.isEmpty) return;
    // 跨房间的批次按组分别结算：每个房间组各自退自己的 holder
    final byGroup = <String, Set<String>>{};
    for (final id in tabIds) {
      final groupKey = _tabGroup[id];
      if (groupKey == null) continue;
      (byGroup[groupKey] ??= <String>{}).add(id);
    }
    if (byGroup.isEmpty) return;
    for (final groupKey in byGroup.keys) {
      final ids = byGroup[groupKey]!;
      final arbiter = _arbiterFor(groupKey);
      final holderId = arbiter.holder;
      final holderInBatch = holderId != null && ids.contains(holderId);
      final exitTab = holderInBatch ? _tabs[holderId] : null;
      final exitAccount = exitTab == null ? null : _accountIds[holderId];

      final transition = arbiter.releaseMany(ids);
      for (final id in ids) {
        _tabs.remove(id);
        _tabGroup.remove(id);
        _accountIds.remove(id);
        _ready.remove(id);
        _lastEnterStatus.remove(id);
        _pendingApplyReplay.remove(id);
      }
      if (transition == null) {
        continue; // 组内没有任何 claimant
      }
      if (transition.exits == null && transition.enters == null) {
        continue; // 原 holder 不在批内：心跳归属不变
      }
      _heartbeatTimers[groupKey]?.cancel();
      if (exitTab != null) {
        await _exitRoom(exitTab, exitAccount);
      }
      if (transition.enters != null) {
        await _applyFallback(transition.enters!, groupKey);
      }
    }
  }

  // —— 写动作进入同一串行域（spec §6.5，M3 记账 #2）——

  Future<PresenceSendResult> sendDanmakuAsHolder({
    required String tabId,
    required String content,
  }) =>
      _serialized(() => _sendDanmakuAsHolder(tabId, content));

  Future<PresenceSendResult> sendActionAsHolder({
    required String tabId,
    required String action,
  }) =>
      _serialized(() => _sendActionAsHolder(tabId, action));

  /// 非 holder / 不在 _ready：零 HTTP 直接 not_holder；
  /// accountId 缺失：not_login。404 重注册一次（与控制器旧策略一致）。
  /// holder 判定按房间组：本标签须是**本房间**的持有者。
  Future<PresenceSendResult> _sendDanmakuAsHolder(
    String tabId,
    String content,
  ) async {
    final tab = _tabs[tabId];
    if (tab == null || !_isRoomHolder(tabId)) {
      return PresenceSendResult.notHolder;
    }
    final accountId = _accountIds[tabId];
    if (accountId == null) {
      return const PresenceSendResult(
        success: false,
        code: kPresenceCodeNotLogin,
      );
    }
    try {
      Future<Map<String, dynamic>> once(String id,
          {bool retried = false}) async {
        try {
          return await _guard.sendDanmaku(
            platform: Constant.kDouyin,
            accountId: id,
            roomId: tab.guardRoomId,
            webRid: tab.guardWebRid,
            content: content,
            extra: tab.guardExtraArgs(),
          );
        } on DioException catch (e) {
          if (e.response?.statusCode == 404 && !retried) {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null) {
              _accountIds[tabId] = newId;
              return once(newId, retried: true);
            }
          }
          rethrow;
        }
      }

      final data = await once(accountId);
      return PresenceSendResult(
        success: data['success'] == true,
        code: data['platformCode']?.toString(),
        message: data['message']?.toString(),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = body is Map ? body['message'] : null;
      return PresenceSendResult(
        success: false,
        message: msg is String && msg.isNotEmpty ? msg : '网络请求失败',
      );
    } catch (e) {
      Log.logPrint('presence: holder 弹幕发送失败: $e');
      return const PresenceSendResult(success: false, message: '网络请求失败');
    }
  }

  /// 互动动作（like/fans_badge/join_club/light_up）。guard.sendAction
  /// 不带 platform/extra（与 sendDanmaku 区别，勿补参数）。
  Future<PresenceSendResult> _sendActionAsHolder(
    String tabId,
    String action,
  ) async {
    final tab = _tabs[tabId];
    if (tab == null || !_isRoomHolder(tabId)) {
      return PresenceSendResult.notHolder;
    }
    final accountId = _accountIds[tabId];
    if (accountId == null) {
      return const PresenceSendResult(
        success: false,
        code: kPresenceCodeNotLogin,
      );
    }
    try {
      Future<Map<String, dynamic>> once(String id,
          {bool retried = false}) async {
        try {
          return await _guard.sendAction(
            accountId: id,
            roomId: tab.guardRoomId,
            webRid: tab.guardWebRid,
            action: action,
          );
        } on DioException catch (e) {
          if (e.response?.statusCode == 404 && !retried) {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null) {
              _accountIds[tabId] = newId;
              return once(newId, retried: true);
            }
          }
          rethrow;
        }
      }

      final data = await once(accountId);
      return PresenceSendResult(
        success: data['success'] == true,
        code: data['platformCode']?.toString(),
        message: data['message']?.toString(),
      );
    } on DioException catch (e) {
      final body = e.response?.data;
      final msg = body is Map ? body['message'] : null;
      return PresenceSendResult(
        success: false,
        message: msg is String && msg.isNotEmpty ? msg : '网络请求失败',
      );
    } catch (e) {
      Log.logPrint('presence: holder 互动动作失败: $e');
      return const PresenceSendResult(success: false, message: '操作失败');
    }
  }

  /// 测试接缝：构造 holder+ready 但 accountId 缺失的 not_login 分支
  /// （生产中 ready 与 accountId 同置，该分支为防御性不可达，靠接缝验证）。
  @visibleForTesting
  void debugDropAccountId(String tabId) => _accountIds.remove(tabId);

  /// 测试接缝：查询补放待办（MINOR-1 竞态断言用）
  @visibleForTesting
  bool hasPendingApplyReplay(String tabId) => _pendingApplyReplay.contains(tabId);

  /// 幸存者重新进场并接管该房间组的心跳；进场失败时 holder 已迁移但不在
  /// _ready 中、心跳暂停，用户在该标签的下一次写动作经 claim 重走完整进场序列。
  Future<void> _applyFallback(String fallbackId, String groupKey) async {
    final fallback = _tabs[fallbackId];
    if (fallback == null) {
      return;
    }
    final result = await _performEnter(fallback);
    final entered = result.outcome;
    if (entered == null) {
      _ready.remove(fallbackId);
      Log.logPrint('presence: 回退接管进场失败，等待用户主动操作');
      return;
    }
    _accountIds[fallbackId] = entered.accountId;
    _lastEnterStatus[fallbackId] =
        Map<String, Object?>.from(entered.status);
    _ready.add(fallbackId);
    if (fallback.isClosed) {
      Log.logPrint('presence: 回退接管时幸存者标签已关闭，跳过 apply: $fallbackId');
    } else {
      if (entered.detail != null) {
        _pendingApplyReplay.remove(fallbackId);
        try {
          await fallback.applyAccountEnter(
            accountDetail: entered.detail!,
            guardStatus: entered.status,
            reentered: true,
          );
        } catch (e) {
          Log.logPrint('presence: 回退接管 apply 失败: $e');
        }
      } else {
        // 账号视角未开：标记待补放，下次短路 claim 补 applyReentered
        _pendingApplyReplay.add(fallbackId);
      }
      _startHeartbeat(fallback, entered.accountId, groupKey);
    }
  }

  DouyinPresenceTab? _currentHolderTab(String groupKey) {
    final id = _groups[groupKey]?.holder;
    return id == null ? null : _tabs[id];
  }

  /// 本标签是否是**本房间**的持有者（且已完整进场）
  bool _isRoomHolder(String tabId) {
    final groupKey = _tabGroup[tabId];
    if (groupKey == null) return false;
    final arbiter = _groups[groupKey];
    if (arbiter == null) return false;
    return arbiter.holder == tabId && _ready.contains(tabId);
  }

  Future<void> _exitRoom(DouyinPresenceTab tab, String? accountId) async {
    // SSR 骨架房抖音 args.roomId 为空：没有可退的服务端房间，不发 exit（#6）
    if (tab.guardRoomId.isEmpty) {
      return;
    }
    try {
      final id = accountId ?? _guard.savedAccountId(Constant.kDouyin);
      if (id == null) {
        return;
      }
      await _guard.exitRoom(
        accountId: id,
        roomId: tab.guardRoomId,
        webRid: tab.guardWebRid,
        extra: tab.guardExtraArgs(),
      );
    } catch (e) {
      Log.logPrint('弹幕服务退出直播间失败: $e');
    }
  }

  /// 账号进场 HTTP 序列：登录态 → 配置 → ensureAccount →
  /// enterRoom（404 重注册一次）。账号详情尽力获取，失败不否决进场
  /// （发送弹幕/送礼/挂时长只需账号在房）；失败 outcome 为 null，reason
  /// 给细分原因（未登录/未配置/guard 进场失败）。holdOnly（挂机）不读
  /// 账号详情，账号视角待后续完整 claim 补放。
  Future<({_EnterOutcome? outcome, PresenceFailureReason? reason, String? message})>
      _performEnter(DouyinPresenceTab tab, {bool holdOnly = false}) async {
    LiveRoomDetail? detail;
    if (holdOnly) {
      detail = null;
    } else {
      try {
        detail = await tab.fetchAccountDetail();
      } catch (e) {
        Log.logPrint('presence: 账号详情获取失败，降级为仅账号在房: $e');
        detail = null;
      }
    }
    // 登录态门在配置门之前：未登录时不计"未配置"，文案指向主窗登录
    final loggedIn = _isAccountLoggedIn?.call() ?? true;
    if (!loggedIn) {
      return (
        outcome: null,
        reason: PresenceFailureReason.notLoggedIn,
        message: null,
      );
    }
    if (!_guard.configured) {
      return (
        outcome: null,
        reason: PresenceFailureReason.notConfigured,
        message: null,
      );
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return (
          outcome: null,
          reason: PresenceFailureReason.enterFailed,
          message: null,
        );
      }
      Map<String, dynamic> status;
      try {
        status = await _guard.enterRoom(
          accountId: accountId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      } on DioException catch (e) {
        if (e.response?.statusCode != 404) {
          rethrow;
        }
        // 服务端会话丢失：重新注册后再进一次
        final newId = await _guard.reregister(Constant.kDouyin);
        if (newId == null) {
          return (
            outcome: null,
            reason: PresenceFailureReason.enterFailed,
            message: null,
          );
        }
        accountId = newId;
        status = await _guard.enterRoom(
          accountId: newId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      }
      return (
        outcome: _EnterOutcome(
          accountId: accountId,
          status: status,
          detail: detail,
        ),
        reason: null,
        message: null,
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return (
        outcome: null,
        reason: PresenceFailureReason.enterFailed,
        message: _serverMessageOf(e),
      );
    }
  }

  /// 心跳失去 holder 资格或重注册失败的统一收口：cancel 该房间组 Timer、
  /// 移出 _ready、标 suspended、通知标签（best-effort）。inRoom!=true 与
  /// 404-reregister 失败共用此路径。
  Future<void> _suspend(DouyinPresenceTab tab, String groupKey) async {
    _heartbeatTimers[groupKey]?.cancel();
    Log.logPrint('presence: 心跳 suspended 收口: ${tab.tabId}');
    _ready.remove(tab.tabId);
    _arbiterFor(groupKey).markSuspended(tab.tabId);
    try {
      await tab.applySuspended();
    } catch (e) {
      Log.logPrint('presence: applySuspended 失败: $e');
    }
  }

  void _startHeartbeat(DouyinPresenceTab tab, String accountId, String groupKey) {
    _heartbeatTimers[groupKey]?.cancel();
    final arbiter = _arbiterFor(groupKey);

    Future<void> beat() async {
      // 上一拍仍在途（RTT > 间隔）：跳过本拍，不并发 heartbeat（#5）
      if (_beatInFlight[groupKey] == true) return;
      // 回调延迟期间 holder 可能已切换：非 holder 不再续租
      if (arbiter.holder != tab.tabId) {
        return;
      }
      _beatInFlight[groupKey] = true;
      try {
        final data = await _guard.heartbeat(
          accountId: accountId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
        if (arbiter.holder != tab.tabId) {
          return;
        }
        if (data['inRoom'] != true) {
          // 同账号在外部端进入别的房间：suspended 收口，不抢回
          await _suspend(tab, groupKey);
          return;
        }
      } on DioException catch (e) {
        if (e.response?.statusCode == 404) {
          // 服务端会话丢失：reregister 一次。成功且仍为 holder → 同步
          // accountId 缓存并重挂心跳；失败/已不持有 → suspended 收口，
          // 不再让 Timer 空转（spec §6.3，替代 M3 只记日志的旧行为）。
          try {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (arbiter.holder != tab.tabId) {
              // 在途期间已让位：新 holder 自带心跳，旧拍直接放弃
              return;
            }
            if (newId != null) {
              _accountIds[tab.tabId] = newId;
              _startHeartbeat(tab, newId, groupKey);
            } else {
              await _suspend(tab, groupKey);
            }
          } catch (e2) {
            Log.logPrint('弹幕服务心跳重注册失败: $e2');
            if (arbiter.holder == tab.tabId) {
              await _suspend(tab, groupKey);
            }
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
      } catch (e) {
        // 响应体畸形等：只记日志，不让单个 beat 成为未处理 async 异常
        Log.logPrint('弹幕服务心跳异常: $e');
      } finally {
        _beatInFlight[groupKey] = false;
      }
    }

    _heartbeatTimers[groupKey] = Timer.periodic(heartbeatInterval, (_) => beat());
    _scheduleWatchdog();
  }

  /// 看门狗：自续期单次 Timer（非 periodic，不干扰业务心跳的 Timer 计数）。
  /// 定期核对每个房间组的持有者是否仍有活跃心跳 Timer，缺失即补挂。
  void _scheduleWatchdog() {
    if (_watchdogTimer != null) return;
    _watchdogTimer = Timer(watchdogInterval, _watchdogTick);
  }

  void _watchdogTick() {
    _watchdogTimer = null;
    // 巡检入串行链：不与在途 claim 抢同房组心跳，避免把「旧 holder 让位
    // 中」的房间重新拉回旧 holder。
    unawaited(
      _serialized(_ensureGroupHeartbeats).catchError((Object e, StackTrace s) {
        Log.logPrint('presence: 心跳看门狗异常: $e');
      }),
    );
    _scheduleWatchdog();
  }

  /// 补挂所有缺失的房间组心跳（持有者已就绪但心跳 Timer 不在）。
  Future<void> _ensureGroupHeartbeats() async {
    for (final entry in _groups.entries) {
      final groupKey = entry.key;
      final holder = entry.value.holder;
      if (holder == null) continue;
      if (!_ready.contains(holder)) continue;
      final timer = _heartbeatTimers[groupKey];
      if (timer != null && timer.isActive) continue;
      final tab = _tabs[holder];
      if (tab == null || tab.isClosed) continue;
      _ensureGroupHeartbeat(groupKey, tab);
    }
  }

  /// 保证某房间组的心跳存活：持有者已就绪、账号 id 已知但心跳 Timer 缺失
  /// 时重新挂上。服务端 heartbeat 会自行重新进房，无需用户再次操作。
  void _ensureGroupHeartbeat(String groupKey, DouyinPresenceTab tab) {
    final timer = _heartbeatTimers[groupKey];
    if (timer != null && timer.isActive) return;
    final accountId = _accountIds[tab.tabId];
    if (accountId == null) return;
    Log.logPrint('presence: 补挂房间组心跳: $groupKey');
    _startHeartbeat(tab, accountId, groupKey);
  }

  @visibleForTesting
  void stopHeartbeatForTesting() {
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    for (final timer in _heartbeatTimers.values) {
      timer.cancel();
    }
    _heartbeatTimers.clear();
  }

  /// 仅掐断房间组心跳（保留看门狗）：模拟心跳 Timer 意外丢失的场景。
  @visibleForTesting
  void dropHeartbeatTimersForTesting() {
    for (final timer in _heartbeatTimers.values) {
      timer.cancel();
    }
    _heartbeatTimers.clear();
  }

  @override
  void onClose() {
    stopHeartbeatForTesting();
    super.onClose();
  }
}

class _EnterOutcome {
  _EnterOutcome({
    required this.accountId,
    required this.status,
    required this.detail,
  });

  final String accountId;
  final Map<String, dynamic> status;
  /// 账号详情尽力获取：为 null 表示读详情失败，账号在房/发送/挂时长照常，
  /// 仅账号视角（详情/账号弹幕）不可用
  final LiveRoomDetail? detail;
}

/// 服务端拒绝原因原文（如「会话数已达上限」）：取自错误体的 message 字段。
/// 非 Dio 异常或无正文时为 null，调用方据此回退到兜底文案。
String? _serverMessageOf(Object e) {
  if (e is! DioException) return null;
  final data = e.response?.data;
  if (data is! Map) return null;
  final message = data['message'];
  return message is String && message.isNotEmpty ? message : null;
}
