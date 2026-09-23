import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/services/guard_server_service.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class GuardServerSettingsPage extends StatefulWidget {
  const GuardServerSettingsPage({super.key});

  @override
  State<GuardServerSettingsPage> createState() =>
      _GuardServerSettingsPageState();
}

class _GuardServerSettingsPageState extends State<GuardServerSettingsPage> {
  final service = GuardServerService.instance;
  late final TextEditingController urlCtrl =
      TextEditingController(text: service.serverUrl);
  late final TextEditingController tokenCtrl =
      TextEditingController(text: service.token);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("弹幕签名服务")),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          const Padding(
            padding: AppStyle.edgeInsetsA12,
            child: Text(
              "配置后，抖音/B站/虎牙弹幕通过服务端真实页面代发，以通过平台风控。Cookie 将托管在服务端。",
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          SettingsCard(
            child: Padding(
              padding: AppStyle.edgeInsetsA12,
              child: Column(children: [
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    labelText: "服务地址",
                    hintText: "http://192.168.x.x:1380",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: tokenCtrl,
                  decoration: const InputDecoration(
                    labelText: "Token",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () async {
                          await service.setConfig(
                              urlCtrl.text, tokenCtrl.text);
                          Get.back();
                        },
                        child: const Text("保存"),
                      ),
                    ]),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
