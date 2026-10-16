import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'presence_arbiter.dart';
import 'presence_claimant.dart';

/// 抖音登录心跳全局仲裁者（每引擎一个；M3 仅主引擎在 kShell binding 实例化）。
///
/// 全应用唯一心跳 Timer：只有 arbiter.holder 的房间被续租。
/// 账号态 HTTP（ensureAccount/enterRoom/heartbeat/exitRoom/reregister）
/// 与 404 重注册全部收口于此；账号详情取数经 DouyinPresenceTab 端口。
///
/// 所有变更操作经 [_serialized] 串行：claim 的 HTTP 在途时到达的
/// release/batchRelease 会排队到进场完成之后执行，避免迟到的成功结果
/// 把已关闭标签变成孤儿 holder。
class DouyinPresenceGateway {
  DouyinPresenceGateway(
    this._guard, {
    this.heartbeatInterval = const Duration(seconds: 20),
  });

  final GuardServerService _guard;
  final Duration heartbeatInterval;
  final PresenceArbiter arbiter = PresenceArbiter();

  final Map<String, DouyinPresenceTab> _tabs = {};
  final Map<String, String> _accountIds = {};

  /// 已完整进场成功且持有心跳的 tabId。holder 不在其中时（回退接管失败、
  /// 被外部端抢占 suspended），claim 必须重走完整进场序列而不能短路。
  final Set<String> _ready = <String>{};

  Timer? _heartbeatTimer;

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
      return PresenceClaimResult.failure(detailFailed: result.detailFailed);
    }

    // HTTP 成功后才迁移仲裁状态
    arbiter.claim(tab.tabId);
    _accountIds[tab.tabId] = entered.accountId;
    if (previousHolder != null) {
      _ready.remove(previousHolder.tabId);
    }
    _ready.add(tab.tabId);
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

    if (previousHolder != null) {
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
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _accountIds.remove(tabId);
    _ready.remove(tabId);
    if (transition == null) {
      return; // 未知 tab
    }
    if (transition.exits == null && transition.enters == null) {
      return; // 非持有者：仅出栈，零 HTTP
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

  DouyinPresenceTab? _currentHolderTab() {
    final id = arbiter.holder;
    return id == null ? null : _tabs[id];
  }

  Future<void> _exitRoom(DouyinPresenceTab tab, String? accountId) async {
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

  /// 账号进场 HTTP 序列：账号详情 → ensureAccount → enterRoom（404 重注册
  /// 重试一次）。任一步失败 outcome 为 null，detailFailed 区分失败类型。
  Future<({_EnterOutcome? outcome, bool detailFailed})> _performEnter(
      DouyinPresenceTab tab) async {
    final LiveRoomDetail detail;
    try {
      detail = await tab.fetchAccountDetail();
    } catch (e) {
      return (outcome: null, detailFailed: true);
    }
    if (!_guard.configured) {
      return (outcome: null, detailFailed: false);
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return (outcome: null, detailFailed: false);
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
          return (outcome: null, detailFailed: false);
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
        detailFailed: false,
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return (outcome: null, detailFailed: false);
    }
  }

  void _startHeartbeat(DouyinPresenceTab tab, String accountId) {
    _heartbeatTimer?.cancel();

    Future<void> beat({bool retried = false}) async {
      // 回调延迟期间 holder 可能已切换：非 holder 不再续租
      if (arbiter.holder != tab.tabId) {
        return;
      }
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
          // 同账号在外部端进入别的房间：停止心跳、标 suspended，不抢回
          _heartbeatTimer?.cancel();
          _ready.remove(tab.tabId);
          arbiter.markSuspended(tab.tabId);
          tab.applySuspended();
        }
      } on DioException catch (e) {
        if (!retried && e.response?.statusCode == 404) {
          // reregister 自身再抛不会被同级 catch 接住，单独包一层
          try {
            final newId = await _guard.reregister(Constant.kDouyin);
            if (newId != null && arbiter.holder == tab.tabId) {
              // 同步 accountId 缓存，否则该 holder 关闭时 exit 会打到过期账号
              _accountIds[tab.tabId] = newId;
              _startHeartbeat(tab, newId);
            }
          } catch (e2) {
            Log.logPrint('弹幕服务心跳重注册失败: $e2');
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
      } catch (e) {
        // 响应体畸形、applySuspended 抛错等：只记日志，不让单个 beat 的
        // 异常成为未处理 async 异常；Timer 仍在，下一拍继续续租。
        Log.logPrint('弹幕服务心跳异常: $e');
      }
    }

    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) => beat());
  }

  @visibleForTesting
  void stopHeartbeatForTesting() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
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
