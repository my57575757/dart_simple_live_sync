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
  Timer? _heartbeatTimer;

  String? get holderTabId => arbiter.holder;

  /// 控制器 onInit 绑定标签端口（同 tabId 重复绑定幂等）
  void bindTab(DouyinPresenceTab tab) {
    _tabs[tab.tabId] = tab;
  }

  bool hasClaim(String tabId) => arbiter.isClaimed(tabId);

  /// 显式进入 / 抢占（点「进入直播间」、发弹幕、点赞等）
  Future<PresenceClaimResult> claim(DouyinPresenceTab tab) async {
    bindTab(tab);
    if (arbiter.holder == tab.tabId) {
      return const PresenceClaimResult.granted();
    }
    final previousHolder = _currentHolderTab();
    // enter 成功前先停心跳：否则旧 holder 的下一拍会在服务端把浏览器页面
    // 抢回旧房间，造成两个标签 flip-flop。
    _heartbeatTimer?.cancel();

    final entered = await _performEnter(tab);
    if (entered == null) {
      // 仲裁尚未迁移，旧 holder 没有被让位：恢复其心跳
      if (previousHolder != null) {
        final id = _accountIds[previousHolder.tabId];
        if (id != null) {
          _startHeartbeat(previousHolder, id);
        }
      }
      return PresenceClaimResult.failure(detailFailed: _lastDetailFailed);
    }

    // HTTP 成功后才迁移仲裁状态
    arbiter.claim(tab.tabId);
    _accountIds[tab.tabId] = entered.accountId;
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
  Future<void> release(String tabId) => _remove(tabId, emitExit: true);

  /// 跨窗移出（detach 语义，M4 接线）：持有者停心跳、不发 exitRoom
  Future<void> detach(String tabId) => _remove(tabId, emitExit: false);

  Future<void> _remove(String tabId, {required bool emitExit}) async {
    final tab = _tabs[tabId];
    final accountId = _accountIds[tabId];
    final transition =
        emitExit ? arbiter.release(tabId) : arbiter.detach(tabId);
    _tabs.remove(tabId);
    _accountIds.remove(tabId);
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
  Future<void> batchRelease(Set<String> tabIds) async {
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

  /// 幸存者重新进场并接管唯一心跳；进场失败时 holder 已迁移、心跳暂停，
  /// 用户在该标签的下一次写动作会经 claim 重试。
  Future<void> _applyFallback(String fallbackId) async {
    final fallback = _tabs[fallbackId];
    if (fallback == null) {
      return;
    }
    final entered = await _performEnter(fallback);
    if (entered == null) {
      Log.logPrint('presence: 回退接管进场失败，等待用户主动操作');
      return;
    }
    _accountIds[fallbackId] = entered.accountId;
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

  bool _lastDetailFailed = false;

  /// 账号进场 HTTP 序列：账号详情 → ensureAccount → enterRoom（404 重注册
  /// 重试一次）。任一步失败返回 null，[_lastDetailFailed] 区分失败类型。
  Future<_EnterOutcome?> _performEnter(DouyinPresenceTab tab) async {
    _lastDetailFailed = false;
    final LiveRoomDetail detail;
    try {
      detail = await tab.fetchAccountDetail();
    } catch (e) {
      _lastDetailFailed = true;
      return null;
    }
    if (!_guard.configured) {
      return null;
    }
    try {
      var accountId = await _guard.ensureAccount(Constant.kDouyin);
      if (accountId == null) {
        return null;
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
          return null;
        }
        accountId = newId;
        status = await _guard.enterRoom(
          accountId: newId,
          roomId: tab.guardRoomId,
          webRid: tab.guardWebRid,
          extra: tab.guardExtraArgs(),
        );
      }
      return _EnterOutcome(
        accountId: accountId,
        status: status,
        detail: detail,
      );
    } catch (e) {
      Log.logPrint('presence: guard 进场失败: $e');
      return null;
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
          arbiter.markSuspended(tab.tabId);
          tab.applySuspended();
          return;
        }
      } on DioException catch (e) {
        if (!retried && e.response?.statusCode == 404) {
          final newId = await _guard.reregister(Constant.kDouyin);
          if (newId != null && arbiter.holder == tab.tabId) {
            // 同步 accountId 缓存，否则该 holder 关闭时 exit 会打到过期账号
            _accountIds[tab.tabId] = newId;
            _startHeartbeat(tab, newId);
          }
          return;
        }
        Log.logPrint('弹幕服务心跳失败: ${e.message}');
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
