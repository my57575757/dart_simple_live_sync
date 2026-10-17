import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_port.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import '../presence_claimant.dart';
import 'presence_protocol.dart';

/// 远端抖音标签在主引擎侧的端口：与主窗本地标签混栈仲裁，账号态 HTTP
/// 全在主端执行；apply 回调经 SubWindowPort 单向 invoke 到该 tabId
/// 所属子窗。单次 apply invoke 失败不置 closed——通道失败不等于窗口
/// 死亡，硬死亡由 windowsChanged 对账兜底。
class RemotePresenceTab implements DouyinPresenceTab {
  RemotePresenceTab({
    required this.tabId,
    required this.windowId,
    required this.roomId,
    required this.shareUrl,
    required SubWindowPort port,
    Future<LiveRoomDetail> Function(String roomId, String shareUrl)?
        accountDetailFetcher,
    String Function()? cookieReader,
  })  : _port = port,
        _fetchDetail = accountDetailFetcher ?? _defaultFetchDetail,
        _readCookie = cookieReader ?? _defaultCookieReader;

  final String windowId;
  final String roomId;
  final String shareUrl;
  final SubWindowPort _port;
  final Future<LiveRoomDetail> Function(String, String) _fetchDetail;
  final String Function() _readCookie;

  static Future<LiveRoomDetail> _defaultFetchDetail(
      String roomId, String shareUrl) {
    final site = Sites.allSites[Constant.kDouyin]!.liveSite as DouyinSite;
    return site.getRoomDetail(roomId: '$roomId;$shareUrl', asAccount: true);
  }

  static String _defaultCookieReader() =>
      DouyinAccountService.instance.loginCookie;

  @override
  final String tabId;

  String _guardRoomId = '';
  String _guardWebRid = '';
  Map<String, Object?> _guardExtra = const <String, Object?>{};

  /// 每次 pr_claim 同步最新 guard 参数；首次 claim 即 bindTab，
  /// 进过栈的远端 tab 必有参数，fallback 可直接重新 enter。
  void updateGuardArgs({
    required String guardRoomId,
    required String guardWebRid,
    required Map<String, Object?> guardExtra,
  }) {
    _guardRoomId = guardRoomId;
    _guardWebRid = guardWebRid;
    _guardExtra = Map<String, Object?>.from(guardExtra);
  }

  bool _closed = false;
  @override
  bool get isClosed => _closed;

  /// release/batch/窗口死亡对账置位
  void markClosed() {
    _closed = true;
  }

  @override
  Future<LiveRoomDetail> fetchAccountDetail() =>
      _fetchDetail(roomId, shareUrl);

  @override
  String get guardRoomId => _guardRoomId;

  @override
  String get guardWebRid => _guardWebRid;

  @override
  Map<String, dynamic> guardExtraArgs() =>
      Map<String, dynamic>.from(_guardExtra);

  @override
  Future<void> applyAccountEnter({
    required LiveRoomDetail accountDetail,
    required Map<String, dynamic> guardStatus,
    required bool reentered,
  }) async {
    // accountDetail 不下发：danmakuData 是 dynamic，跨引擎 JSON 往返不对称；
    // cookie 在发送当刻读取（claim 在途期间主窗可能换号，spec §5.2）。
    await _port.invoke(
      windowId,
      PresenceProtocol.mApplyEnter,
      PresenceProtocol.encodeApplyEnter(
        PresenceApplyEnterCall(
          tabId: tabId,
          cookie: _readCookie(),
          status: Map<String, Object?>.from(guardStatus),
          reentered: reentered,
        ),
      ),
    );
  }

  @override
  Future<void> applyYieldToGuest() => _port.invoke(
        windowId,
        PresenceProtocol.mApplyYield,
        PresenceProtocol.encodeTabApply(tabId),
      );

  @override
  Future<void> applySuspended() => _port.invoke(
        windowId,
        PresenceProtocol.mApplySuspended,
        PresenceProtocol.encodeTabApply(tabId),
      );
}
