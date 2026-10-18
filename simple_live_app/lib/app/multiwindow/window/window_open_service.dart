import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/handoff_controller.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:window_manager/window_manager.dart';

import 'dmw_sub_window_port.dart';
import 'sub_window_port.dart';
import 'window_args.dart';
import 'window_control_protocol.dart';
import 'window_registry.dart';

/// 从主引擎当前 Hive 数据构造子窗只读快照
class WindowSnapshotBuilder {
  /// 当前主引擎数据面全量快照（开窗参数与 dp_ready 对账共用同一来源）
  static WindowSnapshot buildDataSnapshot() {
    final storage = LocalStorageService.instance;
    final db = DBService.instance;

    final settings = <String, dynamic>{};
    for (final entry in storage.settingsBox.toMap().entries) {
      final key = entry.key.toString();
      if (DataPlaneProtocol.isSensitiveKey(key)) continue;
      final value = entry.value;
      // IPC/JSON 只接受基础类型；LocalStorage 现存值均为 num/String/bool
      if (value == null || value is num || value is String || value is bool) {
        settings[key] = value;
      }
    }

    return WindowSnapshot(
      settings: settings,
      shield: storage.shieldBox.values.toList(),
      volumes: db.exportVolumes(),
      followShareUrls: db.exportFollowShareUrls(),
    );
  }

  static RoomWindowArgs build(
    List<TabOpenRequest> requests, {
    String mainWindowId = '',
  }) {
    return RoomWindowArgs(
      mainWindowId: mainWindowId,
      tabs: [
        for (final request in requests)
          RoomTabArg(
            siteId: request.siteId,
            roomId: request.roomId,
            shareUrl: request.shareUrl,
          ),
      ],
      snapshot: buildDataSnapshot(),
    );
  }
}

/// 主引擎开窗协调者：全局去重前置、开窗登记、子窗存活对账与联动关闭
class WindowOpenService extends GetxService {
  WindowOpenService({
    required this.port,
    required this.store,
    required this.registry,
    this.presenceService,
    void Function(String message)? showToast,
    Future<void> Function()? showAndFocusMain,
  })  : _showToast = showToast ?? SmartDialog.showToast,
        _focusMainOverride = showAndFocusMain;

  static WindowOpenService get instance => Get.find<WindowOpenService>();

  final SubWindowPort port;
  final TabStore store;
  final WindowRegistry registry;

  /// MPS 构造晚于本服务：app_pages 装配 MainPresenceService 后后绑。
  PresenceHandoffController? presenceService;

  final void Function(String message) _showToast;
  final Future<void> Function()? _focusMainOverride;

  /// 在途迁移 tabId 集：菜单 unawaited 连点会让同一标签的两次迁移在 await
  /// 点交错（孤立重复标签 / presence 索引被末次 pr_register 胜出 / 旧
  /// handoff 被误报「移动超时」）。入口登记，finally 清理。
  final Set<String> _movingTabIds = <String>{};

  Future<void> _showAndFocusMain() async {
    final override = _focusMainOverride;
    if (override != null) {
      await override();
      return;
    }
    await windowManager.show();
    await windowManager.focus();
  }

  StreamSubscription<void>? _windowsChangedSub;

  final StreamController<Set<String>> _childWindowsClosed =
      StreamController<Set<String>>.broadcast();

  /// 对账发现子窗进程消失（无临终消息）时推送被摘除 windowId 集。
  /// MainPresenceService 订阅后批量释放该窗名下远端 presence 标签。
  /// 广播流不补发历史，订阅必须先于对账事件建立（MainPresenceService 在 onInit 订阅，早于任何开窗）。
  Stream<Set<String>> get onChildWindowsClosed => _childWindowsClosed.stream;

  @override
  void onInit() {
    super.onInit();
    _windowsChangedSub = port.windowsChanged.listen((_) async {
      try {
        final removed = registry.reconcile(await port.listWindowIds());
        if (removed.isNotEmpty) {
          _childWindowsClosed.add(removed);
        }
      } catch (_) {
        // 对账失败等下一事件自愈，不影响开窗主流程
      }
    });
  }

