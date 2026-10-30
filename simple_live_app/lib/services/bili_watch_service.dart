import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/local_storage_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:uuid/uuid.dart';

/// b 站直播观看心跳（live-trace E/X 协议）全局服务。
///
/// 持有进程唯一的 [BiliWatchTracker]（其内部按房间维护多会话）与内嵌
/// spyder.wasm 签名器。首次 [start] 时懒加载：读 assets 中的 wasm、
/// 解析持久化的设备标识。加载失败不影响播放，下一次 start 自动重试。
class BiliWatchService extends GetxService {
  BiliWatchService({Future<BiliWatchTracker?> Function()? trackerBuilder})
      : _externalBuilder = trackerBuilder;

  final Future<BiliWatchTracker?> Function()? _externalBuilder;

  static BiliWatchService get instance => Get.find<BiliWatchService>();

  Future<BiliWatchTracker?>? _loading;

  /// start/stop 串行化：所有调用在 tracker 就绪后严格按发出顺序执行。
  /// 否则「进房后立刻切走」时 stop 可能在 wasm 异步加载完成前到达而丢失，
  /// 导致加载完成后 E 已发出却无人收尾、后台标签会话残留。
  Future<void> _chain = Future<void>.value();

  static const String _wasmAsset = 'assets/wasm/spyder.wasm';

  /// 请求开始（或延续）某房间的观看会话。幂等：tracker 内部按房间去重，
  /// 防抖窗口内的同房 start 会取消 stop 补发、延续原会话。
  Future<void> start(int roomId) {
    final next = _chain.then((_) async {
      final tracker = await _ensureTracker();
      if (tracker != null) {
        await tracker.start(roomId);
      }
    });
    _chain = next;
    return next;
  }

  /// 请求结束某房间观看会话；真正的最后一个 X 由 tracker 防抖
  /// （10–60s）后补发，防抖窗口内 [start] 同一房间可延续会话。
  Future<void> stop(int roomId) {
    final next = _chain.then((_) async {
      final tracker = await _ensureTracker();
      tracker?.stop(roomId);
    });
    _chain = next;
    return next;
  }

  Future<BiliWatchTracker?> _ensureTracker() {
    return _loading ??= (_externalBuilder ?? _buildTracker)();
  }

  Future<BiliWatchTracker?> _buildTracker() async {
    try {
      final site = Sites.allSites[Constant.kBiliBili]!.liveSite as BiliBiliSite;
      final byteData = await rootBundle.load(_wasmAsset);
      final bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      final signer = await BiliSpyderSigner.fromBytes(bytes);
      final tracker = BiliWatchTracker(
        http: site,
        sign: signer.sign,
        buvid: _resolveBuvid(site),
        deviceId: _resolveDeviceId(),
        userAgent: BiliBiliSite.kDefaultUserAgent,
        onFail: (reason) {
          Log.logPrint('b站观看心跳失败: reason=$reason');
        },
      );
      return tracker;
    } catch (e) {
      // 失败后允许下一次 start 重新构建（wasm 资源读失败等）
      _loading = null;
      Log.logPrint('b站观看心跳初始化失败: $e');
      return null;
    }
  }

  /// cookie 自带 LIVE_BUVID（登录 WebView 经过直播域时可能已有）优先；
  /// 否则用本地持久值；都没有则按官方 AUTO 算法生成并落盘。
  String _resolveBuvid(BiliBiliSite site) {
    final fromCookie = site.liveBuvid;
    if (fromCookie.isNotEmpty) return fromCookie;
    final storage = LocalStorageService.instance;
    final persisted =
        storage.getValue<String>(LocalStorageService.kBiliWatchBuvid, '');
    if (persisted.isNotEmpty) return persisted;
    final generated = BiliBiliSite.generateLiveBuvid();
    storage.setValue(LocalStorageService.kBiliWatchBuvid, generated);
    return generated;
  }

  String _resolveDeviceId() {
    final storage = LocalStorageService.instance;
    final persisted =
        storage.getValue<String>(LocalStorageService.kBiliWatchDeviceId, '');
    if (persisted.isNotEmpty) return persisted;
    final deviceId = const Uuid().v4();
    storage.setValue(LocalStorageService.kBiliWatchDeviceId, deviceId);
    return deviceId;
  }
}
