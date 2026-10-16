import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

import 'sub_window_port.dart';
import 'window_args.dart';
import 'window_registry.dart';

/// 从主引擎当前 Hive 数据构造子窗只读快照
class WindowSnapshotBuilder {
  /// 禁止跨窗传播的键：各平台登录凭据、guard 服务配置/账号、WebDAV 与
  /// 局域网同步信息。M4-1 子窗固定游客态：若带入抖音登录 cookie，子引擎
  /// DouyinAccountService.onInit 会判定 logined=true；带入 GuardServerUrl
  /// 会使 GuardServerService.configured=true——均破坏游客态假设。
  static const Set<String> sensitiveKeys = {
    'BilibiliCookie',
    'DouyinCookie',
    'DouyinLoginCookie',
    'GuardServerUrl',
    'GuardServerToken',
    'DouyuCookie',
    'DouyuLoginAccount',
    'DouyuLoginPassword',
    'HuyaCookie',
    'TwitchClientId',
    'TwitchToken',
    'TwitchUserLogin',
    'WebDAVUri',
    'WebDAVUser',
    'kWebDAVPassword',
    'userName',
    'syncUrl',
  };

  /// 敏感键前缀（guard 账号 id 按平台存多份）
  static const String sensitivePrefix = 'GuardAccountId_';

  static bool isSensitiveKey(String key) =>
      sensitiveKeys.contains(key) || key.startsWith(sensitivePrefix);

  static RoomWindowArgs build(List<TabOpenRequest> requests) {
    final storage = LocalStorageService.instance;
    final db = DBService.instance;

    final settings = <String, dynamic>{};
    for (final entry in storage.settingsBox.toMap().entries) {
      final key = entry.key.toString();
      if (isSensitiveKey(key)) continue;
      final value = entry.value;
      // IPC/JSON 只接受基础类型；LocalStorage 现存值均为 num/String/bool
      if (value == null ||
          value is num ||
          value is String ||
          value is bool) {
        settings[key] = value;
      }
    }

    return RoomWindowArgs(
      tabs: [
        for (final request in requests)
          RoomTabArg(
            siteId: request.siteId,
            roomId: request.roomId,
            shareUrl: request.shareUrl,
          ),
      ],
      snapshot: WindowSnapshot(
        settings: settings,
        shield: storage.shieldBox.values.toList(),
        volumes: db.exportVolumes(),
        followShareUrls: db.exportFollowShareUrls(),
      ),
    );
  }
}

/// 主引擎开窗协调者：全局去重前置、开窗登记、子窗存活对账与联动关闭
class WindowOpenService extends GetxService {
  WindowOpenService({
    required this.port,
    required this.store,
    required this.registry,
  });

  static WindowOpenService get instance => Get.find<WindowOpenService>();

  final SubWindowPort port;
  final TabStore store;
  final WindowRegistry registry;

  StreamSubscription<void>? _windowsChangedSub;

  @override
  void onInit() {
    super.onInit();
    _windowsChangedSub = port.windowsChanged.listen((_) async {
      try {
        registry.reconcile(await port.listWindowIds());
      } catch (_) {
        // 对账失败等下一事件自愈，不影响开窗主流程
      }
    });
  }

  @override
  void onClose() {
    unawaited(_windowsChangedSub?.cancel());
    _windowsChangedSub = null;
    super.onClose();
  }

  /// 卡片「新窗口打开」：主窗已有→激活；子窗已有→IPC 置前；否则新建
  Future<void> openInNewWindow(TabOpenRequest request) async {
    if (store.findByKey(request.key) != null) {
      store.open(request);
      return;
    }
    final existingWindow = registry.windowForTab(request.key);
    if (existingWindow != null) {
      await port.invoke(existingWindow, 'focus_tab', request.key);
      return;
    }
    final handle = await port.createRoomWindow(
      WindowSnapshotBuilder.build([request]).encode(),
    );
    registry.registerChild(handle.windowId, {request.key});
  }

  /// 主窗常规入口（首页/卡片进房、右键后台标签）：全局去重前置。
  /// 房间已在某子窗 → IPC 置前该子窗；否则在主窗按 background 语义开/激活。
  Future<void> openLocallyWithGlobalDedup(
    TabOpenRequest request, {
    bool background = false,
  }) async {
    if (store.findByKey(request.key) == null) {
      final existingWindow = registry.windowForTab(request.key);
      if (existingWindow != null) {
        await port.invoke(existingWindow, 'focus_tab', request.key);
        return;
      }
    }
    store.open(request, activate: !background);
  }

  /// 标签右键「移到新窗口」。M4-1 前置条件：游客态
  /// （账号态由 UI 置灰，不进入此方法）。快照重建：先开新窗再关本标签。
  Future<void> moveTabToNewWindow(String tabId) async {
    final descriptor =
        store.tabs.firstWhereOrNull((tab) => tab.tabId == tabId);
    if (descriptor == null) return;
    final request = descriptor.request;
    final handle = await port.createRoomWindow(
      WindowSnapshotBuilder.build([request]).encode(),
    );
    registry.registerChild(handle.windowId, {request.key});
    store.close(tabId);
  }

  int get childWindowCount => registry.childCount;

  /// 主窗关闭前尽力联动关闭所有子窗；单个失败不阻断退出
  Future<void> requestCloseAllChildren() async {
    for (final windowId in registry.childWindowIds) {
      try {
        await port.invoke(windowId, 'close_window', null);
      } catch (_) {}
    }
  }
}
