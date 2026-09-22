import 'dart:math';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/danmaku/twitch_danmaku.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';

class TwitchSite implements LiveSite {
  @override
  String id = "twitch";

  @override
  String name = "Twitch";

  /// Twitch 网页版内置公开 Client-ID
  static const String kWebClientId = "kimne78kx3ncx6brgo4mv6wki5h1ko";

  String clientId = kWebClientId;

  /// 用户配置的 OAuth Token，非空时元数据走 Helix
  String oauthToken = "";

  bool get useHelix => oauthToken.isNotEmpty;

  @override
  LiveDanmaku getDanmaku() => TwitchDanmaku();

  late final String _deviceId = _generateDeviceId();

  String _generateDeviceId() {
    var random = Random.secure();
    return List.generate(32, (_) => random.nextInt(16).toRadixString(16)).join();
  }

  Map<String, String> get _gqlHeader => {
        "Client-ID": clientId,
        "X-Device-Id": _deviceId,
        "Content-Type": "application/json",
      };

  Map<String, String> get _helixHeader => {
        "Client-ID": clientId,
        "Authorization": "Bearer $oauthToken",
      };

  Future<Map<String, dynamic>> gqlPost(
      String query, Map<String, dynamic> variables) async {
    var result = await HttpClient.instance.postJson(
      "https://gql.twitch.tv/gql",
      data: {
        "query": query,
        "variables": variables,
      },
      header: _gqlHeader,
    );
    if (result["errors"] != null) {
      throw CoreError(result["errors"].toString());
    }
    return result["data"] as Map<String, dynamic>;
  }

  Future<dynamic> helixGet(String path,
      [Map<String, String>? queryParameters]) async {
    var result = await HttpClient.instance.getJson(
      "https://api.twitch.tv/helix$path",
      queryParameters: queryParameters ?? {},
      header: _helixHeader,
    );
    if (result["error"] != null) {
      throw CoreError(result["message"]?.toString() ?? result["error"].toString());
    }
    return result["data"];
  }

  static String imageSize(String url, int width, int height) {
    return url
        .replaceAll("{width}", width.toString())
        .replaceAll("{height}", height.toString());
  }

  // ================================ 分区 ================================

  @override
  Future<List<LiveCategory>> getCategores() async {
    return useHelix ? _helixCategories() : _gqlCategories();
  }

  Future<List<LiveCategory>> _gqlCategories() async {
    var data = await gqlPost(
      r"""
      query {
        games(first: 100, sort: VIEWER_COUNT) {
          edges { node { id name boxArtURL } }
        }
      }
      """,
      {},
    );
    return [_buildCategory(
      (data["games"]["edges"] as List)
          .map((e) => e["node"] as Map<String, dynamic>)
          .toList(),
      (g) => g["id"].toString(),
      (g) => g["name"].toString(),
      (g) => imageSize(g["boxArtURL"].toString(), 100, 100),
    )];
  }

  Future<List<LiveCategory>> _helixCategories() async {
    var list = await helixGet("/games/top", {"first": "100"}) as List;
    return [_buildCategory(
      list.cast<Map<String, dynamic>>(),
      (g) => g["id"].toString(),
      (g) => g["name"].toString(),
      (g) => imageSize(g["box_art_url"].toString(), 100, 100),
    )];
  }

  LiveCategory _buildCategory(
    List<Map<String, dynamic>> games,
    String Function(Map<String, dynamic>) idOf,
    String Function(Map<String, dynamic>) nameOf,
    String Function(Map<String, dynamic>) picOf,
  ) {
    var subs = games
        .map((g) => LiveSubCategory(
              id: idOf(g),
              name: nameOf(g),
              parentId: idOf(g),
              pic: picOf(g),
            ))
        .toList();
    return LiveCategory(id: "all", name: "Twitch 分区", children: subs);
  }

  // ================================ 分区房间 ================================

  final Map<String, String> _gameCursors = {};

  @override
  Future<LiveCategoryResult> getCategoryRooms(LiveSubCategory category,
      {int page = 1}) async {
    return useHelix
        ? _helixCategoryRooms(category, page)
        : _gqlCategoryRooms(category, page);
  }

