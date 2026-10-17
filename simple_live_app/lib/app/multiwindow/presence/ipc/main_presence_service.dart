import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/multiwindow/window/window_open_service.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../douyin_presence_gateway.dart';
import '../handoff_controller.dart';
import '../presence_client.dart';
import 'presence_protocol.dart';
import 'remote_presence_tab.dart';

class HandoffTimeoutException implements Exception {
  const HandoffTimeoutException();
  @override
  String toString() => 'HandoffTimeoutException';
}

class HandoffSupersededException implements Exception {
  const HandoffSupersededException();
  @override
  String toString() => 'HandoffSupersededException';
}

class HandoffSourceClosedException implements Exception {
  const HandoffSourceClosedException();
  @override
  String toString() => 'HandoffSourceClosedException';
}

class _Handoff {
  _Handoff(this.destWindowId) : completer = Completer<void>();

  final String destWindowId;
  final Completer<void> completer;
  Timer? timer;
  bool settled = false;
}

/// 主引擎账号面 presence 服务：解析 pr_ 方法，把远端标签混入唯一网关
/// 仲裁栈；维护 tabId→windowId 死亡对账索引（register 只建索引，
/// 不进栈）；订阅子窗死亡流批量释放。dp_/pr_ 互不解析对方方法。
class MainPresenceService extends GetxService
    implements PresenceHandoffController {
  MainPresenceService({
    required this.gateway,
    required this.port,
    required WindowOpenService windowOpenService,
    this.accountDetailFetcher,
    this.cookieReader,
    this.credentialReaderFor,
  }) : _windowOpenService = windowOpenService;

  final DouyinPresenceGateway gateway;
  final SubWindowPort port;
  final WindowOpenService _windowOpenService;

  /// 测试接缝：生产为 null，RemotePresenceTab 用主窗 DouyinSite 取详情
  final Future<LiveRoomDetail> Function(String roomId, String shareUrl)?
      accountDetailFetcher;

  /// 测试接缝：生产为 null，apply 当刻读 DouyinAccountService.loginCookie
  final String Function()? cookieReader;

  /// 测试接缝：生产为 null，非抖音 register 后回推凭据时按 siteId 读
  /// 对应账号服务。返回值约定：douyu/huya/bilibili → {'cookie': <String>}；
  /// twitch → {'creds': {oauthToken,userLogin,clientId}}。凭据仅经
  /// pr_apply_enter 单向下发，不得出现在其他协议/日志。
  final Map<String, Object?> Function(String siteId)? credentialReaderFor;

  /// tabId → windowId 死亡对账索引：pr_register 时建立，pr_release/
  /// pr_batch_release/子窗死亡对账时摘除；claim 仅读取校验，不写索引。
  final Map<String, String> _tabWindow = {};

  /// tabId → 远端标签，首次 claim 时建（与 _tabWindow 分离：register
  /// 不建标签、不碰仲裁栈）
  final Map<String, RemotePresenceTab> _remoteTabs = {};

  static const Duration handoffTimeout = Duration(seconds: 10);
  final Map<String, _Handoff> _handoffs = {};

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
    if (call == null) return false;
    // 索引先于一切（既有改挂语义；迁移在途旧窗迟到消息由归属门天然过滤）
    _tabWindow[call.tabId] = call.windowId;

    // 非抖音：只建死亡对账索引 + 回推凭据（M5）；不进仲裁栈、不建 RemoteTab。
    // 凭据仅经 pr_apply_enter 单向下发，best-effort 吞错不阻塞 register。
    if (call.siteId != Constant.kDouyin) {
      unawaited(_pushBorrowedCredentials(call));
      return true;
    }

    final handoff = _handoffs[call.tabId];
    if (handoff != null) {
      if (call.windowId != _windowOpenService.registry.mainWindowId) {
        // 目标必为子窗：无条件换新 RemotePresenceTab。
        // guard 双来源：子→子复制旧 RemoteTab；主→子问网关当前端口要。
        final old = _remoteTabs.remove(call.tabId);
        final guard = old != null
            ? (
                roomId: old.guardRoomId,
                webRid: old.guardWebRid,
                extra: old.guardExtraArgs(),
              )
            : gateway.currentGuardArgsFor(call.tabId);
        old?.markClosed();
        final fresh = RemotePresenceTab(
          tabId: call.tabId,
          windowId: call.windowId,
          roomId: call.roomId,
          shareUrl: call.shareUrl,
          port: port,
          accountDetailFetcher: accountDetailFetcher,
          cookieReader: cookieReader,
        );
        if (guard != null) {
          fresh.updateGuardArgs(
            guardRoomId: guard.roomId,
            guardWebRid: guard.webRid,
            guardExtra: guard.extra,
          );
        }
        _remoteTabs[call.tabId] = fresh;
        unawaited(
          gateway.rehome(call.tabId, newPort: fresh).then(
            (_) => _settleHandoff(call.tabId),
            onError: (Object e) => _failHandoff(call.tabId, e),
          ),
        );
      } else {
        // 主窗不发 register，此路不可达；防御性直接结算
        _settleHandoff(call.tabId);
      }
    }
    return true;
  }

  /// 非抖音 register 成功后回推一次凭据（M5 Cookie 借用扩展）。
  /// 载荷：douyu/bili/huya 走 cookie 单串（可 ''）；twitch 走 creds 三键
  /// （cookie 恒 ''）。status 空 Map、reentered=false——语义退化为「凭据下发」。
  /// 凭据值只出现在 pr_apply_enter，本方法是唯一出口；异常吞掉不外逸。
  Future<void> _pushBorrowedCredentials(PresenceRegisterCall call) async {
    try {
      final payload = _readBorrowedCredentials(call.siteId);
      await port.invoke(
        call.windowId,
        PresenceProtocol.mApplyEnter,
        PresenceProtocol.encodeApplyEnter(
          PresenceApplyEnterCall(
            tabId: call.tabId,
            cookie: payload.cookie,
            creds: payload.creds,
            status: const <String, Object?>{},
            reentered: false,
          ),
        ),
      );
    } catch (_) {
      // best-effort：子窗不可达/读取失败不影响 register 结果
    }
  }

  /// 按 siteId 读当刻凭据；测试经 [credentialReaderFor] 注入，生产直读
  /// 账号服务字段。返回 (cookie, creds)：twitch 的 cookie 恒 ''。
  ({String cookie, Map<String, String>? creds}) _readBorrowedCredentials(
      String siteId) {
    if (credentialReaderFor != null) {
      final raw = credentialReaderFor!(siteId);
      final cookie = raw['cookie'] is String ? raw['cookie'] as String : '';
      final credsRaw = raw['creds'];
      final creds = credsRaw is Map
          ? <String, String>{
              for (final e in credsRaw.entries)
                if (e.key is String && e.value is String)
                  e.key as String: e.value as String,
            }
          : null;
      return (cookie: cookie, creds: creds);
    }
    switch (siteId) {
      case Constant.kDouyu:
        return (cookie: DouyuAccountService.instance.cookie, creds: null);
      case Constant.kBiliBili:
        return (cookie: BiliBiliAccountService.instance.cookie, creds: null);
      case Constant.kHuya:
        return (cookie: HuyaAccountService.instance.cookie, creds: null);
      case Constant.kTwitch:
        final t = TwitchAccountService.instance;
        return (
          cookie: '',
          creds: {
            'oauthToken': t.oauthToken,
            'userLogin': t.userLogin,
            'clientId':
                t.clientId.isEmpty ? TwitchSite.kWebClientId : t.clientId,
          },
        );
      default:
        return (cookie: '', creds: null);
    }
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

  /// 编排层迁移前置：网关跟踪该 tab 时建 10s handoff 并返回其 future；
  /// 非跟踪（非抖音/纯游客）返回 null，编排层按纯壳迁移处理。
  @override
  Future<void>? prepareHandoff(String tabId, String destWindowId) {
    if (!gateway.isTrackedTab(tabId)) return null;
    final previous = _handoffs.remove(tabId);
    if (previous != null && !previous.settled) {
      previous.settled = true;
      previous.timer?.cancel();
      if (!previous.completer.isCompleted) {
        previous.completer
            .completeError(const HandoffSupersededException());
      }
    }
    final handoff = _Handoff(destWindowId);
    handoff.timer = Timer(handoffTimeout, () {
      if (!handoff.settled) {
        handoff.settled = true;
        _handoffs.remove(tabId);
        if (!handoff.completer.isCompleted) {
          handoff.completer.completeError(
            const HandoffTimeoutException(),
          );
        }
      }
    });
    _handoffs[tabId] = handoff;
    return handoff.completer.future;
  }

  /// 子→主：主窗 store.open 后控制器已 bindTab 本地端口。摘远端索引/
  /// RemoteTab，网关 rehome(newPort:null) 换到本地端口并复刻；幂等。
  @override
  Future<void> rehomeLocal(String tabId) async {
    final old = _remoteTabs.remove(tabId);
    old?.markClosed();
    _tabWindow.remove(tabId);
    if (gateway.isTrackedTab(tabId)) {
      await gateway.rehome(tabId);
    }
    _settleHandoff(tabId);
  }

  void _settleHandoff(String tabId) {
    final handoff = _handoffs[tabId];
    if (handoff == null || handoff.settled) return;
    handoff.settled = true;
    handoff.timer?.cancel();
    _handoffs.remove(tabId);
    if (!handoff.completer.isCompleted) {
      handoff.completer.complete();
    }
  }

  void _failHandoff(String tabId, Object error) {
    final handoff = _handoffs[tabId];
    if (handoff == null || handoff.settled) return;
    handoff.settled = true;
    handoff.timer?.cancel();
    _handoffs.remove(tabId);
    if (!handoff.completer.isCompleted) {
      handoff.completer.completeError(error);
    }
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
    for (final tabId in tabIds) {
      _failHandoff(tabId, const HandoffSourceClosedException());
    }
    if (tabIds.isNotEmpty) {
      await gateway.batchRelease(tabIds);
    }
  }
}
