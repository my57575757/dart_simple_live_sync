import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:window_manager/window_manager.dart';

import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/multiwindow/data/data_plane_protocol.dart';
import 'package:simple_live_app/app/multiwindow/data/remote_kv_box.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_client.dart';
import 'package:simple_live_app/app/multiwindow/data/sub_data_plane_port.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/ipc_presence_coordinator.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/presence_protocol.dart';
import 'package:simple_live_app/app/multiwindow/presence/ipc/sub_presence_port.dart';
import 'package:simple_live_app/app/multiwindow/shell/getx_room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/room_controller_registry.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_open_request.dart';
import 'package:simple_live_app/app/multiwindow/shell/tab_store.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_port.dart';
import 'package:simple_live_app/app/multiwindow/window/sub_window_control_service.dart';
import 'package:simple_live_app/app/multiwindow/window/window_args.dart';
import 'package:simple_live_app/app/multiwindow/window/window_control_protocol.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';
import 'package:simple_live_app/main.dart' show MyApp;
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/douyin_account_service.dart';
import 'package:simple_live_app/services/douyu_account_service.dart';
import 'package:simple_live_app/services/follow_service.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/services/huya_account_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_app/services/twitch_account_service.dart';
import 'package:simple_live_core/simple_live_core.dart';

import 'in_memory_services.dart';

