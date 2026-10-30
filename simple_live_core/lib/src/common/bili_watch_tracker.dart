import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/convert_helper.dart';

/// E/X 协议需要的网络能力，由 BiliBiliSite 实现；测试用内存假实现替换。
abstract class BiliWatchHttp {
  Future<BiliRoomInfo> getRoomBaseInfo(int roomId);
  Future<BiliWatchResponse> postEnterRoom(Map<String, dynamic> params);
  Future<BiliWatchResponse> postHeartBeat(Map<String, dynamic> params);
}

/// getRoomBaseInfo 返回的房间四元信息。
class BiliRoomInfo {
  final int roomId;
  final int parentAreaId;
  final int areaId;
  final int ruid;

  const BiliRoomInfo({
    required this.roomId,
    required this.parentAreaId,
    required this.areaId,
    required this.ruid,
  });
}

/// E/X 响应体（只保留心跳会话关心的字段）。
class BiliWatchResponse {
  final int code;
  final int? heartbeatInterval;
  final String? secretKey;
  final List<int>? secretRule;
  final int? timestamp;

  const BiliWatchResponse({
    required this.code,
    this.heartbeatInterval,
    this.secretKey,
    this.secretRule,
    this.timestamp,
  });

  factory BiliWatchResponse.fromJson(Map<String, dynamic> json) {
    final data = (json['data'] as Map?) ?? const {};
    return BiliWatchResponse(
      code: asT<int?>(json['code']) ?? -1,
      heartbeatInterval:
          asT<num?>(data['heartbeat_interval'])?.toInt(),
      secretKey: data['secret_key']?.toString(),
      secretRule: (data['secret_rule'] as List?)?.cast<int>(),
      timestamp: asT<num?>(data['timestamp'])?.toInt(),
    );
  }
}

/// spyder 签名回调：入参为 X 的 reportData JSON 字符串与 E 下发的 secret_rule。
typedef BiliWatchSigner = String Function(
  String reportJson,
  List<int> rule,
);

/// E/X 请求参数与 reportData 拼装（纯函数，逐字对齐官方 webpack 模块 46653）。
class BiliWatchReports {
  static String id({
    required int parentId,
    required int areaId,
    required int seq,
    required int roomId,
  }) =>
      '[$parentId,$areaId,$seq,$roomId]';

  static String device({required String buvid, required String uuid}) =>
      '[${jsonString(buvid)},${jsonString(uuid)}]';

  static String heartbeatReportJson({
    required String id,
    required String device,
    required int ruid,
    required int ets,
    required String benchmark,
    required int time,
    required int tsMs,
    required String ua,
    required String trackid,
  }) {
    // 字段插入顺序即官方 JSON.stringify 输出顺序，spyder 对整串哈希，不能改。
    return '{'
        '"id":${jsonString(id)},'
        '"device":${jsonString(device)},'
        '"ruid":$ruid,'
        '"ets":$ets,'
        '"benchmark":${jsonString(benchmark)},'
        '"time":$time,'
        '"ts":$tsMs,'
        '"ua":${jsonString(ua)},'
        '"trackid":${jsonString(trackid)}'
        '}';
  }

  static Map<String, dynamic> enterParams({
    required String id,
    required String device,
    required int ruid,
    required int tsMs,
    required String ua,
    String heartBeat = '[]',
  }) {
    // 显式 LinkedHashMap 固定字段顺序；heart_beat 是 JSON 字符串而非数组。
    return <String, dynamic>{
      'id': id,
      'device': device,
      'ruid': ruid,
      'ts': tsMs,
      'is_patch': heartBeat == '[]' ? 0 : 1,
      'heart_beat': heartBeat,
      'ua': ua,
    };
  }