  Future<LiveCategoryResult> _gqlCategoryRooms(
      LiveSubCategory category, int page) async {
    var cursorKey = category.id;
    var data = await gqlPost(
      r"""
      query($gameId: ID!, $after: Cursor) {
        game(id: $gameId) {
          streams(first: 30, after: $after) {
            edges {
              cursor
              node {
                title viewersCount previewImageURL
                broadcaster { login displayName avatarURL }
              }
            }
            pageInfo { hasNextPage }
          }
        }
      }
      """,
      {
        "gameId": category.id,
        "after": page == 1 ? null : _gameCursors[cursorKey],
      },
    );
    var streams = data["game"]["streams"];
    return _buildStreamResult(streams, cursorKey, _gameCursors, (node) {
      return _gqlRoomItem(node);
    });
  }

  Future<LiveCategoryResult> _helixCategoryRooms(
      LiveSubCategory category, int page) async {
    var params = <String, String>{
      "game_id": category.id,
      "first": "30",
    };
    if (page > 1 && _gameCursors[category.id] != null) {
      params["after"] = _gameCursors[category.id]!;
    }
    var result = await HttpClient.instance.getJson(
      "https://api.twitch.tv/helix/streams",
      queryParameters: params,
      header: _helixHeader,
    );
    return _helixStreamResult(result, category.id, _gameCursors);
  }

  // ================================ 推荐 ================================

