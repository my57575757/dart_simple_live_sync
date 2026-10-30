import 'dart:convert';

import 'package:crypto/crypto.dart';

/// B 站 web 端 wbi 签名。
///
/// 算法逐字对照官方直播页 webpack 模块 25219 的 K 函数（mixin 重排表、
/// 过滤 `!'()*`、encodeURIComponent、md5），黄金向量对拍见
/// test/bili_wbi_test.dart（与真实抓包 E 请求的 w_rid 一致）。
class BiliWbi {
  static const List<int> mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, //
    27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
    37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
    22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
  ];

  static String mixinKey(String imgKey, String subKey) {
    final raw = imgKey + subKey;
    final buffer = StringBuffer();
    for (final index in mixinKeyEncTab) {
      if (index < raw.length) buffer.write(raw[index]);
    }
    return buffer.toString().substring(0, 32);
  }

  /// 对查询参数签名，返回 w_rid 与 wts（秒）。
  /// [wts] 仅测试注入；生产环境取当前时间。
  static ({String wRid, String wts}) sign(
    Map<String, dynamic> params, {
    required String imgKey,
    required String subKey,
    int? wts,
  }) {
    final wtsValue = wts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final entries = <MapEntry<String, dynamic>>[
      ...params.entries,
      MapEntry('wts', wtsValue),
    ]..sort((a, b) => a.key.compareTo(b.key));

    final parts = <String>[];
    for (final entry in entries) {
      final value = entry.value;
      if (value == null) continue;
      final normalized = value is String
          ? value.replaceAll(RegExp(r"""[!'()*]"""), '')
          : '$value';
      parts.add(
        '${Uri.encodeComponent(entry.key)}=${Uri.encodeComponent(normalized)}',
      );
    }

    final query = parts.join('&');
    final digest = md5
        .convert(utf8.encode('$query${mixinKey(imgKey, subKey)}'))
        .toString();
    return (wRid: digest, wts: wtsValue.toString());
  }
}