  /// 按 JS JSON.stringify 规则生成 JSON 字符串字面量：非 ASCII 字符保留原字符
  /// （Dart 默认 jsonEncode 会转成反斜杠-u 十六进制，spyder 哈希会不一致）。
  static String jsonString(String value) {
    const shorthand = {
      0x08: 'b',
      0x09: 't',
      0x0a: 'n',
      0x0c: 'f',
      0x0d: 'r',
    };
    final buffer = StringBuffer();
    buffer.writeCharCode(0x22); // "
    for (final code in value.codeUnits) {
      if (code == 0x22 || code == 0x5c) {
        buffer.writeCharCode(0x5c); // 前缀反斜杠
        buffer.writeCharCode(code);
      } else if (shorthand.containsKey(code)) {
        buffer.writeCharCode(0x5c);
        buffer.write(shorthand[code]);
      } else if (code < 0x20) {
        buffer.writeCharCode(0x5c);
        buffer.write('u${code.toRadixString(16).padLeft(4, '0')}');
      } else {
        buffer.writeCharCode(code);
      }
    }
    buffer.writeCharCode(0x22);
    return buffer.toString();
  }
}

/// E/X 观看会话状态机。
///
/// 一个实例模拟官方直播间页面的单例心跳控制器，但按 roomId 支持多个并存
/// 会话（App 多标签各对应官方一个页面），共享 buvid；各会话独立 uuid/seq。
class BiliWatchTracker {
  BiliWatchTracker({
    required this.http,
    required BiliWatchSigner sign,
    required this.buvid,
    required this.userAgent,
    String? deviceId,
    DateTime Function()? now,
    Random? random,
    this.onFail,
  })  : _sign = sign,
        _fixedDeviceId = deviceId,
        _now = now ?? DateTime.now,
        _random = random ?? Random();

  final BiliWatchHttp http;
  final BiliWatchSigner _sign;
  final String buvid;
  final String userAgent;
  final String? _fixedDeviceId;
  final DateTime Function() _now;
  final Random _random;
  final void Function(int reason)? onFail;

  static const Duration checkInterval = Duration(seconds: 60);
  static const String defaultTrackid = '-999998';

  final Map<int, _BiliSession> _sessions = {};

