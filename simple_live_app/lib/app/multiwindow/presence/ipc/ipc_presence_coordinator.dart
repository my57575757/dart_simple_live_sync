import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../presence_batch_releaser.dart';
import '../presence_client.dart';
import 'presence_apply_target.dart';
import 'presence_protocol.dart';
import 'sub_presence_port.dart';

/// 子端本地发送（pr_guard_send）失败码：invoke 抛错或主窗回执无法解析。
/// not_holder/not_login 由主端产生；此码仅出子端、不上线。
const String kPresenceCodeIpcFailed = 'ipc_failed';

/// 子端 claim 当刻读取的进房参数快照提供者：guard 房间标识随游客详情
/// 刷新可能变化，故不在工厂调用时固化。
class PresenceClaimArgs {
  const PresenceClaimArgs({
    required this.roomId,
    required this.shareUrl,
    required this.guardRoomId,
    required this.guardWebRid,
    required this.guardExtra,
  });

  final String roomId;
  final String shareUrl;
  final String guardRoomId;
  final String guardWebRid;
  final Map<String, Object?> guardExtra;
}

/// 子引擎每窗一个：出站 presence IPC、per-tab PresenceClient 工厂、
/// 主→子三个 apply 回调；同时以 PresenceBatchReleaser 身份承接子窗
/// TabStore 的批量关闭（整批经主端一次释放）。
class IpcPresenceCoordinator extends GetxService
    implements PresenceBatchReleaser {
  IpcPresenceCoordinator({
    required this.windowId,
    required SubPresencePort port,
    required PresenceApplyTarget? Function(String tabId) resolveTarget,
    required DouyinAccountService accounts,
  })  : _port = port,
        _resolveTarget = resolveTarget,
        _accounts = accounts;

  final String windowId;
  final SubPresencePort _port;
  final PresenceApplyTarget? Function(String tabId) _resolveTarget;
  final DouyinAccountService _accounts;

  /// 子端控制器绑定后调用：只在主端建死亡对账索引，不进仲裁栈。
  /// best-effort：主窗不可达不阻塞子端进房（主窗关闭=应用退出）。
  Future<void> registerRemoteTab({
    required String tabId,
    required String siteId,
    required String roomId,
    required String shareUrl,
  }) async {
    try {
      await _port.invokeMain(
        PresenceProtocol.mRegister,
        PresenceProtocol.encodeRegister(
          PresenceRegisterCall(
            windowId: windowId,
            tabId: tabId,
            siteId: siteId,
            roomId: roomId,
            shareUrl: shareUrl,
          ),
        ),
      );
    } catch (_) {
      // T7：只记固定文案/方法名，禁止回显异常对象——PlatformException
      // 文本可能携带主端拼入的请求载荷。
      Log.d('presence: pr_register 主窗无响应，已忽略');
    }
  }

  /// 子窗标签刷新/切房 leave 完成后的身份复位：pr_release 已把主端死亡
  /// 对账索引与仲裁标签一并摘除，而 register 只在控制器 onInit 发生一次，
  /// 不补登记则该 tabId 后续 claim 必被裸拒（子端误报主窗无响应）。
  /// 同时立即清空借用登录凭据（刷新路径不经 yield/suspended 失效点），
  /// 重新 claim 成功时 apply_enter 会再下发当刻新值。register 为幂等
  /// 纯索引写入：非抖音站点主端拒绝注册，此处仅完成清理；主窗不可达
  /// 时 best-effort 不抛错。
  Future<void> refreshRemoteTab({
    required String tabId,
    required String siteId,
    required String roomId,
    required String shareUrl,
  }) async {
    _accounts.setBorrowedLoginCookie(null);
    await registerRemoteTab(
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
    );
  }

  /// 控制器持有的 per-tab presence 客户端；guard 参数每次 claim 当刻
  /// 经 [args] 读取（游客详情刷新后 roomId/webRid 可能变化）。
  PresenceClient clientForTab({
    required String tabId,
    required PresenceClaimArgs Function() args,
  }) =>
      _IpcPresenceClient(
        windowId: windowId,
        tabId: tabId,
        args: args,
        port: _port,
      );

  @override
  Future<void> batchRelease(Set<String> tabIds) async {
    if (tabIds.isEmpty) return;
    try {
      await _port.invokeMain(
        PresenceProtocol.mBatchRelease,
        PresenceProtocol.encodeBatchRelease(
          PresenceBatchReleaseCall(
            windowId: windowId,
            tabIds: tabIds.toList(),
          ),
        ),
      );
    } catch (_) {
      // T7：异常文本可能回显载荷，只记固定文案。
      Log.d('presence: pr_batch_release 主窗无响应，已忽略');
    }
  }

  /// 子引擎总 method handler 的 pr_apply_* 三 case 转交入口（T10 接线）。
  /// 查无控制器（已销毁）静默返回；任何子端异常不得回传主端——主端
  /// apply 本就是 best-effort，通道抛错只会变成主端日志噪音。
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case PresenceProtocol.mApplyEnter:
        final call = PresenceProtocol.decodeApplyEnter(arguments);
        if (call == null) return false;
        final target = _resolveTarget(call.tabId);
        if (target == null) return null;
        // 先写借用 cookie，自取详情才会携带登录凭据
        _accounts.setBorrowedLoginCookie(call.cookie);
        final LiveRoomDetail detail;
        try {
          detail = await target.fetchAccountDetail();
        } catch (e) {
          // 自取失败：保留游客弹幕，不调 apply；不向主端抛错
          Log.d('presence: 子端自取账号详情失败，保持游客弹幕：$e');
          return null;
        }
        try {
          await target.applyAccountEnter(
            accountDetail: detail,
            guardStatus: Map<String, dynamic>.from(call.status),
            reentered: call.reentered,
          );
        } catch (e) {
          Log.d('presence: 子端 applyAccountEnter 失败：$e');
        }
        return null;

      case PresenceProtocol.mApplyYield:
      case PresenceProtocol.mApplySuspended:
        final tabId = PresenceProtocol.decodeTabApply(arguments);
        if (tabId == null) return false;
        // cookie 先于控制器切换失效（三失效点之二）
        _accounts.setBorrowedLoginCookie(null);
        final target = _resolveTarget(tabId);
        if (target == null) return null;
        try {
          if (method == PresenceProtocol.mApplyYield) {
            await target.applyYieldToGuest();
          } else {
            await target.applySuspended();
          }
        } catch (e) {
          Log.d('presence: 子端 $method apply 失败：$e');
        }
        return null;

      default:
        return null;
    }
  }

  /// 防御性清理：仅在容器拆卸/测试场景可达。生产子引擎不主动 Get.delete
  /// 本服务，子窗关闭时借用 cookie 随进程隔离销毁；活跃借用态的立即失效
  /// 由 yield/suspended 两路径保证，主端死亡则经 batchRelease 对账释放。
  @override
  void onClose() {
    _accounts.setBorrowedLoginCookie(null);
    super.onClose();
  }
}

