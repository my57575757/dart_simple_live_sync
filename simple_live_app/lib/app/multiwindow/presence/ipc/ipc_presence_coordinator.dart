import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
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
    required DouyuAccountService douyuAccounts,
    required TwitchAccountService twitchAccounts,
    required BiliBiliAccountService biliAccounts,
    required HuyaAccountService huyaAccounts,
  })  : _port = port,
        _resolveTarget = resolveTarget,
        _accounts = accounts,
        _douyuAccounts = douyuAccounts,
        _twitchAccounts = twitchAccounts,
        _biliAccounts = biliAccounts,
        _huyaAccounts = huyaAccounts;

  final String windowId;
  final SubPresencePort _port;
  final PresenceApplyTarget? Function(String tabId) _resolveTarget;
  final DouyinAccountService _accounts;
  final DouyuAccountService _douyuAccounts;
  final TwitchAccountService _twitchAccounts;
  final BiliBiliAccountService _biliAccounts;
  final HuyaAccountService _huyaAccounts;

  /// tabId → siteId：register 时写入，apply_enter 按站点分发凭据到对应
  /// 账号服务。切房后 refreshRemoteTab 会以新 siteId 覆盖。
  final Map<String, String> _tabSite = {};

  /// 凭据下发完成回调（M5 接线点）：live_room_controller 注册后按需
  /// 重启该站弹幕连接。仅在 apply_enter 写完借用凭据后触发一次。
  void Function(String tabId, String siteId)? onCredentialsApplied;

  /// 子端控制器绑定后调用：只在主端建死亡对账索引，不进仲裁栈。
  /// best-effort：主窗不可达不阻塞子端进房（主窗关闭=应用退出）。
  Future<void> registerRemoteTab({
    required String tabId,
    required String siteId,
    required String roomId,
    required String shareUrl,
  }) async {
    _tabSite[tabId] = siteId;
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
  /// 纯索引写入；主窗不可达时 best-effort 不抛错。
  Future<void> refreshRemoteTab({
    required String tabId,
    required String siteId,
    required String roomId,
    required String shareUrl,
  }) async {
    _clearBorrowedCredentials();
    await registerRemoteTab(
      tabId: tabId,
      siteId: siteId,
      roomId: roomId,
      shareUrl: shareUrl,
    );
  }

  /// 四个失效点（yield/suspended/onClose/refreshRemoteTab）共用：
  /// 五站借用凭据一并清空，语义安全且不依赖当刻 siteId。
  void _clearBorrowedCredentials() {
    _accounts.setBorrowedLoginCookie(null);
    _douyuAccounts.setBorrowedLoginCookie(null);
    _twitchAccounts.setBorrowedLoginCreds(null);
    _biliAccounts.setBorrowedLoginCookie(null);
    _huyaAccounts.setBorrowedLoginCookie(null);
  }

  /// 控制器持有的 per-tab presence 客户端；guard 参数每次 claim 当刻
  /// 经 [args] 读取（游客详情刷新后 roomId/webRid 可能变化）。
  /// [siteId] 构造时固化（claim 语义与站点解耦），写动作 encode 时带上。
  PresenceClient clientForTab({
    required String tabId,
    required String siteId,
    required PresenceClaimArgs Function() args,
  }) =>
      _IpcPresenceClient(
        windowId: windowId,
        tabId: tabId,
        siteId: siteId,
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
        final siteId = _tabSite[call.tabId] ?? Constant.kDouyin;
        // 先写借用凭据，自取详情/弹幕重连才会携带登录身份
        _applyBorrowedCredentials(siteId, call);
        onCredentialsApplied?.call(call.tabId, siteId);
        // 非抖音只写凭据：账号态进场（fetchAccountDetail/applyAccountEnter）
        // 是抖音 presence 语义，其余站点弹幕升级由 onCredentialsApplied 负责
        if (siteId != Constant.kDouyin) return null;
        final target = _resolveTarget(call.tabId);
        if (target == null) return null;
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
        // 凭据先于控制器切换失效（三失效点之二）；三站一并清空
        _clearBorrowedCredentials();
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

  /// 按 siteId 把借用凭据写进对应账号服务（纯内存单点，不写 KV/不翻登录态）。
  void _applyBorrowedCredentials(
    String siteId,
    PresenceApplyEnterCall call,
  ) {
    switch (siteId) {
      case Constant.kDouyu:
        _douyuAccounts.setBorrowedLoginCookie(call.cookie);
        break;
      case Constant.kBiliBili:
        _biliAccounts.setBorrowedLoginCookie(call.cookie);
        break;
      case Constant.kHuya:
        _huyaAccounts.setBorrowedLoginCookie(call.cookie);
        break;
      case Constant.kTwitch:
        _twitchAccounts.setBorrowedLoginCreds(call.creds);
        break;
      default:
        // 抖音：单串 cookie
        _accounts.setBorrowedLoginCookie(call.cookie);
        break;
    }
  }

  /// 防御性清理：仅在容器拆卸/测试场景可达。生产子引擎不主动 Get.delete
  /// 本服务，子窗关闭时借用 cookie 随进程隔离销毁；活跃借用态的立即失效
  /// 由 yield/suspended 两路径保证，主端死亡则经 batchRelease 对账释放。
  @override
  void onClose() {
    _clearBorrowedCredentials();
    _tabSite.clear();
    super.onClose();
  }
}

class _IpcPresenceClient implements PresenceClient {
  _IpcPresenceClient({
    required this.windowId,
    required this.tabId,
    required this.siteId,
    required this.args,
    required this.port,
  });

  final String windowId;
  final String tabId;
  final String siteId;
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
      final a = args();
      final raw = await port.invokeMain(
        PresenceProtocol.mGuardSend,
        PresenceProtocol.encodeGuardSend(
          PresenceGuardSendCall(
            windowId: windowId,
            tabId: tabId,
            kind: kind,
            content: content,
            action: action,
            siteId: siteId,
            roomId: a.guardRoomId,
            webRid: a.guardWebRid,
            extra: a.guardExtra.isEmpty ? null : a.guardExtra,
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
