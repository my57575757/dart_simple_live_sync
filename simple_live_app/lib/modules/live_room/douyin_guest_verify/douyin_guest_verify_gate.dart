import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/routes/route_path.dart';

/// 抖音游客验证页的全局去重入口。
///
/// 进房（LiveRoomController）与关注列表后台状态刷新（FollowService）都可能
/// 检测到需要游客验证。无论多少房间、多少请求同时撞上，只打开一个验证页，
/// 其余调用复用同一结果；验证写入的设备级 trust 随后对所有房间生效。
class DouyinGuestVerifyGate {
  DouyinGuestVerifyGate._();

  static final DouyinGuestVerifyGate _instance = DouyinGuestVerifyGate._();

  static DouyinGuestVerifyGate get instance => _override ?? _instance;

  @visibleForTesting
  static void setOverride(DouyinGuestVerifyGate? value) {
    _override = value;
  }

  static DouyinGuestVerifyGate? _override;

  Completer<Object?>? _completer;

  bool get isOpen => _completer != null;

  Future<Object?> open(
    String webRid, {
    Future<Object?> Function(String webRid)? navigator,
  }) {
    final existing = _completer;
    if (existing != null) return existing.future;

    final completer = Completer<Object?>();
    _completer = completer;
    final nav = navigator ?? _defaultNavigator;
    nav(webRid).then(
      (result) {
        if (identical(_completer, completer)) _completer = null;
        if (!completer.isCompleted) completer.complete(result);
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_completer, completer)) _completer = null;
        if (!completer.isCompleted) {
          completer.completeError(error, stack);
        }
      },
    );
    return completer.future;
  }

  Future<Object?> _defaultNavigator(String webRid) async {
    return await Get.toNamed<Object?>(
      RoutePath.kDouyinGuestVerify,
      arguments: webRid,
    );
  }
}