  @override
  void onClose() {
    unawaited(_windowsChangedSub?.cancel());
    _windowsChangedSub = null;
    unawaited(_childWindowsClosed.close());
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
      WindowSnapshotBuilder.build(
        [request],
        mainWindowId: DmwSubWindowPort.mainWindowId ?? '',
      ).encode(),
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

  int get childWindowCount => registry.childCount;

  /// 主窗右键菜单候选：仅已存在子窗（主窗自身不作为主窗发起的目标）。
  List<WindowListEntry> listMoveTargets({required String? excludeWindowId}) {
    return [
      for (final e in registry.childWindowOrder())
        if (e.id != excludeWindowId)
          WindowListEntry(id: e.id, label: '直播间窗口 ${e.ordinal}'),
    ];
  }

  /// mw_list_windows 回执：主窗口固定符号项 + 全部子窗（开窗序编号）。
  List<WindowListEntry> listWindowEntries() => [
        const WindowListEntry(
            id: WindowControlProtocol.targetMain, label: '主窗口'),
        ...listMoveTargets(excludeWindowId: null),
      ];

  Future<Object?> handleWindowCall(String method, Object? arguments) async {
    switch (method) {
      case WindowControlProtocol.mRequestMove:
        final call = WindowControlProtocol.decodeRequestMove(arguments);
        if (call == null) {
          return WindowControlProtocol.encodeMoveResult(false,
              message: '移动失败，请重试');
        }
        final message = await moveTabToWindow(
          tabId: call.tabId,
          sourceWindowId: call.sourceWindowId,
          target: call.target,
          siteId: call.siteId,
          roomId: call.roomId,
          shareUrl: call.shareUrl,
        );
        return WindowControlProtocol.encodeMoveResult(message == null,
            message: message);
      case WindowControlProtocol.mListWindows:
        return WindowControlProtocol.encodeWindowList(listWindowEntries());
      default:
        return null;
    }
  }

  /// 跨窗迁移标签。null=成功；非空=固定中文失败文案（禁止回显异常对象）。
  /// 主窗发起（sourceWindowId==null）失败在主窗 toast；子窗发起只返回文案，
  /// 由 mw_request_move 回执送子端 toast（跨引擎 SmartDialog 不共享）。
  Future<String?> moveTabToWindow({
    required String tabId,
    String? sourceWindowId,
    required String target,
    String? siteId,
    String? roomId,
    String? shareUrl,
  }) async {
    final fromMain = sourceWindowId == null;

    String? fail(String message) {
      if (fromMain) _showToast(message);
      return message;
    }

    // F1：tabId 级在途守卫，第二次并发直接拒
    if (!_movingTabIds.add(tabId)) {
      return fail('移动失败，请重试');
    }
    try {
      // 1. 取请求四元组（tabId 为权威身份，presence 全程不换）
      TabOpenRequest? request;
      if (fromMain) {
        request = store.tabs.firstWhereOrNull((t) => t.tabId == tabId)?.request;
      } else if (siteId != null && roomId != null) {
        request = TabOpenRequest(
            siteId: siteId, roomId: roomId, shareUrl: shareUrl ?? '');
      }
      final req0 = request;
      if (req0 == null) {
        return fail('未找到要移动的标签');
      }
      final tabKey = req0.key;

      // F3：子源载荷归属校验——tab 实际所在子窗须等于 sourceWindowId，
      // 防 IPC 载荷串窗/伪造；registry 查不到（漂移）放行以免误杀。
      final owner = registry.windowForTab(tabKey);
      if (owner != null && owner != sourceWindowId) {
        return fail('未找到要移动的标签');
      }

      // 2. 解析目标；__new__ 此刻创建进程（早于 prepareHandoff：创建失败
      //    时根本没有 handoff 需要取消，spec §8）
      var destIsNew = false;
      var destIsMain = false;
      var destWindowId = '';
      if (target == WindowControlProtocol.targetMain) {
        destIsMain = true;
        destWindowId = registry.mainWindowId;
      } else if (target == WindowControlProtocol.targetNew) {
        destIsNew = true;
        try {
          final handle = await port.createRoomWindow(
            RoomWindowArgs(
              mainWindowId: DmwSubWindowPort.mainWindowId ?? '',
              tabs: [
                RoomTabArg(
                  siteId: req0.siteId,
                  roomId: req0.roomId,
                  shareUrl: req0.shareUrl,
                  tabId: tabId,
                ),
              ],
              snapshot: WindowSnapshotBuilder.buildDataSnapshot(),
            ).encode(),
          );
          destWindowId = handle.windowId;
          // 新窗空集覆盖式登记（registerChild 语义）
          registry.registerChild(handle.windowId, {tabKey});
        } catch (_) {
          return fail('新建窗口失败');
        }
      } else {
        if (!registry.childWindowIds.contains(target)) {
          return fail('目标窗口不存在');
        }
        destWindowId = target;
      }

      // 3. presence 无缝 handoff（非抖音/未跟踪得 null，壳流程不等）
      final handoff = presenceService?.prepareHandoff(tabId, destWindowId);
      // 立即挂 catchError 防 unhandled：覆盖后续所有提前 return / 不 await
      // 分支；正常 await handoff 收口语义不变（成功/超时/失败既有行为不动）。
      if (handoff != null) {
        unawaited(handoff.catchError((Object _) {}));
      }

      // 4. 目标落标签
      if (destIsMain) {
        // 主窗控制器在 store.open 同步头内 onInit→bindTab，先于 rehomeLocal
        store.open(req0, tabId: tabId);
        try {
          await presenceService?.rehomeLocal(tabId);
        } catch (_) {
          // 本地复刻失败不阻断壳迁移：pending 补放/写动作 claim 自愈（spec §8）
        }
      } else {
        if (!destIsNew) {
          Object? accepted;
          try {
            accepted = await port.invoke(
              destWindowId,
              WindowControlProtocol.mOpenTab,
              WindowControlProtocol.encodeOpenTab(
                OpenTabCall(
                  tabId: tabId,
                  siteId: req0.siteId,
                  roomId: req0.roomId,
                  shareUrl: req0.shareUrl,
                  activate: true,
                ),
              ),
            );
          } catch (_) {
            accepted = false;
          }
          if (accepted != true) {
            // 不登记 registry；handoff 由 10s 超时自清；源不动（spec §8）
            return fail('目标窗口无响应');
          }
          registry.addChildTab(destWindowId, tabKey);
        }
        // new 的 pr_register 与 child 的 register 均已在途：等 rehome 结算
        if (handoff != null) {
          try {
            await handoff;
          } catch (_) {
            if (destIsNew) {
              // 无法确认新窗状态：best-effort 关窗（成功则 reconcile 摘表）
              try {
                await port.invoke(destWindowId, 'close_window', null);
              } catch (_) {}
            }
            // child：保守保留目标标签（其 store.open 已成功），源不动
            return fail('移动超时，标签可能已在目标窗口');
          }
        }
      }

      // 5. 关源（best-effort：源窗若已死，reconcile 兜底）
      if (fromMain) {
        store.closeForMove(tabId);
      } else {
        try {
          await port.invoke(
            sourceWindowId,
            WindowControlProtocol.mCloseTab,
            WindowControlProtocol.encodeCloseTab(CloseTabCall(tabId: tabId)),
          );
        } catch (_) {}
      }

      // 6. registry 挪动（主窗标签不在 registry；新窗步骤 2 已登记）
      if (!fromMain) {
        if (destIsMain) {
          registry.removeChildTab(sourceWindowId, tabKey);
        } else {
          registry.moveChildTab(sourceWindowId, destWindowId, tabKey);
        }
      }

      // 7. 聚焦：新窗 bootstrap 自 show；已存在子窗发 focus_tab；
      //    主窗仅在源是子窗时置前
      if (destIsMain) {
        if (!fromMain) {
          try {
            await _showAndFocusMain();
          } catch (_) {}
        }
      } else if (!destIsNew) {
        try {
          await port.invoke(destWindowId, 'focus_tab', tabKey);
        } catch (_) {}
      }
      return null;
    } catch (_) {
      // F2：编排体逃逸异常（store.open 未知 site / closeForMove 源被手关 /
      // moveChildTab 目标窗已死等）统一收口，禁止把异常对象拼进文案
      return fail('移动失败，请重试');
    } finally {
      _movingTabIds.remove(tabId);
    }
  }

  /// 主窗关闭前尽力联动关闭所有子窗；单个失败不阻断退出
  Future<void> requestCloseAllChildren() async {
    for (final windowId in registry.childWindowIds) {
      try {
        await port.invoke(windowId, 'close_window', null);
      } catch (_) {}
    }
  }
}
