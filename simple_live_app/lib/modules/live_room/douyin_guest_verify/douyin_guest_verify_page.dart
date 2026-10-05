import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:get/get.dart';

import 'douyin_guest_verify_controller.dart';

class DouyinGuestVerifyPage extends StatefulWidget {
  const DouyinGuestVerifyPage({super.key});

  @override
  State<DouyinGuestVerifyPage> createState() => _DouyinGuestVerifyPageState();
}

class _DouyinGuestVerifyPageState extends State<DouyinGuestVerifyPage> {
  final DouyinGuestVerifyController controller =
      Get.find<DouyinGuestVerifyController>();
  bool prepared = false;

  @override
  void initState() {
    super.initState();
    controller.setupIsolation().then((_) {
      if (mounted) setState(() => prepared = true);
    });
  }

  Widget buildWebView() => InAppWebView(
        initialUrlRequest: URLRequest(url: controller.roomUrl),
        initialSettings: controller.buildSettings(),
        webViewEnvironment: controller.environment,
        onWebViewCreated: controller.onWebViewCreated,
        onLoadStop: controller.onLoadStop,
      );

  Widget buildPanel() {
    final body = Column(
      children: [
        Expanded(child: prepared ? buildWebView() : const Center(child: CircularProgressIndicator())),
        const Padding(
          padding: EdgeInsets.all(8.0),
          child: Text(
            "请按页面提示完成验证；验证结果仅保存 12 小时",
            style: TextStyle(fontSize: 12),
          ),
        ),
      ],
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text("游客验证"),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: controller.cancel,
        ),
        actions: [
          TextButton(
            onPressed: controller.manualSubmit,
            child: const Text("完成验证"),
          ),
        ],
      ),
      body: body,
    );
  }

  @override
  Widget build(BuildContext context) {
    final panel = PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) controller.cancel();
      },
      child: buildPanel(),
    );
    if (!Platform.isWindows) return panel;
    return Scaffold(
      backgroundColor: Colors.black54,
      body: Center(
        child: SizedBox(
          width: MediaQuery.of(context).size.width * 0.62,
          height: MediaQuery.of(context).size.height * 0.82,
          child: Card(
            clipBehavior: Clip.antiAlias,
            margin: EdgeInsets.zero,
            child: panel,
          ),
        ),
      ),
    );
  }
}
