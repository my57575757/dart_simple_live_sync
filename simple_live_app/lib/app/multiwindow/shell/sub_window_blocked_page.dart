import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/multiwindow/window/window_role.dart';

/// 子窗深路由防御包装：子窗模式渲染拦截页（AppBar 返回 + 居中提示、
/// 不构建子页），主窗模式透传。包装账号设置 / Web 登录 / 其他设置 /
/// WebDAV 等凭据与全局设置路由（spec §6.6.5，纵深防御）。
class SubWindowBlockedPage extends StatelessWidget {
  const SubWindowBlockedPage({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows || !MultiWindowRole.isSubWindow) {
      return child;
    }
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Get.back<void>(),
        ),
      ),
      body: const Center(
        child: Text('该功能仅可在主窗口使用'),
      ),
    );
  }
}
