import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';

import '../shell/tab_descriptor.dart';
import '../shell/tab_open_request.dart';
import '../shell/tab_store.dart';
import 'sub_window_control_port.dart';
import 'window_control_protocol.dart';

/// 子引擎窗口管理服务：应主端要求落标签/关标签，并向主端发起跨窗移动。
/// 仅在带主窗 id 的子窗装配（bootstrap presencePort 同款门控）。
class SubWindowControlService extends GetxService {
  SubWindowControlService({
    required this.windowId,
    required this.port,
    required this.store,
    void Function(String message)? showToast,
  }) : _showToast = showToast ?? SmartDialog.showToast;

  final String windowId;
  final SubWindowControlPort port;
  final TabStore store;
  final void Function(String message) _showToast;

  static SubWindowControlService get instance =>
      Get.find<SubWindowControlService>();

  /// 拉取可移入窗口列表（含主窗口）；调用方自行排除本窗 windowId。
  Future<List<WindowListEntry>> requestWindowList() async {
    final raw = await port.invokeMain(WindowControlProtocol.mListWindows);
    return WindowControlProtocol.decodeWindowList(raw) ?? const [];
  }

  /// 请求把本窗标签移到 target（__main__/__new__/windowId）。
  /// 成败由主端裁定；失败只 toast 不抛异常，返回 false 供菜单收口。
  Future<bool> requestMove({
    required TabDescriptor tab,
    required String target,
  }) async {
    final args = WindowControlProtocol.encodeRequestMove(
      WindowMoveCall(
        sourceWindowId: windowId,
        tabId: tab.tabId,
        siteId: tab.request.siteId,
        roomId: tab.request.roomId,
        shareUrl: tab.request.shareUrl,
        target: target,
      ),
    );
    try {
      final result = WindowControlProtocol.decodeMoveResult(
        await port.invokeMain(WindowControlProtocol.mRequestMove, args),
      );
      if (result != null && result.ok) return true;
      _showToast(result?.message ?? '移动失败，请重试');
      return false;
    } catch (_) {
      _showToast('移动失败，请重试');
      return false;
    }
  }

  /// 子端总 handler 的 mw_ 委托点；未知方法返回 null 交由 default 回落。
  Future<Object?> handleCall(String method, Object? arguments) async {
    switch (method) {
      case WindowControlProtocol.mOpenTab:
        final call = WindowControlProtocol.decodeOpenTab(arguments);
        if (call == null) return false;
        try {
          store.open(
            TabOpenRequest(
              siteId: call.siteId,
              roomId: call.roomId,
              shareUrl: call.shareUrl,
            ),
            activate: call.activate,
            tabId: call.tabId,
          );
          return true;
        } catch (_) {
          return false;
        }
      case WindowControlProtocol.mCloseTab:
        final call = WindowControlProtocol.decodeCloseTab(arguments);
        if (call == null) return false;
        try {
          store.closeForMove(call.tabId);
          return true;
        } catch (_) {
          return false;
        }
      default:
        return null;
    }
  }
}
