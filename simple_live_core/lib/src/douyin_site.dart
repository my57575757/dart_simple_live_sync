import 'dart:convert';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_core/src/common/convert_helper.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

/// 房间页面 HTML 获取器（webRid + 当前 cookie -> 房间页 HTML 原文）
/// 由宿主 App 注入以绕过 Dart 侧 TLS 指纹风控；为 null 时使用内置 Dio 路径
typedef DouyinHtmlFetcher = Future<String> Function(
  String webRid,
  String cookie,
);

/// 直播搜索获取器（keyword + page -> 搜索接口原始 JSON）。
/// 由宿主 App 注入、在受信浏览器环境执行以通过风控；null 时走 Dio 直连
typedef DouyinSearchFetcher = Future<Map<String, dynamic>> Function(
  String keyword, {
  int page,
});

/// 房间页命中验证码中间页：宿主应弹出游客验证窗口，而非走其他取房兜底
class DouyinGuestVerifyRequired implements Exception {
  final String webRid;
  DouyinGuestVerifyRequired(this.webRid);
}

/// 搜索要求登录：抖音登录态缺失/失效，宿主应引导登录抖音账号
class DouyinLoginRequired implements Exception {
  final String message;
  DouyinLoginRequired([this.message = "请先登录抖音账号"]);
  @override
  String toString() => message;
}

/// 搜索命中抖音风控校验（verify_check）
class DouyinRiskControl implements Exception {
  final String message;
  DouyinRiskControl([this.message = "抖音风控校验，请稍后再试"]);
  @override
  String toString() => message;
}

class DouyinSite implements LiveSite {
  @override
  String id = "douyin";

  @override
  String name = "抖音直播";

  @override
  LiveDanmaku getDanmaku() =>
      DouyinDanmaku()..htmlProvider = htmlFetcher;

  /// 使用 QQBrowser User-Agent（参考 DouyinLiveRecorder）
  static const String kDefaultUserAgent =
      "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.5845.97 Safari/537.36 Core/1.116.567.400 QQBrowser/19.7.6764.400";

  static const String kDefaultReferer = "https://live.douyin.com";

  static const String kDefaultAuthority = "live.douyin.com";

  /// 默认 Cookie - 只需要 ttwid 字段即可获取所有画质（包括蓝光）
  /// 经过测试验证，LOGIN_STATUS=1 等其他字段都是可选的
  static const String kDefaultCookie =
      "ttwid=1%7CB1qls3GdnZhUov9o2NxOMxxYS2ff6OSvEWbv0ytbES4%7C1680522049%7C280d802d6d478e3e78d0c807f7c487e7ffec0ae4e5fdd6a0fe74c3c6af149511";

  /// 设备匿名身份 cookie（ttwid）；不承载账号登录态
  String cookie = "";

  /// 账号完整登录 cookie（含 sessionid）；未登录为空
  String loginCookie = "";

  /// 宿主注入的房间 HTML 获取器；null = 走 Dio（console / 不支持 webview 的平台）
  DouyinHtmlFetcher? htmlFetcher;

  /// 宿主注入的直播搜索获取器；null = 走 Dio 直连
  DouyinSearchFetcher? searchFetcher;

  void _logDebug(String msg) {
    // 同时使用 print 和 CoreLog 确保日志输出
    print("[Douyin] $msg");
    CoreLog.d("[Douyin] $msg");
  }

  Map<String, dynamic> headers = {
    "Authority": kDefaultAuthority,
    "Referer": kDefaultReferer,
    "User-Agent": kDefaultUserAgent,
  };