class _IpcPresenceClient implements PresenceClient {
  _IpcPresenceClient({
    required this.windowId,
    required this.tabId,
    required this.args,
    required this.port,
  });

  final String windowId;
  final String tabId;
  final PresenceClaimArgs Function() args;
  final SubPresencePort port;

  bool _claimed = false;

  @override
  bool get isClaimed => _claimed;

  @override
  Future<PresenceClaimResult> claim() async {
    final a = args();
    try {
      final raw = await port.invokeMain(
        PresenceProtocol.mClaim,
        PresenceProtocol.encodeClaim(
          PresenceClaimCall(
            windowId: windowId,
            tabId: tabId,
            roomId: a.roomId,
            shareUrl: a.shareUrl,
            guardRoomId: a.guardRoomId,
            guardWebRid: a.guardWebRid,
            guardExtra: a.guardExtra,
          ),
        ),
      );
      final r = PresenceProtocol.decodeClaimResult(raw);
      if (r == null) {
        _claimed = false;
        return const PresenceClaimResult.failure(
            reason: PresenceFailureReason.ipcFailed);
      }
      _claimed = r.ok;
      if (r.ok) return const PresenceClaimResult.granted();
      return PresenceClaimResult.failure(
          reason: r.reason ?? PresenceFailureReason.ipcFailed);
    } catch (_) {
      // T7：不回显异常/载荷，回执只含固定 reason
      _claimed = false;
      return const PresenceClaimResult.failure(
          reason: PresenceFailureReason.ipcFailed);
    }
  }

  @override
  Future<void> release() => _leave(PresenceProtocol.mRelease);

  @override
  Future<void> detach() => _leave(PresenceProtocol.mDetach);

  Future<void> _leave(String method) async {
    _claimed = false;
    try {
      await port.invokeMain(
        method,
        PresenceProtocol.encodeRelease(
          PresenceReleaseCall(windowId: windowId, tabId: tabId),
        ),
      );
    } catch (_) {
      // T7：只记方法名，异常文本可能回显载荷
      Log.d('presence: $method 主窗无响应，已忽略');
    }
  }

  @override
  Future<PresenceSendResult> sendDanmaku(String content) =>
      _send(PresenceProtocol.kDanmaku, content: content);

  @override
  Future<PresenceSendResult> sendAction(String action) =>
      _send(PresenceProtocol.kAction, action: action);

  Future<PresenceSendResult> _send(
    String kind, {
    String? content,
    String? action,
  }) async {
    try {
      final raw = await port.invokeMain(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          PresenceGuardSendCall(
            windowId: windowId,
            tabId: tabId,
            kind: kind,
            content: content,
            action: action,
          ),
        ),
      );
      final r = PresenceProtocol.decodeSendResult(raw);
      if (r != null) return r;
    } catch (_) {
      // T7：落到本地固定失败回执，不回显异常/载荷
    }
    return const PresenceSendResult(
      success: false,
      code: kPresenceCodeIpcFailed,
      message: '主窗口服务无响应，请重试',
    );
  }
}
