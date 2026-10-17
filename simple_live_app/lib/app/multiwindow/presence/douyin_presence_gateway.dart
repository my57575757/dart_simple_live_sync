import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'presence_arbiter.dart';
import 'presence_claimant.dart';
import 'presence_client.dart';

/// 抖音登录心跳全局仲裁者（每引擎一个；M3 仅主引擎在 kShell binding 实例化）。
///
/// 全应用唯一心跳 Timer：只有 arbiter.holder 的房间被续租。
/// 账号态 HTTP（ensureAccount/enterRoom/heartbeat/exitRoom/reregister）
/// 与 404 重注册全部收口于此；账号详情取数经 DouyinPresenceTab 端口。
///
/// 所有变更操作经 [_serialized] 串行：claim 的 HTTP 在途时到达的
/// release/batchRelease 会排队到进场完成之后执行，避免迟到的成功结果
/// 把已关闭标签变成孤儿 holder。
class DouyinPresenceGateway extends GetxService {
  DouyinPresenceGateway(
    this._guard, {
    this.heartbeatInterval = const Duration(seconds: 20),
    bool Function()? isAccountLoggedIn,
  }) : _isAccountLoggedIn = isAccountLoggedIn;

  final GuardServerService _guard;
  final Duration heartbeatInterval;
  final bool Function()? _isAccountLoggedIn;
  final PresenceArbiter arbiter = PresenceArbiter();

  final Map<String, DouyinPresenceTab> _tabs = {};
  final Map<String, String> _accountIds = {};

  /// 已完整进场成功且持有心跳的 tabId。holder 不在其中时（回退接管失败、
  /// 被外部端抢占 suspended），claim 必须重走完整进场序列而不能短路。
  final Set<String> _ready = <String>{};

  Timer? _heartbeatTimer;

  /// 心跳拍在途标志：heartbeat RTT 超过间隔时跳过重叠拍，杜绝并发续租（#5）
  bool _beatInFlight = false;

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

  String? get holderTabId => arbiter.holder;

  /// 控制器 onInit 绑定标签端口（同 tabId 重复绑定幂等）
  void bindTab(DouyinPresenceTab tab) {
    _tabs[tab.tabId] = tab;
  }

  bool hasClaim(String tabId) => arbiter.isClaimed(tabId);

  /// 显式进入 / 抢占（点「进入直播间」、发弹幕、点赞等）
  Future<PresenceClaimResult> claim(DouyinPresenceTab tab) =>
      _serialized(() => _claim(tab));