  Future<String> _getText(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
  }) {
    return HttpClient.instance.getText(
      url,
      queryParameters: queryParameters,
      header: header,
    );
  }

  Future<dynamic> _getJson(
    String url, {
    Map<String, dynamic>? queryParameters,
    Map<String, dynamic>? header,
  }) {
    return HttpClient.instance.getJson(
      url,
      queryParameters: queryParameters,
      header: header,
    );
  }

  Future<Map<String, dynamic>> getRequestHeaders({bool asAccount = false}) async {
    try {
      if (asAccount && loginCookie.contains("sessionid")) {
        headers["cookie"] = loginCookie;
        return headers;
      }

      // 游客路径：设备 cookie 优先，否则默认匿名 ttwid；任何情况不带 loginCookie
      headers["cookie"] = cookie.isNotEmpty ? cookie : kDefaultCookie;
      return headers;
    } catch (e) {
      CoreLog.error(e);
      if (!(headers["cookie"]?.toString().isNotEmpty ?? false)) {
        headers["cookie"] = kDefaultCookie;
      }
      return headers;
    }
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    List<LiveCategory> categories = [];
    var result = await _getText(
      "https://live.douyin.com/",
      queryParameters: {},
      header: await getRequestHeaders(),
    );

    var renderData =
        RegExp(
          r'\{\\"pathname\\":\\"\/\\",\\"categoryData.*?\]\\n',
        ).firstMatch(result)?.group(0) ??
        "";
    var renderDataJson = json.decode(
      renderData
          .trim()
          .replaceAll('\\"', '"')
          .replaceAll(r"\\", r"\")
          .replaceAll(']\\n', ""),
    );

    for (var item in renderDataJson["categoryData"]) {
      List<LiveSubCategory> subs = [];
      var id = '${item["partition"]["id_str"]},${item["partition"]["type"]}';
      for (var subItem in item["sub_partition"]) {
        var subCategory = LiveSubCategory(
          id: '${subItem["partition"]["id_str"]},${subItem["partition"]["type"]}',
          name: asT<String?>(subItem["partition"]["title"]) ?? "",
          parentId: id,
          pic: "",
        );
        subs.add(subCategory);
      }

      var category = LiveCategory(
        children: subs,
        id: id,
        name: asT<String?>(item["partition"]["title"]) ?? "",
      );
      subs.insert(
        0,
        LiveSubCategory(
          id: category.id,
          name: category.name,
          parentId: category.id,
          pic: "",
        ),
      );
      categories.add(category);
    }
    return categories;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    var ids = category.id.split(',');
    var partitionId = ids[0];
    var partitionType = ids[1];

    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": partitionId,
        "partition_type": partitionType,
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await _getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    var hasMore = (result["data"]["data"] as List).length >= 15;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["data"]) {
      var roomItem = LiveRoomItem(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        userName: item["room"]["owner"]["nickname"].toString(),
        online:
            int.tryParse(
              item["room"]["room_view_stats"]["display_value"].toString(),
            ) ??
            0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    String serverUrl =
        "https://live.douyin.com/webcast/web/partition/detail/room/v2/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "aid": '6383',
        "app_name": "douyin_web",
        "live_id": '1',
        "device_platform": "web",
        "language": "zh-CN",
        "enter_from": "link_share",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "count": '15',
        "offset": ((page - 1) * 15).toString(),
        "partition": '720',
        "partition_type": '1',
        "req_from": '2',
      },
    );
    var requestUrl = DouyinSign.getAbogusUrl(uri.toString(), kDefaultUserAgent);

    var result = await _getJson(
      requestUrl,
      header: await getRequestHeaders(),
    );

    var hasMore = (result["data"]["data"] as List).length >= 15;
    var items = <LiveRoomItem>[];
    for (var item in result["data"]["data"]) {
      var roomItem = LiveRoomItem(
        roomId: item["web_rid"],
        title: item["room"]["title"].toString(),
        cover: item["room"]["cover"]["url_list"][0].toString(),
        userName: item["room"]["owner"]["nickname"].toString(),
        online:
            int.tryParse(
              item["room"]["room_view_stats"]["display_value"].toString(),
            ) ??
            0,
      );
      items.add(roomItem);
    }
    return LiveCategoryResult(hasMore: hasMore, items: items);
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({
    required String roomId,
    bool asAccount = false,
  }) async {
    var arr = roomId.split(";");
    var shareUrl = "";
    if (arr.length > 1) {
      shareUrl = arr[1];
    }
    roomId = arr[0];
    // 有两种roomId，一种是webRid，一种是roomId
    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // roomId一般长度为19位，例如：7376429659866598196
    // webRid是固定的，用户每次开播都是同一个webRid
    // webRid一般长度为11-12位，例如：416144012050
    // 这里简单进行判断，如果roomId长度小于15，则认为是webRid
    if (roomId.length <= 16) {
      var webRid = roomId;
      return await getRoomDetailByWebRid(webRid, shareUrl, asAccount: asAccount);
    }

    return await getRoomDetailByRoomId(roomId, asAccount: asAccount);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByRoomId(
    String roomId, {
    bool asAccount = false,
  }) async {
    // reflow/info 是匿名端点：读取恒走游客 ttwid，带 sessionid 会判 invalid session
    var roomData = await _getRoomDataByRoomId(roomId);

    // 通过房间信息获取WebRid
    var webRid = roomData["data"]["room"]["owner"]["web_rid"].toString();

    // 读取用户唯一ID，用于弹幕连接
    // 似乎这个参数不是必须的，先随机生成一个
    //var userUniqueId = await _getUserUniqueId(webRid);
    var userUniqueId = generateRandomNumber(12).toString();

    var room = roomData["data"]["room"];
    var owner = room["owner"];

    var status = asT<int?>(room["status"]) ?? 0;

    // roomId是一次性的，用户每次重新开播都会生成一个新的roomId
    // 所以如果roomId对应的直播间状态不是直播中，就通过webRid获取直播间信息
    if (status == 4) {
      var result = await getRoomDetailByWebRid(webRid, "", asAccount: asAccount);
      return result;
    }

    var roomStatus = status == 2;
    // 弹幕 args cookie 跟随身份：账号态为 loginCookie，游客态为 ttwid
    var headers = await getRequestHeaders(asAccount: asAccount);

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: owner["nickname"].toString(),
      userAvatar: owner["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner["signature"].toString(),
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
      ),
      data: room["stream_url"],
    );
  }

  /// 通过WebRid获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> getRoomDetailByWebRid(
    String webRid,
    String shareUrl, {
    bool asAccount = false,
  }) async {
    // 无进场副作用：优先 GET HTML；失败再用 shareUrl 走 reflow
    try {
      return await _getRoomDetailByWebRidHtml(webRid, asAccount: asAccount);
    } on DouyinGuestVerifyRequired {
      // 验证信号必须直达宿主弹窗，不能被 shareUrl 直连兜底吞掉
      rethrow;
    } catch (e) {
      CoreLog.error(e);
      if (shareUrl != "") {
        return await _getRoomDetailByShareUrl(shareUrl, asAccount: asAccount);
      }
      rethrow;
    }
  }

  /// 通过shareUrl访问直播间网页，从网页HTML中获取直播间信息
  /// - [shareUrl] 直播间shareUrl
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByShareUrl(
    String shareUrl, {
    bool asAccount = false,
  }) async {
    var roomId = await _parseDouyinShareRoomId(shareUrl);
    if (roomId.isEmpty) {
      throw Exception("无法解析此链接");
    }
    return getRoomDetail(roomId: roomId, asAccount: asAccount);
  }

  Future<String> _parseDouyinShareRoomId(String url) async {
    if (url.contains("live.douyin.com")) {
      return RegExp(r"live\.douyin\.com/([\d\w]+)").firstMatch(url)?.group(1) ??
          "";
    }

    if (url.contains("webcast.amemv.com")) {
      var shareUrl = await _getShareUrlFromWebcastPage(url);
      return RegExp(r"reflow/(\d+)").firstMatch(shareUrl)?.group(1) ?? "";
    }

    if (url.contains("v.douyin.com")) {
      var shortUrl =
          RegExp(
            r"https?:\/\/v.douyin.com\/[\d\w]+\/?",
          ).firstMatch(url)?.group(0) ??
          "";
      var location = await _getRedirectLocation(shortUrl);
      if (location.isNotEmpty && location != url) {
        return _parseDouyinShareRoomId(location);
      }
    }

    return "";
  }

  Future<String> _getRedirectLocation(String url) async {
    try {
      if (url.isEmpty) return "";
      await Dio().get(url, options: Options(followRedirects: false));
    } on DioException catch (e) {
      if (e.response?.statusCode == 302) {
        return e.response?.headers.value("Location") ?? "";
      }
    } catch (e) {
      CoreLog.error(e);
    }
    return "";
  }

  Future<String> _getShareUrlFromWebcastPage(String url) async {
    try {
      if (url.isEmpty) return "";
      var response = await Dio().get<String>(url);
      return RegExp(
            r'\\"shareUrl\\"\s*:\s*\\"(.*?)\\"',
          ).firstMatch(response.data ?? "")?.group(1) ??
          "";
    } on DioException catch (e) {
      CoreLog.error(e);
      if (e.response?.statusCode == 302) {
        return e.response?.headers.value("Location") ?? "";
      }
    } catch (e) {
      CoreLog.error(e);
    }
    return "";
  }

  /// 通过WebRid访问直播间网页，从网页HTML中获取直播间信息
  /// - [webRid] 直播间RID
  /// - 返回直播间信息
  Future<LiveRoomDetail> _getRoomDetailByWebRidHtml(
    String webRid, {
    bool asAccount = false,
  }) async {
    var roomData = await _getRoomDataByHtml(webRid, asAccount: asAccount);
    var headers = await getRequestHeaders(asAccount: asAccount);
    var room = roomData["roomStore"]?["roomInfo"]?["room"];
    if (room == null) {
      // 账号态骨架更可能是被该房限制/拉黑：抛错交由进入流程回滚到游客态
      if (asAccount) {
        throw CoreError("无法以账号身份读取该房间（可能被主播限制）");
      }
      // SSR 仅下发占位骨架、无场次信息：按未开播处理，不崩溃
      return buildOfflineDetail(
        webRid: webRid,
        state: roomData,
        headers: headers,
      );
    }

    var roomId = room["id_str"].toString();
    var userUniqueId =
        roomData["userStore"]?["odin"]?["user_unique_id"]?.toString() ??
            generateRandomNumber(12).toString();

    var owner = room["owner"];
    var anchor = roomData["roomStore"]["roomInfo"]["anchor"];
    var roomStatus = (asT<int?>(room["status"]) ?? 0) == 2;

    return LiveRoomDetail(
      roomId: webRid,
      title: room["title"].toString(),
      cover: roomStatus ? room["cover"]["url_list"][0].toString() : "",
      userName: roomStatus
          ? owner["nickname"].toString()
          : anchor["nickname"].toString(),
      userAvatar: roomStatus
          ? owner["avatar_thumb"]["url_list"][0].toString()
          : anchor["avatar_thumb"]["url_list"][0].toString(),
      online: roomStatus
          ? asT<int?>(room["room_view_stats"]["display_value"]) ?? 0
          : 0,
      status: roomStatus,
      url: "https://live.douyin.com/$webRid",
      introduction: owner?["signature"]?.toString() ?? "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: roomId,
        userId: userUniqueId,
        cookie: headers["cookie"],
      ),
      data: roomStatus ? room["stream_url"] : {},
    );
  }

  /// 读取用户的唯一ID
  /// - [webRid] 直播间RID
  // ignore: unused_element
  Future<String> _getUserUniqueId(String webRid) async {
    try {
      var webInfo = await _getRoomDataByHtml(webRid);
      return webInfo["userStore"]["odin"]["user_unique_id"].toString();
    } catch (e) {
      return generateRandomNumber(12).toString();
    }
  }

  /// 进入直播间前需要先获取cookie
  /// - [webRid] 直播间RID
  Future<String> _getWebCookie(String webRid) async {
    var headResp = await HttpClient.instance.head(
      "https://live.douyin.com/$webRid",
      header: headers,
    );
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("msToken")) {
        dyCookie += "$cookie;";
      }
    });
    return dyCookie;
  }

  /// 从直播间页面 HTML 中解析 state
  static Map parseRoomStateFromHtml(String result) {
    var renderData =
        RegExp(
          r'\{\\"state\\":\{\\"appStore.*?\]\\n',
        ).firstMatch(result)?.group(0) ??
        "";
    if (renderData.isEmpty) {
      throw CoreError("无法读取直播间页面信息，请稍后手动重试");
    }
    var str = renderData
        .trim()
        .replaceAll('\\"', '"')
        .replaceAll(r"\\", r"\")
        .replaceAll(']\\n', "");
    var renderDataJson = json.decode(str);
    return renderDataJson["state"];
  }

  /// 从页面 state 中判定是否直播中（room.status==2）；字段缺失安全降级
  static bool isRoomLiving(Map state) {
    var room = state["roomStore"]?["roomInfo"]?["room"];
    return (asT<int?>(room?["status"]) ?? 0) == 2;
  }

  /// SSR state 是否含有效场次 room 块
  static bool hasRoomInfo(Map state) =>
      state["roomStore"]?["roomInfo"]?["room"] != null;

  /// roomInfo 无 room 场次块时的离线占位详情
  /// （部分房间 SSR 仅下发 {web_rid, web_stream_url} 骨架，真实数据靠客户端 hydrate）
  static LiveRoomDetail buildOfflineDetail({
    required String webRid,
    required Map state,
    required Map headers,
  }) {
    final info = (state["roomStore"]?["roomInfo"] as Map?) ?? const {};
    final anchor = info["anchor"] as Map?;
    final userId =
        state["userStore"]?["odin"]?["user_unique_id"]?.toString() ??
            generateRandomNumber(12).toString();
    return LiveRoomDetail(
      roomId: webRid,
      title: "",
      cover: "",
      userName: anchor?["nickname"]?.toString() ?? "",
      userAvatar:
          anchor?["avatar_thumb"]?["url_list"]?[0]?.toString() ?? "",
      online: 0,
      status: false,
      url: "https://live.douyin.com/$webRid",
      introduction: "",
      notice: "",
      danmakuData: DouyinDanmakuArgs(
        webRid: webRid,
        roomId: "",
        userId: userId,
        cookie: headers["cookie"]?.toString() ?? "",
      ),
      data: const {},
    );
  }

  Future<Map> _getRoomDataByHtml(
    String webRid, {
    bool asAccount = false,
  }) async {
    final identityCookie = asAccount ? loginCookie : cookie;
    final fetcher = htmlFetcher;
    if (fetcher != null) {
      // 真实浏览器内核同源取页面（cookie 为空也合法：webview 已持有 ttwid）
      final html = await fetcher(webRid, identityCookie);
      return parseRoomStateFromHtml(html);
    }

    // 身份 cookie 可用时直接携带；未设置再降级为匿名 ttwid。纯 GET 文档不触发进场
    var dyCookie = identityCookie.isNotEmpty
        ? identityCookie
        : await _getWebCookie(webRid);
    var result = await _getText(
      "https://live.douyin.com/$webRid",
      queryParameters: {},
      header: {
        "Authority": kDefaultAuthority,
        "Referer": kDefaultReferer,
        "Cookie": dyCookie,
        "User-Agent": kDefaultUserAgent,
      },
    );

    return parseRoomStateFromHtml(result);
  }

  /// 通过roomId获取直播间信息
  /// - [roomId] 直播间ID
  Future<Map> _getRoomDataByRoomId(String roomId) async {
    var result = await _getJson(
      'https://webcast.amemv.com/webcast/room/reflow/info/',
      queryParameters: {
        "type_id": 0,
        "live_id": 1,
        "room_id": roomId,
        "sec_user_id": "",
        "version_code": "99.99.99",
        "app_id": 6383,
      },
      header: await getRequestHeaders(asAccount: false),
    );
    return result;
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    List<LivePlayQuality> qualities = [];

    try {
      var liveCoreData = detail.data["live_core_sdk_data"];

      if (liveCoreData == null) {
        return qualities;
      }

      var pullData = liveCoreData["pull_data"];

      if (pullData == null) {
        return qualities;
      }

      var options = pullData["options"];

      var qulityList = options?["qualities"];

      var streamData = pullData["stream_data"]?.toString() ?? "";

      if (!streamData.startsWith('{')) {
        var flvList = (detail.data["flv_pull_url"] as Map).values
            .cast<String>()
            .toList();
        var hlsList = (detail.data["hls_pull_url_map"] as Map).values
            .cast<String>()
            .toList();
        for (var quality in qulityList) {
          int level = quality["level"];
          List<String> urls = [];
          var flvIndex = flvList.length - level;
          if (flvIndex >= 0 && flvIndex < flvList.length) {
            urls.add(flvList[flvIndex]);
          }
          var hlsIndex = hlsList.length - level;
          if (hlsIndex >= 0 && hlsIndex < hlsList.length) {
            urls.add(hlsList[hlsIndex]);
          }
          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: level,
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      } else {
        var qualityData = json.decode(streamData)["data"] as Map;

        for (var quality in qulityList) {
          List<String> urls = [];

          var flvUrl = qualityData[quality["sdk_key"]]?["main"]?["flv"]
              ?.toString();

          if (flvUrl != null && flvUrl.isNotEmpty) {
            urls.add(flvUrl);
          }
          var hlsUrl = qualityData[quality["sdk_key"]]?["main"]?["hls"]
              ?.toString();

          if (hlsUrl != null && hlsUrl.isNotEmpty) {
            urls.add(hlsUrl);
          }

          var qualityItem = LivePlayQuality(
            quality: quality["name"],
            sort: quality["level"],
            data: urls,
          );
          if (urls.isNotEmpty) {
            qualities.add(qualityItem);
          }
        }
      }
    } catch (e, stackTrace) {
      CoreLog.error(e);
      CoreLog.error(stackTrace);
    }
    // var qualityData = json.decode(
    //     detail.data["live_core_sdk_data"]["pull_data"]["stream_data"])["data"];

    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    _logDebug("获取到的画质列表: ${qualities.map((q) => q.quality).toList()}");
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    // 返回列表的副本，防止外部 clear() 影响原始数据
    return LivePlayUrl(urls: List<String>.from(quality.data));
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(
    String keyword, {
    int page = 1,
  }) async {
    final fetcher = searchFetcher;
    if (fetcher != null) {
      return _parseSearchResult(await fetcher(keyword, page: page));
    }
    return _searchRoomsDirect(keyword, page);
  }

  /// Dio 直连兜底。搜索已强制受信浏览器环境，此路径通常会被风控；
  /// 合并账号登录态后在部分网络/会话下仍可能成功
  Future<LiveSearchRoomResult> _searchRoomsDirect(
    String keyword,
    int page,
  ) async {
    String serverUrl = "https://www.douyin.com/aweme/v1/web/live/search/";
    var uri = Uri.parse(serverUrl).replace(
      scheme: "https",
      port: 443,
      queryParameters: {
        "device_platform": "webapp",
        "aid": "6383",
        "channel": "channel_pc_web",
        "search_channel": "aweme_live",
        "keyword": keyword,
        "search_source": "switch_tab",
        "query_correct_type": "1",
        "is_filter_search": "0",
        "from_group_id": "",
        "offset": ((page - 1) * 10).toString(),
        "count": "10",
        "pc_client_type": "1",
        "version_code": "170400",
        "version_name": "17.4.0",
        "cookie_enabled": "true",
        "screen_width": "1980",
        "screen_height": "1080",
        "browser_language": "zh-CN",
        "browser_platform": "Win32",
        "browser_name": "Edge",
        "browser_version": "125.0.0.0",
        "browser_online": "true",
        "engine_name": "Blink",
        "engine_version": "125.0.0.0",
        "os_name": "Windows",
        "os_version": "10",
        "cpu_core_num": "12",
        "device_memory": "8",
        "platform": "PC",
        "downlink": "10",
        "effective_type": "4g",
        "round_trip_time": "100",
        "webid": "7382872326016435738",
      },
    );
    //var requlestUrl = await getAbogusUrl(uri.toString());
    var requlestUrl = uri.toString();
    var headResp = await HttpClient.instance.head(
      'https://live.douyin.com',
      header: headers,
    );
    var dyCookie = "";
    headResp.headers["set-cookie"]?.forEach((element) {
      var cookie = element.split(";")[0];
      if (cookie.contains("ttwid")) {
        dyCookie += "$cookie;";
      }
      if (cookie.contains("__ac_nonce")) {
        dyCookie += "$cookie;";
      }
    });
    // 合并账号登录态（含 sessionid），否则接口以 status_code 2483 要求登录
    if (loginCookie.contains("sessionid")) {
      dyCookie = "$dyCookie; $loginCookie";
    }

    var result = await _getJson(
      requlestUrl,
      queryParameters: {},
      header: {
        "Authority": 'www.douyin.com',
        'accept': 'application/json, text/plain, */*',
        'accept-language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'cookie': dyCookie,
        'priority': 'u=1, i',
        'referer':
            'https://www.douyin.com/search/${Uri.encodeComponent(keyword)}?type=live',
        'sec-ch-ua':
            '"Microsoft Edge";v="125", "Chromium";v="125", "Not.A/Brand";v="24"',
        'sec-ch-ua-mobile': '?0',
        'sec-ch-ua-platform': '"Windows"',
        'sec-fetch-dest': 'empty',
        'sec-fetch-mode': 'cors',
        'sec-fetch-site': 'same-origin',
        'user-agent': kDefaultUserAgent,
      },
    );
    if (result == "" || result == 'blocked') {
      throw Exception("抖音直播搜索被限制，请稍后再试");
    }
    return _parseSearchResult(result);
  }

  /// 搜索结果统一解析：先查 status_code / 风控空结果，再解析 rawdata
  LiveSearchRoomResult _parseSearchResult(Map<dynamic, dynamic> result) {
    if (result["status_code"] == 2483) {
      throw DouyinLoginRequired();
    }
    final nilInfo = result["search_nil_info"];
    final nilType =
        nilInfo is Map ? nilInfo["search_nil_type"]?.toString() : null;

    var items = <LiveRoomItem>[];
    final dataList = result["data"];
    if (dataList == null || (dataList is List && dataList.isEmpty)) {
      if (nilType == "verify_check") {
        throw DouyinRiskControl();
      }
    }
    for (var item in dataList ?? []) {
      var itemData = json.decode(item["lives"]["rawdata"].toString());
      var roomItem = LiveRoomItem(
        roomId: itemData["owner"]["web_rid"].toString(),
        title: itemData["title"].toString(),
        cover: itemData["cover"]["url_list"][0].toString(),
        userName: itemData["owner"]["nickname"].toString(),
        online: int.tryParse(itemData["stats"]["total_user"].toString()) ?? 0,
      );
      items.add(roomItem);
    }
    return LiveSearchRoomResult(hasMore: items.length >= 10, items: items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(
    String keyword, {
    int page = 1,
  }) async {
    throw Exception("抖音暂不支持搜索主播，请直接搜索直播间");
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    // 仅做无进场副作用的查询：GET HTML / reflow，不调 web enter 接口
    var key = roomId.split(";")[0];
    if (key.length > 16) {
      var data = await _getRoomDataByRoomId(key);
      return (asT<int?>(data["data"]?["room"]?["status"]) ?? 0) == 2;
    }
    return isRoomLiving(await _getRoomDataByHtml(key));
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) {
    return Future.value(<LiveSuperChatMessage>[]);
  }

  //生成指定长度的16进制随机字符串
  String generateRandomString(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(16));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item.toRadixString(16));
    }
    return stringBuffer.toString();
  }

  // 生成随机的数字
  static int generateRandomNumber(int length) {
    var random = Random.secure();
    var values = List<int>.generate(length, (i) => random.nextInt(10));
    StringBuffer stringBuffer = StringBuffer();
    for (var item in values) {
      stringBuffer.write(item);
    }
    return int.tryParse(stringBuffer.toString()) ??
        Random().nextInt(1000000000);
  }
}
