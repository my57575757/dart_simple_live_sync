import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../douyin_presence_gateway.dart';
import '../presence_client.dart';
import 'presence_protocol.dart';
import 'remote_presence_tab.dart';

/// 主引擎账号面 presence 服务：解析 pr_ 方法，把远端标签混入唯一网关
/// 仲裁栈；维护 tabId→windowId 死亡对账索引（register 只建索引，
/// 不进栈）；订阅子窗死亡流批量释放。dp_/pr_ 互不解析对方方法。
class MainPresenceService extends GetxService {
  MainPresenceService({
    required this.gateway,
    required this.port,
    required WindowOpenService windowOpenService,
    this.accountDetailFetcher,
    this.cookieReader,
  }) : _windowOpenService = windowOpenService;

  final DouyinPresenceGateway gateway;
  final SubWindowPort port;
  final WindowOpenService _windowOpenService;

  /// 测试接缝：生产为 null，RemotePresenceTab 用主窗 DouyinSite 取详情
  final Future<LiveRoomDetail> Function(String roomId, String shareUrl)?
      accountDetailFetcher;

  /// 测试接缝：生产为 null，apply 当刻读 DouyinAccountService.loginCookie
  final String Function()? cookieReader;

  /// tabId → windowId 死亡对账索引：pr_register 时建立，pr_release/
  /// pr_batch_release/子窗死亡对账时摘除；claim 仅读取校验，不写索引。
  final Map<String, String> _tabWindow = {};

  /// tabId → 远端标签，首次 claim 时建（与 _tabWindow 分离：register
  /// 不建标签、不碰仲裁栈）
  final Map<String, RemotePresenceTab> _remoteTabs = {};

  StreamSubscription<Set<String>>? _closedSub;

  @override
  void onInit() {
    super.onInit();
    _closedSub = _windowOpenService.onChildWindowsClosed
        .listen(_onChildWindowsClosed);
  }

  @override
  void onClose() {
    unawaited(_closedSub?.cancel());
    _closedSub = null;
    super.onClose();
  }

  /// 主窗 method handler 默认分支委托入口（T8 接线）
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case PresenceProtocol.mRegister:
        return _register(arguments);
      case PresenceProtocol.mClaim:
        return _claim(arguments);
      case PresenceProtocol.mRelease:
        return _release(arguments, detach: false);
      case PresenceProtocol.mDetach:
        return _release(arguments, detach: true);
      case PresenceProtocol.mBatchRelease:
        return _batchRelease(arguments);
      case PresenceProtocol.mGuardSend:
        return _guardSend(arguments);
      default:
        return null;
    }
  }

  Future<Object?> _register(Object? arguments) async {
    final call = PresenceProtocol.decodeRegister(arguments);
    if (call == null || call.siteId != Constant.kDouyin) return false;
    // 只建死亡对账索引：不建 RemotePresenceTab、不碰仲裁栈
    _tabWindow[call.tabId] = call.windowId;
    return true;
  }

  Future<Object?> _claim(Object? arguments) async {
    final call = PresenceProtocol.decodeClaim(arguments);
    if (call == null) return false;
    final registeredWindow = _tabWindow[call.tabId];
    if (registeredWindow == null || registeredWindow != call.windowId) {
      return false;
    }
    final existing = _remoteTabs[call.tabId];
    if (existing != null && existing.windowId != call.windowId) {
      existing.markClosed();
      _remoteTabs.remove(call.tabId);
    }
    final tab = _remoteTabs.putIfAbsent(
      call.tabId,
      () => RemotePresenceTab(
        tabId: call.tabId,
        windowId: call.windowId,
        roomId: call.roomId,
        shareUrl: call.shareUrl,
        port: port,
        accountDetailFetcher: accountDetailFetcher,
        cookieReader: cookieReader,
      ),
    );
    tab.updateGuardArgs(
      guardRoomId: call.guardRoomId,
      guardWebRid: call.guardWebRid,
      guardExtra: call.guardExtra,
    );
    final result = await gateway.claim(tab);
    if (result.granted) {
      return PresenceProtocol.encodeClaimOk();
    }
    return PresenceProtocol.encodeClaimFailure(
      result.reason ?? PresenceFailureReason.enterFailed,
    );
  }

  Future<Object?> _release(Object? arguments,
      {required bool detach}) async {
    final call = PresenceProtocol.decodeRelease(arguments);
    if (call == null) return false;
    final registeredWindow = _tabWindow[call.tabId];
    if (registeredWindow == null || registeredWindow != call.windowId) {
      return true; // 未知 tab：幂等
    }
    if (detach) {
      // detach 只摘仲裁栈：不摘索引、不置 closed（M4-4 跨窗拖拽复用）
      await gateway.detach(call.tabId);
      return true;
    }
    _remoteTabs.remove(call.tabId)?.markClosed();
    _tabWindow.remove(call.tabId);
    await gateway.release(call.tabId);
    return true;
  }

  Future<Object?> _batchRelease(Object? arguments) async {
    final call = PresenceProtocol.decodeBatchRelease(arguments);
    if (call == null) return false;
    final ids = <String>{};
    for (final tabId in call.tabIds) {
      if (_tabWindow[tabId] != call.windowId) continue;
      _remoteTabs.remove(tabId)?.markClosed();
      _tabWindow.remove(tabId);
      ids.add(tabId);
    }
    if (ids.isNotEmpty) {
      await gateway.batchRelease(ids);
    }
    return true;
  }

  Future<Object?> _guardSend(Object? arguments) async {
    final call = PresenceProtocol.decodeGuardSend(arguments);
    if (call == null) return false;
    if (_tabWindow[call.tabId] != call.windowId) {
      return PresenceProtocol.encodeSendResult(
          PresenceSendResult.notHolder);
    }
    final result = call.kind == PresenceProtocol.kDanmaku
        ? await gateway.sendDanmakuAsHolder(
            tabId: call.tabId,
            content: call.content!,
          )
        : await gateway.sendActionAsHolder(
            tabId: call.tabId,
            action: call.action!,
          );
    return PresenceProtocol.encodeSendResult(result);
  }

  /// 子窗进程被杀（无临终消息）：汇总已死窗名下登记的全部 tab，
  /// 整批一次摘栈释放，然后清自身索引。
  Future<void> _onChildWindowsClosed(Set<String> windowIds) async {
    final tabIds = <String>{};
    _tabWindow.removeWhere((tabId, windowId) {
      if (!windowIds.contains(windowId)) return false;
      tabIds.add(tabId);
      return true;
    });
    for (final tabId in tabIds) {
      _remoteTabs.remove(tabId)?.markClosed();
    }
    if (tabIds.isNotEmpty) {
      await gateway.batchRelease(tabIds);
    }
  }
}
