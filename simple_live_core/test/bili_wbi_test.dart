import 'package:simple_live_core/simple_live_core.dart';
import 'package:test/test.dart';

void main() {
  // 黄金向量来源：在官方直播页（房间 5050）内移植模块 25219 的 K 函数产出
  // 规范化输入串，本地 md5 后与真实抓包 E 请求的 w_rid 逐位对拍通过；
  // 此夹具是同一算法下「无 csrf 的 X 参数」形状（csrf 不允许落盘）。
  const imgKey = '7cd084941338484aae1ad9425b84077c';
  const subKey = '4932caff0ff746eab6f01bf08b70ac45';
  const wts = 1793287269;

  test('wbi 签名与官方页面抓包黄金向量一致', () {
    final params = <String, dynamic>{
      's':
          '250bc74ce2e86db94609adeccc835ac8853a4412340c7f371822351041edf1e37ee43ca1a54e1e4abff8df79f78c05795da563fcee1e7e85bbc32cb083c33c5e',
      'id': '[6,236,1,5050]',
      'device':
          '["AUTO3317901687841255","bfcdd5fb-649f-4057-bc46-4e32bc0dfee4"]',
      'ruid': 433351,
      'ets': 1793287209,
      'benchmark': 'seacasdgyijfhofiuxoannn',
      'time': 60,
      'ts': 1793287269733,
      // UA 含空格与括号：官方过滤 !'()* 后用 encodeURIComponent（空格 %20），
      // 不能用 x-www-form-urlencoded 的 '+'，否则签名不符。
      'ua':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36',
      'trackid': '-99998',
      'web_location': '444.8',
    };

    final signed = BiliWbi.sign(
      params,
      imgKey: imgKey,
      subKey: subKey,
      wts: wts,
    );

    expect(signed.wts, wts.toString());
    expect(signed.wRid, '7144ef3f743f5e70198ac4c090857f13');
  });

  test('mixin key 重排与官方一致', () {
    expect(
      BiliWbi.mixinKey(imgKey, subKey),
      'ea1db124af3c7062474693fa704f4ff8',
    );
  });
}