  Future<PresenceClaimResult> _claim(DouyinPresenceTab tab) async {
    bindTab(tab);
    if (arbiter.holder == tab.tabId && _ready.contains(tab.tabId)) {
      return const PresenceClaimResult.granted();
    }
    final previousHolder = _currentHolderTab();
    final selfWasHolder = arbiter.holder == tab.tabId;
    // enter 成功前先停心跳：否则旧 holder 的下一拍会在服务端把浏览器页面
    // 抢回旧房间，造成两个标签 flip-flop。
    _heartbeatTimer?.cancel();

    final result = await _performEnter(tab);
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
          _startHeartbeat(previousHolder, id);
        }
      }
      return PresenceClaimResult.failure(
        reason: result.reason ?? PresenceFailureReason.enterFailed,
      );
    }

    // HTTP 成功后才迁移仲裁状态
    arbiter.claim(tab.tabId);
    _accountIds[tab.tabId] = entered.accountId;
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
      try {
        await tab.applyAccountEnter(
          accountDetail: entered.detail,
          guardStatus: entered.status,
          reentered: false,
        );
      } catch (e) {
        // 服务端已进场，以仲裁/心跳为准；弹幕侧重连失败只记日志
        Log.logPrint('presence: applyAccountEnter 失败: $e');
      }
      _startHeartbeat(tab, entered.accountId);
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

  Future<void> _remove(String tabId, {required bool emitExit}) async {
    final tab = _tabs[tabId];
    final accountId = _accountIds[tabId];
    // 必须在 arbiter 摘栈前快照：detach 唯一持有者且无 fallback 时
    // transition 的 exits/enters 均为 null，会命中下方早退导致 Timer 残留（#4）
    final wasHolder = arbiter.holder == tabId;
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _accountIds.remove(tabId);
    _ready.remove(tabId);
    if (wasHolder) {
      _heartbeatTimer?.cancel();
    }
    if (transition == null) {
      return; // 未知 tab
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 非持有者仅出栈 / detach 唯一持有者无 fallback：心跳已在上方取消
    }
    _heartbeatTimer?.cancel();

    // 同一服务端浏览器页面会话：先 exit（页面回首页）再让 fallback enter，
    // 顺序反了 exit 可能作用于 fallback 刚进入的房间。
    if (emitExit && transition.exits != null && tab != null) {
      await _exitRoom(tab, accountId);
    }
    if (transition.enters != null) {
      await _applyFallback(transition.enters!);
    }
  }

  /// 批量关闭（关闭其他/右侧/全部）：一次性摘栈，整批至多一次 exit、
  /// 至多一次幸存者接管。必须在这批标签的控制器被销毁**之前**调用：
  /// 摘栈后控制器 onClose 的 release 全部命中未知 tab no-op。
  Future<void> batchRelease(Set<String> tabIds) =>
      _serialized(() => _batchRelease(tabIds));

  Future<void> _batchRelease(Set<String> tabIds) async {
    if (tabIds.isEmpty) return;
    final holderId = arbiter.holder;
    final holderInBatch = holderId != null && tabIds.contains(holderId);
    final exitTab = holderInBatch ? _tabs[holderId] : null;
    final exitAccount =
        exitTab == null ? null : _accountIds[holderId];

    final transition = arbiter.releaseMany(tabIds);
    if (transition == null) {
      return; // 批内没有任何 claimant
    }
    for (final id in tabIds) {
      _tabs.remove(id);
      _accountIds.remove(id);
      _ready.remove(id);
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 原 holder 不在批内：心跳归属不变
    }
    _heartbeatTimer?.cancel();
    if (exitTab != null) {
      await _exitRoom(exitTab, exitAccount);
    }
    if (transition.enters != null) {
      await _applyFallback(transition.enters!);
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
  Future<PresenceSendResult> _sendDanmakuAsHolder(
    String tabId,
    String content,
  ) async {
    final tab = _tabs[tabId];
    if (tab == null ||
        arbiter.holder != tabId ||
        !_ready.contains(tabId)) {
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
    if (tab == null ||
        arbiter.holder != tabId ||
        !_ready.contains(tabId)) {
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

  /// 幸存者重新进场并接管唯一心跳；进场失败时 holder 已迁移但不在 _ready
  /// 中、心跳暂停，用户在该标签的下一次写动作经 claim 重走完整进场序列。
  Future<void> _applyFallback(String fallbackId) async {
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
    _ready.add(fallbackId);
    if (fallback.isClosed) {
      Log.logPrint('presence: 回退接管时幸存者标签已关闭，跳过 apply: $fallbackId');
    } else {
      try {
        await fallback.applyAccountEnter(
          accountDetail: entered.detail,
          guardStatus: entered.status,
          reentered: true,
        );
      } catch (e) {
        Log.logPrint('presence: 回退接管 apply 失败: $e');
      }
      _startHeartbeat(fallback, entered.accountId);
    }
  }

  DouyinPresenceTab? _currentHolderTab() {
    final id = arbiter.holder;
    return id == null ? null : _tabs[id];
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

  /// 账号进场 HTTP 序列：账号详情 → 登录态 → 配置 → ensureAccount →
  /// enterRoom（404 重注册一次）。失败 outcome 为 null，reason 给细分原因。
  Future<({_EnterOutcome? outcome, PresenceFailureReason? reason})>
      _performEnter(DouyinPresenceTab tab) async {
    final LiveRoomDetail detail;
    try {
      detail = await tab.fetchAccountDetail();
    } catch (e) {
      return (outcome: null, reason: PresenceFailureReason.detailFailed);
    }
    // 登录态门在配置门之前：未登录时不计"未配置"，文案指向主窗登录
    final loggedIn = _isAccountLoggedIn?.call() ?? true;
    if (!loggedIn) {
      return (outcome: null, reason: PresenceFailureReason.notLoggedIn);
    }
    if (!_guard.configured) {
      return (outcome: null, reason: PresenceFailureReason.notConfigured);
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return (outcome: null, reason: PresenceFailureReason.enterFailed);
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
          return (outcome: null, reason: PresenceFailureReason.enterFailed);
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
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return (outcome: null, reason: PresenceFailureReason.enterFailed);
    }
  }

  /// 心跳失去 holder 资格或重注册失败的统一收口：cancel Timer、移出
  /// _ready、标 suspended、通知标签（best-effort）。inRoom!=true 与
  /// 404-reregister 失败共用此路径。
  Future<void> _suspend(DouyinPresenceTab tab) async {
    _heartbeatTimer?.cancel();
    _ready.remove(tab.tabId);
    arbiter.markSuspended(tab.tabId);
    try {
      await tab.applySuspended();
    } catch (e) {
      Log.logPrint('presence: applySuspended 失败: $e');
    }
  }

  void _startHeartbeat(DouyinPresenceTab tab, String accountId) {
    _heartbeatTimer?.cancel();

    Future<void> beat() async {
      // 上一拍仍在途（RTT > 间隔）：跳过本拍，不并发 heartbeat（#5）
      if (_beatInFlight) return;
      // 回调延迟期间 holder 可能已切换：非 holder 不再续租
      if (arbiter.holder != tab.tabId) {
        return;
      }
      _beatInFlight = true;
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
          await _suspend(tab);
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
              _startHeartbeat(tab, newId);
            } else {
              await _suspend(tab);
            }
          } catch (e2) {
            Log.logPrint('弹幕服务心跳重注册失败: $e2');
            if (arbiter.holder == tab.tabId) {
              await _suspend(tab);
            }
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
      } catch (e) {
        // 响应体畸形等：只记日志，不让单个 beat 成为未处理 async 异常
        Log.logPrint('弹幕服务心跳异常: $e');
      } finally {
        _beatInFlight = false;
      }
    }

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => beat());
  }

  @visibleForTesting
  void stopHeartbeatForTesting() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  @override
  void onClose() {
    _heartbeatTimer?.cancel();
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
  final LiveRoomDetail detail;
}