/// 房间子引擎入口：精简服务集，无 Hive / presence 网关 / Sync / Update /
/// IndexedController；只读快照 + 内存后端，五个账号服务空凭据游客态进房。
Future<void> runSubEngine(WindowController self) async {
  final RoomWindowArgs args;
  try {
    args = RoomWindowArgs.decode(self.arguments);
  } catch (e, st) {
    Log.logPrint(e);
    Log.logPrint(st);
    await windowManager.ensureInitialized();
    await windowManager.close();
    return;
  }

  MultiWindowRole.isSubWindow = true;
  MediaKit.ensureInitialized();
  Utils.packageInfo = await PackageInfo.fromPlatform();
  await windowManager.ensureInitialized();
  // 原生建窗时为 800x600 空标题且 hiddenAtLaunch，由 window_manager 接管外观
  windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1200, 720),
      minimumSize: Size(360, 400),
      center: true,
      title: 'Simple Live',
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
      // SWP_FRAMECHANGED 强制 DWM 重注册窗口，否则 Win11 贴靠布局可能漏掉本窗
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      // 显示后再走一次 ITaskbarList::AddTab，补住建窗时 hiddenAtLaunch 的登记时机
      await windowManager.setSkipTaskbar(false);
    },
  );

  // —— 内存后端（必须先于一切服务）。带主窗 id 时启用数据面写穿 ——
  final SubDataPlanePort? dataPort = args.mainWindowId.isEmpty
      ? null
      : DmwSubDataPlanePort(args.mainWindowId);

  // 账号面 presence 通道与数据面同生命周期：仅在有主窗 id 时启用
  final SubPresencePort? presencePort = dataPort == null
      ? null
      : DmwSubPresencePort(args.mainWindowId);

  // 窗口管理通道与 presence 通道同门控：只有挂在主窗下的子窗才能跨窗迁移
  final SubWindowControlPort? controlPort = presencePort == null
      ? null
      : DmwSubWindowControlPort(args.mainWindowId);

  RemoteKvBox<dynamic>? settingsKv;
  RemoteKvBox<String>? shieldKv;
  final InMemoryLocalStorageService storage;
  if (dataPort != null) {
    settingsKv =
        RemoteKvBox<dynamic>(DataPlaneProtocol.boxSettings, dataPort);
    shieldKv = RemoteKvBox<String>(DataPlaneProtocol.boxShield, dataPort);
    settingsKv.seedReplaceAll(
        Map<Object, dynamic>.of(args.snapshot.settings));
    shieldKv.seedReplaceAll(
        <Object, String>{for (final w in args.snapshot.shield) w: w});
    storage = InMemoryLocalStorageService(
        settingsBox: settingsKv, shieldBox: shieldKv);
  } else {
    storage = InMemoryLocalStorageService()..applySnapshot(args.snapshot);
  }
  Get.put<LocalStorageService>(storage, permanent: true);

  final db = InMemoryDBService(dataPort: dataPort)
    ..applySnapshot(args.snapshot);
  Get.put<DBService>(db, permanent: true);

  // —— 最小服务集 ——
  Get.put(AppSettingsController(), permanent: true);
  // 与主引擎 initCoreLog 对齐：子引擎借用主窗 cookie 取账号详情后，dio
  // 拦截器默认 requestLogType=all 会把含 Cookie 的请求头打控制台；short
  // 只打 URL/状态码。不接 onPrintLog：子引擎 CoreLog 仅静控制台、不路由文件。
  CoreLog.enableLog =
      !kReleaseMode || AppSettingsController.instance.logEnable.value;
  CoreLog.requestLogType = RequestLogType.short;
  // configured=false：不联网、不 rehydrate、不绑 htmlFetcher
  Get.put(GuardServerService(), permanent: true);
  // 空 cookie：logined=false，纯游客
  Get.put(DouyinAccountService(), permanent: true);
  // 其余四平台账号服务也必须注册：斗鱼 loadData() 进房路径直查
  // DouyuAccountService（live_room_controller.dart:1435），弹幕登录态
  // getter danmakuLogined（:1237）构建期遍历五服务；快照已剥离全部
  // cookie/token，onInit 纯本地读 KV、无网络/定时器，注册即天然游客态
  Get.put(BiliBiliAccountService(), permanent: true);
  Get.put(DouyuAccountService(), permanent: true);
  Get.put(HuyaAccountService(), permanent: true);
  Get.put(TwitchAccountService(), permanent: true);
  // 不起定时刷新、不跑状态查询网络
  Get.put(FollowService(enableScheduledRefresh: false), permanent: true);

  // —— 标签壳（无首页、无主端 presence 网关；批量释放挂 coordinator）——
  Get.put<RoomControllerRegistry>(GetxRoomControllerRegistry(),
      permanent: true);

  // 子端 presence 协调者：必须先于 TabStore（批量关闭经它整批释放）、
  // 先于 store.open（控制器 onInit 即发 pr_register，T11）就位
  // 显式非空泛型：本赋值目标类型可空 + 条件表达式，上下文类型会把 put 的
  // 类型实参下推推断成 IpcPresenceCoordinator?，注册 key 退化为带 "?" 的
  // 类型名，导致各处按非空类型 isRegistered/find 全部落空。
  final IpcPresenceCoordinator? presenceCoordinator = presencePort == null
      ? null
      : Get.put<IpcPresenceCoordinator>(
          IpcPresenceCoordinator(
            windowId: self.windowId,
            port: presencePort,
            resolveTarget: (tabId) => Get.find<RoomControllerRegistry>()
                .controllerForTabId(tabId),
            accounts: Get.find<DouyinAccountService>(),
            douyuAccounts: Get.find<DouyuAccountService>(),
            twitchAccounts: Get.find<TwitchAccountService>(),
            biliAccounts: Get.find<BiliBiliAccountService>(),
            huyaAccounts: Get.find<HuyaAccountService>(),
          ),
          permanent: true,
        );
  // 凭据下发后按需重启该站弹幕（douyu/twitch）；按 tabId 解析到控制器
  presenceCoordinator?.onCredentialsApplied = (tabId, siteId) {
    final controller =
        Get.find<RoomControllerRegistry>().controllerForTabId(tabId);
    if (controller != null) {
      unawaited(controller.applyBorrowedCredentials(siteId));
    }
  };

  final store = Get.put<TabStore>(
    TabStore(
      registry: Get.find<RoomControllerRegistry>(),
      hasHome: false,
      presenceGateway: presenceCoordinator,
    ),
    permanent: true,
  );

  // 同上：显式非空泛型，避免可空上下文把注册 key 推断成带 "?" 的类型名。
  final SubWindowControlService? controlService = controlPort == null
      ? null
      : Get.put<SubWindowControlService>(
          SubWindowControlService(
            windowId: self.windowId,
            port: controlPort,
            store: store,
          ),
          permanent: true,
        );

  // —— 数据面客户端 + 总 handler：handler 先就位，再 await 对账（spec §6.4）——
  final SubDataPlaneClient? dataClient = dataPort == null
      ? null
      : SubDataPlaneClient(
          port: dataPort,
          settings: settingsKv!,
          shield: shieldKv!,
          db: db,
          registry: Get.find<RoomControllerRegistry>(),
          onSettingsChanged: () =>
              AppSettingsController.instance.reloadFromStorage(),
        );

  self.setWindowMethodHandler((call) async {
    switch (call.method) {
      case DataPlaneProtocol.mChanged:
        dataClient?.handleChanged(call.arguments);
        return true;
      case PresenceProtocol.mApplyEnter:
      case PresenceProtocol.mApplyYield:
      case PresenceProtocol.mApplySuspended:
        // coordinator 为 null（无主窗的独立子窗）时 await null → 返回 null
        return await presenceCoordinator?.handleCall(
            call.method, call.arguments);
      case WindowControlProtocol.mOpenTab:
      case WindowControlProtocol.mCloseTab:
        // controlService 为 null（无主窗的独立子窗）时返回 null
        return await controlService?.handleCall(call.method, call.arguments);
      case 'focus_tab':
        await windowManager.show();
        await windowManager.focus();
        store.activateByKey(call.arguments as String);
        return true;
      case 'close_window':
        final closer = SubWindowCommands.closeRequested;
        if (closer != null) {
          await closer();
        }
        return true;
      default:
        return null;
    }
  });

  await dataClient?.reconcile();

  for (final tab in args.tabs) {
    try {
      store.open(
        TabOpenRequest(
          siteId: tab.siteId,
          roomId: tab.roomId,
          shareUrl: tab.shareUrl,
        ),
        tabId: tab.tabId,
      );
    } catch (e, st) {
      Log.logPrint('子窗打开标签失败：${tab.siteId}/${tab.roomId}');
      Log.logPrint(e);
      Log.logPrint(st);
    }
  }
  if (store.tabs.isEmpty) {
    await windowManager.close();
    return;
  }

  runApp(const MyApp(isSubWindow: true));
}