  String? _recommendCursor;

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    return useHelix ? _helixRecommend(page) : _gqlRecommend(page);
  }

  Future<LiveCategoryResult> _gqlRecommend(int page) async {
    var data = await gqlPost(
      r"""
      query($after: Cursor) {
        streams(first: 30, after: $after) {
          edges {
            cursor
            node {
              title viewersCount previewImageURL
              broadcaster { login displayName avatarURL }
            }
          }
          pageInfo { hasNextPage }
        }
      }
      """,
      {"after": page == 1 ? null : _recommendCursor},
    );
    var edges = data["streams"]["edges"] as List;
    if (edges.isNotEmpty) {
      _recommendCursor = edges.last["cursor"].toString();
    }
    var items = edges
        .map((e) => _gqlRoomItem(e["node"] as Map<String, dynamic>))
        .toList();
    return LiveCategoryResult(
      hasMore: data["streams"]["pageInfo"]["hasNextPage"] == true,
      items: items,
    );
  }

  Future<LiveCategoryResult> _helixRecommend(int page) async {
    var params = <String, String>{"first": "30"};
    if (page > 1 && _recommendCursor != null) {
      params["after"] = _recommendCursor!;
    }
    var result = await HttpClient.instance.getJson(
      "https://api.twitch.tv/helix/streams",
      queryParameters: params,
      header: _helixHeader,
    );
    var list = result["data"] as List;
    var cursor = result["pagination"]?["cursor"]?.toString();
    if (cursor != null) {
      _recommendCursor = cursor;
    }
    return LiveCategoryResult(
      hasMore: cursor != null && list.length >= 30,
      items: list
          .map((e) => _helixRoomItem(e as Map<String, dynamic>))
          .toList(),
    );
  }

  LiveCategoryResult _buildStreamResult(
    Map<String, dynamic> streams,
    String cursorKey,
    Map<String, String> cursorStore,
    LiveRoomItem Function(Map<String, dynamic> node) itemBuilder,
  ) {
    var edges = streams["edges"] as List;
    if (edges.isNotEmpty) {
      cursorStore[cursorKey] = edges.last["cursor"].toString();
    }
    return LiveCategoryResult(
      hasMore: streams["pageInfo"]["hasNextPage"] == true,
      items: edges
          .map((e) => itemBuilder(e["node"] as Map<String, dynamic>))
          .toList(),
    );
  }

  LiveCategoryResult _helixStreamResult(
    Map<String, dynamic> result,
    String cursorKey,
    Map<String, String> cursorStore,
  ) {
    var list = result["data"] as List;
    var cursor = result["pagination"]?["cursor"]?.toString();
    if (cursor != null) {
      cursorStore[cursorKey] = cursor;
    }
    return LiveCategoryResult(
      hasMore: cursor != null && list.length >= 30,
      items: list
          .map((e) => _helixRoomItem(e as Map<String, dynamic>))
          .toList(),
    );
  }

  LiveRoomItem _gqlRoomItem(Map<String, dynamic> node) {
    var broadcaster = node["broadcaster"] as Map<String, dynamic>;
    return LiveRoomItem(
      roomId: broadcaster["login"].toString(),
      title: node["title"].toString(),
      cover: imageSize(node["previewImageURL"].toString(), 1280, 720),
      userName: broadcaster["displayName"].toString(),
      online: int.tryParse(node["viewersCount"].toString()) ?? 0,
    );
  }

  LiveRoomItem _helixRoomItem(Map<String, dynamic> s) {
    return LiveRoomItem(
      roomId: s["user_login"].toString(),
      title: s["title"].toString(),
      cover: imageSize(s["thumbnail_url"].toString(), 1280, 720),
      userName: s["user_name"].toString(),
      online: int.tryParse(s["viewer_count"].toString()) ?? 0,
    );
  }

  // ================================ 搜索 ================================

  final Map<String, String> _searchCursors = {};

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword,
      {int page = 1}) async {
    return useHelix
        ? _helixSearchRooms(keyword, page)
        : _gqlSearchRooms(keyword, page);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword,
      {int page = 1}) async {
    return useHelix
        ? _helixSearchAnchors(keyword, page)
        : _gqlSearchAnchors(keyword, page);
  }

  Future<Map<String, dynamic>> _searchTray(
      String keyword, int page) async {
    return gqlPost(
      r"""
      query($query: String!, $after: Cursor) {
        searchTray(first: 30, query: $query, after: $after) {
          edges {
            cursor
            node {
              __typename
              ... on Stream {
                title viewersCount previewImageURL
                broadcaster { login displayName avatarURL }
              }
              ... on Channel {
                login displayName avatarURL
                stream { id }
              }
            }
          }
          pageInfo { hasNextPage }
        }
      }
      """,
      {
        "query": keyword,
        "after": page == 1 ? null : _searchCursors[keyword],
      },
    );
  }

  Future<LiveSearchRoomResult> _gqlSearchRooms(String keyword, int page) async {
    var data = await _searchTray(keyword, page);
    var edges = data["searchTray"]["edges"] as List;
    if (edges.isNotEmpty) {
      _searchCursors[keyword] = edges.last["cursor"].toString();
    }
    var items = edges
        .map((e) => e["node"] as Map<String, dynamic>)
        .where((node) => node["__typename"] == "Stream")
        .map((node) => _gqlRoomItem(node))
        .toList();
    return LiveSearchRoomResult(
      hasMore: data["searchTray"]["pageInfo"]["hasNextPage"] == true,
      items: items,
    );
  }

  Future<LiveSearchAnchorResult> _gqlSearchAnchors(
      String keyword, int page) async {
    var data = await _searchTray(keyword, page);
    var edges = data["searchTray"]["edges"] as List;
    if (edges.isNotEmpty) {
      _searchCursors[keyword] = edges.last["cursor"].toString();
    }
    var items = edges
        .map((e) => e["node"] as Map<String, dynamic>)
        .where((node) => node["__typename"] == "Channel")
        .map((node) => LiveAnchorItem(
              roomId: node["login"].toString(),
              avatar: node["avatarURL"].toString(),
              userName: node["displayName"].toString(),
              liveStatus: node["stream"] != null,
            ))
        .toList();
    return LiveSearchAnchorResult(
      hasMore: data["searchTray"]["pageInfo"]["hasNextPage"] == true,
      items: items,
    );
  }

  Future<Map<String, dynamic>> _helixSearch(
      String keyword, int page) async {
    var params = <String, String>{
      "query": keyword,
      "first": "30",
    };
    if (page > 1 && _searchCursors[keyword] != null) {
      params["after"] = _searchCursors[keyword]!;
    }
    var result = await HttpClient.instance.getJson(
      "https://api.twitch.tv/helix/search/channels",
      queryParameters: params,
      header: _helixHeader,
    );
    var cursor = result["pagination"]?["cursor"]?.toString();
    if (cursor != null) {
      _searchCursors[keyword] = cursor;
    }
    return {
      "list": result["data"] as List,
      "hasMore": cursor != null && (result["data"] as List).length >= 30,
    };
  }

  Future<LiveSearchRoomResult> _helixSearchRooms(
      String keyword, int page) async {
    var result = await _helixSearch(keyword, page);
    var items = (result["list"] as List)
        .cast<Map<String, dynamic>>()
        .where((c) => c["is_live"] == true)
        .map((c) => LiveRoomItem(
              roomId: c["broadcaster_login"].toString(),
              title: c["title"].toString(),
              cover: imageSize(c["thumbnail_url"].toString(), 1280, 720),
              userName: c["display_name"].toString(),
            ))
        .toList();
    return LiveSearchRoomResult(hasMore: result["hasMore"] as bool, items: items);
  }

  Future<LiveSearchAnchorResult> _helixSearchAnchors(
      String keyword, int page) async {
    var result = await _helixSearch(keyword, page);
    var items = (result["list"] as List)
        .cast<Map<String, dynamic>>()
        .map((c) => LiveAnchorItem(
              roomId: c["broadcaster_login"].toString(),
              avatar: c["thumbnail_url"].toString(),
              userName: c["display_name"].toString(),
              liveStatus: c["is_live"] == true,
            ))
        .toList();
    return LiveSearchAnchorResult(
        hasMore: result["hasMore"] as bool, items: items);
  }

  // ================================ 房间详情 ================================

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    return useHelix ? _helixRoomDetail(roomId) : _gqlRoomDetail(roomId);
  }

  Future<LiveRoomDetail> _gqlRoomDetail(String roomId) async {
    var data = await gqlPost(
      r"""
      query($login: String!) {
        user(login: $login) {
          id login displayName avatarURL description
          stream {
            id title viewersCount previewImageURL createdAt
          }
        }
      }
      """,
      {"login": roomId},
    );
    var user = data["user"];
    if (user == null) {
      throw CoreError("直播间不存在");
    }
    var stream = user["stream"];
    var live = stream != null;
    return LiveRoomDetail(
      roomId: user["login"].toString(),
      title: live ? stream["title"].toString() : user["displayName"].toString(),
      cover: live
          ? imageSize(stream["previewImageURL"].toString(), 1280, 720)
          : user["avatarURL"].toString(),
      userName: user["displayName"].toString(),
      userAvatar: user["avatarURL"].toString(),
      online: live ? int.tryParse(stream["viewersCount"].toString()) ?? 0 : 0,
      status: live,
      url: "https://www.twitch.tv/${user["login"]}",
      introduction: user["description"]?.toString(),
      showTime: live ? _isoToEpoch(stream["createdAt"].toString()) : null,
      danmakuData: TwitchDanmakuArgs(
        channel: user["login"].toString(),
        oauthToken: oauthToken,
      ),
    );
  }

  Future<LiveRoomDetail> _helixRoomDetail(String roomId) async {
    var results = await Future.wait([
      HttpClient.instance.getJson(
        "https://api.twitch.tv/helix/users",
        queryParameters: {"login": roomId},
        header: _helixHeader,
      ),
      HttpClient.instance.getJson(
        "https://api.twitch.tv/helix/streams",
        queryParameters: {"user_login": roomId},
        header: _helixHeader,
      ),
    ]);
    var users = results[0]["data"] as List;
    if (users.isEmpty) {
      throw CoreError("直播间不存在");
    }
    var user = users.first;
    var streams = results[1]["data"] as List;
    var live = streams.isNotEmpty;
    var stream = live ? streams.first : null;
    return LiveRoomDetail(
      roomId: user["login"].toString(),
      title: live ? stream["title"].toString() : user["display_name"].toString(),
      cover: live
          ? imageSize(stream["thumbnail_url"].toString(), 1280, 720)
          : user["profile_image_url"].toString(),
      userName: user["display_name"].toString(),
      userAvatar: user["profile_image_url"].toString(),
      online: live ? int.tryParse(stream["viewer_count"].toString()) ?? 0 : 0,
      status: live,
      url: "https://www.twitch.tv/${user["login"]}",
      introduction: user["description"]?.toString(),
      showTime: live ? _isoToEpoch(stream["started_at"].toString()) : null,
      danmakuData: TwitchDanmakuArgs(
        channel: user["login"].toString(),
        oauthToken: oauthToken,
      ),
    );
  }

  String _isoToEpoch(String iso) {
    return (DateTime.parse(iso).millisecondsSinceEpoch ~/ 1000).toString();
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    if (useHelix) {
      var list = await helixGet("/streams", {"user_login": roomId}) as List;
      return list.isNotEmpty;
    }
    var data = await gqlPost(
      r"""
      query($login: String!) {
        user(login: $login) { stream { id } }
      }
      """,
      {"login": roomId},
    );
    return data["user"]?["stream"] != null;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage(
      {required String roomId}) async {
    return [];
  }

  // ================================ 播放 ================================

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    var playlist = await _fetchPlaylist(detail.roomId);
    var variants = _parsePlaylist(playlist);
    variants.sort((a, b) => b.$3.compareTo(a.$3));
    return variants
        .map((v) => LivePlayQuality(quality: v.$1, data: v.$2))
        .toList();
  }

  @override
  Future<LivePlayUrl> getPlayUrls(
      {required LiveRoomDetail detail,
      required LivePlayQuality quality}) async {
    return LivePlayUrl(urls: [quality.data.toString()]);
  }

  Future<String> _fetchPlaylist(String channel) async {
    var data = await gqlPost(
      r"""
      query PlaybackAccessToken(
        $login: String!, $isLive: Boolean!, $vodID: String!, $isVod: Boolean!
      ) {
        streamPlaybackAccessToken(
          channelName: $login,
          params: {
            platform: "web",
            playerBackend: "mediaplayer",
            playerType: "site"
          }
        ) { value signature }
      }
      """,
      {"login": channel, "isLive": true, "vodID": "", "isVod": false},
    );
    var token = data["streamPlaybackAccessToken"];
    return HttpClient.instance.getText(
      "https://usher.ttvnw.net/api/channel/hls/$channel.m3u8",
      queryParameters: {
        "nauth": token["value"].toString(),
        "nauthsig": token["signature"].toString(),
        "allow_source": "true",
        "allow_audio_only": "true",
        "player": "twitchweb",
      },
      header: _gqlHeader,
    );
  }

  /// 解析 master playlist，返回 (清晰度名, 播放地址, 排序权重)
  List<(String, String, int)> _parsePlaylist(String playlist) {
    var lines = playlist.split("\n");
    var result = <(String, String, int)>[];
    for (var i = 0; i < lines.length - 1; i++) {
      var line = lines[i].trim();
      if (!line.startsWith("#EXT-X-STREAM-INF")) {
        continue;
      }
      var video = RegExp(r'VIDEO="([^"]*)"').firstMatch(line)?.group(1) ?? "";
      if (video.isEmpty || video == "audio_only") {
        continue;
      }
      var url = lines[i + 1].trim();
      if (url.isEmpty || url.startsWith("#")) {
        continue;
      }
      var name = video == "chunked" ? "源画质" : video;
      result.add((name, url, _qualitySort(video)));
    }
    return result;
  }

  int _qualitySort(String video) {
    if (video == "chunked") {
      return 100000;
    }
    var match = RegExp(r"(\d+)p(?:(\d+))?").firstMatch(video);
    if (match == null) {
      return 0;
    }
    var height = int.tryParse(match.group(1)!) ?? 0;
    var fps = int.tryParse(match.group(2) ?? "") ?? 0;
    return height * 100 + fps;
  }
}
