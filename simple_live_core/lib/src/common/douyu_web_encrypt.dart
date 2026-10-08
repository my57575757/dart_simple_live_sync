import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:simple_live_core/src/common/http_client.dart';

class DouyuEncryptKey {
  final String encData;
  final String key;
  final String randStr;
  final int encTime;
  final int expireAt;
  final bool isSpecial;

  DouyuEncryptKey({
    required this.encData,
    required this.key,
    required this.randStr,
    required this.encTime,
    required this.expireAt,
    required this.isSpecial,
  });

  factory DouyuEncryptKey.fromJson(Map json) => DouyuEncryptKey(
        encData: json["enc_data"].toString(),
        key: json["key"].toString(),
        randStr: json["rand_str"].toString(),
        encTime: int.tryParse(json["enc_time"].toString()) ?? 1,
        expireAt: int.tryParse(json["expire_at"].toString()) ?? 0,
        isSpecial: int.tryParse(json["is_special"].toString()) == 1,
      );
}

/// 斗鱼桌面网页版新的播放签名流程（getH5PlayV1）。
///
/// 旧的 getH5Play（ver=Douyu_223061205）已被服务端把所有画质降级为低码率；
/// 新流程的密钥由 getEncryption 下发，auth 为对 rand_str/key 的迭代 MD5。
///
/// 注意必须与真实网页播放器保持一致：使用固定 DID、ive=0 且不带 ver 参数；
/// 随机 DID + ive=1 的组合会被服务端风控判定为异常，把所有请求降级到 _900。
class DouyuWebEncrypt {
  static const String defaultDid = "10000000000000000000000000001501";

  final String did;
  DouyuWebEncrypt([this.did = defaultDid]);

  DouyuEncryptKey? _key;

  static String calcAuth({
    required String randStr,
    required String key,
    required int encTime,
    required String roomId,
    required int ts,
    bool isSpecial = false,
  }) {
    var u = randStr;
    for (var i = 0; i < encTime; i++) {
      u = md5.convert(utf8.encode("$u$key")).toString();
    }
    final input = isSpecial ? "" : "$roomId$ts";
    return md5.convert(utf8.encode("$u$key$input")).toString();
  }

  bool get _isKeyValid {
    if (_key == null) return false;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return now < _key!.expireAt;
  }

  Future<DouyuEncryptKey> getKey(String roomId) async {
    if (_isKeyValid) return _key!;
    final result = await HttpClient.instance.getJson(
      "https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption",
      queryParameters: {"did": did},
      header: {'referer': "https://www.douyu.com/$roomId"},
    );
    if (result["error"] != 0) {
      throw Exception("getEncryption: ${result["msg"]}");
    }
    _key = DouyuEncryptKey.fromJson(result["data"] as Map);
    return _key!;
  }

  /// 请求指定画质/线路的播放数据，返回接口的 data 字段。
  Future<Map<String, dynamic>> getPlayData(
    String roomId, {
    required int rate,
    String cdn = "",
  }) async {
    final key = await getKey(roomId);
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final auth = calcAuth(
      randStr: key.randStr,
      key: key.key,
      encTime: key.encTime,
      roomId: roomId,
      ts: ts,
      isSpecial: key.isSpecial,
    );
    final body = "enc_data=${Uri.encodeComponent(key.encData)}"
        "&tt=$ts&did=$did&auth=$auth"
        "&cdn=${Uri.encodeComponent(cdn)}"
        "&rate=$rate&hevc=0&fa=0&ive=0";
    final result = await HttpClient.instance.postJson(
      "https://www.douyu.com/lapi/live/getH5PlayV1/$roomId",
      data: body,
      header: {'referer': "https://www.douyu.com/$roomId"},
      formUrlEncoded: true,
    );
    if (result["error"] != 0) {
      throw Exception("getH5PlayV1: ${result["msg"]}");
    }
    return result["data"] as Map<String, dynamic>;
  }
}