  /// 进入房间（E）。已在防抖等待停止的房间会取消补发、延续原会话。
  Future<bool> start(int roomId) async {
    final existing = _sessions[roomId];
    if (existing != null) {
      final debounce = existing.debounce;
      if (debounce != null) {
        debounce.cancel();
        existing.debounce = null;
      }
      if (existing.enabled) return true;
    }

    BiliRoomInfo? room;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        room ??= await http.getRoomBaseInfo(roomId);
        final session = _sessions.putIfAbsent(
          roomId,
          () => _BiliSession(
            room: room!,
            deviceId: _fixedDeviceId ?? _newUuid(),
            lastReport: _now(),
          ),
        );
        final params = BiliWatchReports.enterParams(
          id: BiliWatchReports.id(
            parentId: session.room.parentAreaId,
            areaId: session.room.areaId,
            seq: session.seq,
            roomId: session.room.roomId,
          ),
          device: BiliWatchReports.device(
            buvid: buvid,
            uuid: session.deviceId,
          ),
          ruid: session.room.ruid,
          tsMs: _now().millisecondsSinceEpoch,
          ua: userAgent,
        );
        final response = await http.postEnterRoom(params);
        if (response.code == 0) {
          session
            ..interval = response.heartbeatInterval ?? session.interval
            ..rule = response.secretRule ?? const []
            ..benchmark = response.secretKey ?? ''
            ..ets = response.timestamp
            ..timestampLost = response.timestamp == null
            ..lastReport = _now()
            ..failed = false
            ..enabled = true
            ..seq = session.seq + 1;
          session.startTimer(checkInterval, () => _check(session));
          return true;
        }
      } catch (_) {
        // 落到下一次重试
      }
    }
    _sessions.remove(roomId);
    onFail?.call(10);
    return false;
  }

  /// 离开房间：10–60 秒随机防抖后补发最后一个 X（节拍期间仍继续上报，
  /// 与官方一致）；防抖窗口内重新 start 同一房间则取消补发、会话延续。
  void stop(int roomId) {
    final session = _sessions[roomId];
    if (session == null || session.debounce != null) return;
    final delayMs = 1000 * (_random.nextInt(51) + 10);
    session.debounce = Timer(Duration(milliseconds: delayMs), () async {
      session.debounce = null;
      session.stopTimer();
      await _sendHeartbeat(session, _watchSeconds(session));
      _sessions.remove(roomId);
    });
  }

  /// 释放全部会话：取消定时器与待发补发，不补发最后一个 X。
  void dispose() {
    for (final session in _sessions.values) {
      session.stopTimer();
      session.debounce?.cancel();
      session.debounce = null;
    }
    _sessions.clear();
  }

  Future<void> _check(_BiliSession session) async {
    final watch = _watchSeconds(session);
    if (watch + 5 >= session.interval) {
      if (await _sendHeartbeat(session, watch)) {
        session.lastReport = _now();
        return;
      }
    }
    if (session.failed) {
      if (await _sendHeartbeat(session, session.interval)) {
        session.lastReport = _now();
      }
    }
  }

  Future<bool> _sendHeartbeat(_BiliSession session, int time) async {
    if (time <= 0 || !session.enabled) return false;
    if (session.timestampLost && session.ets != null) {
      session.ets = session.ets! + session.interval;
    }
    session.failed = false;
    try {
      final room = session.room;
      final reportJson = BiliWatchReports.heartbeatReportJson(
        id: BiliWatchReports.id(
          parentId: room.parentAreaId,
          areaId: room.areaId,
          seq: session.seq,
          roomId: room.roomId,
        ),
        device: BiliWatchReports.device(
          buvid: buvid,
          uuid: session.deviceId,
        ),
        ruid: room.ruid,
        ets: session.ets ?? 0,
        benchmark: session.benchmark,
        time: time,
        tsMs: _now().millisecondsSinceEpoch,
        ua: userAgent,
        trackid: defaultTrackid,
      );
      final signature = _sign(reportJson, session.rule);
      final params = <String, dynamic>{
        's': signature,
        ...jsonDecode(reportJson) as Map<String, dynamic>,
      };
      final response = await http.postHeartBeat(params);
      _applyHeartbeatResponse(session, response);
      if (response.code != 0) {
        session.failed = true;
        onFail?.call(11);
        return false;
      }
      session.seq += 1;
      return true;
    } catch (_) {
      session.failed = true;
      onFail?.call(11);
      return false;
    }
  }

  void _applyHeartbeatResponse(
    _BiliSession session,
    BiliWatchResponse response,
  ) {
    final interval = response.heartbeatInterval;
    if (interval != null) session.interval = interval;
    final key = response.secretKey;
    if (key != null) session.benchmark = key;
    final rule = response.secretRule;
    if (rule != null) session.rule = rule;
    final timestamp = response.timestamp;
    if (timestamp != null) {
      session.ets = timestamp;
      session.timestampLost = false;
    } else {
      session.timestampLost = true;
    }
  }

  int _watchSeconds(_BiliSession session) {
    var seconds = (_now().difference(session.lastReport).inMilliseconds / 1000)
        .ceil();
    if (seconds < 0) seconds = 0;
    if (seconds > session.interval) seconds = session.interval;
    return seconds;
  }

  String _newUuid() {
    String hex(int count) => List.generate(
          count,
          (_) => _random.nextInt(16).toRadixString(16),
        ).join();
    return '${hex(8)}-${hex(4)}-4${hex(3)}-${(_random.nextInt(4) + 8).toRadixString(16)}${hex(3)}-${hex(12)}';
  }
}

class _BiliSession {
  final BiliRoomInfo room;
  final String deviceId;
  int seq = 0;
  int? ets;
  int interval = 60;
  String benchmark = '';
  List<int> rule = const [];
  bool enabled = false;
  bool failed = false;
  bool timestampLost = false;
  DateTime lastReport;
  Timer? checkTimer;
  Timer? debounce;

  _BiliSession({
    required this.room,
    required this.deviceId,
    required this.lastReport,
  });

  void startTimer(Duration period, void Function() onTick) {
    stopTimer();
    checkTimer = Timer.periodic(period, (_) => onTick());
  }

  void stopTimer() {
    checkTimer?.cancel();
    checkTimer = null;
  }
}
