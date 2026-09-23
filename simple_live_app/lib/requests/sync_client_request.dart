import 'package:simple_live_app/models/sync_client_info_model.dart';
import 'package:simple_live_app/requests/http_client.dart';
import 'package:simple_live_app/services/sync_service.dart';

class SyncClientRequest {
  Future<SyncClientInfoModel> getClientInfo(SyncClinet client) async {
    var url = "http://${client.address}:${client.port}/info";
    var data = await HttpClient.instance.getJson(url);

    return SyncClientInfoModel.fromJson(data);
  }

  Future<bool> syncFollow(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/follow";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTag(
      SyncClinet client,
      dynamic body, {
        bool overlay = false,
      }) async {
    var url = "http://${client.address}:${client.port}/sync/tag";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncHistory(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/history";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBlockedWord(
    SyncClinet client,
    dynamic body, {
    bool overlay = false,
  }) async {
    var url = "http://${client.address}:${client.port}/sync/blocked_word";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
      queryParameters: {
        'overlay': overlay ? '1' : '0',
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncBiliAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/bilibili";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTtwid(SyncClinet client, String ttwid) async {
    var url = "http://${client.address}:${client.port}/sync/account/ttwid";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": ttwid,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncDouyuAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/douyu";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncHuyaAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/huya";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncDouyinAccount(SyncClinet client, String cookie) async {
    var url = "http://${client.address}:${client.port}/sync/account/douyin";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "cookie": cookie,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncTwitchAccount(
    SyncClinet client,
    String clientId,
    String token,
    String login,
  ) async {
    var url = "http://${client.address}:${client.port}/sync/account/twitch";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "clientId": clientId,
        "token": token,
        "login": login,
      },
    );

    if (data["status"]) {
      return true;
    } else {
      throw data["message"];
    }
  }

  Future<bool> syncAll(
      dynamic body,String syncUrl) async {
    var url = syncUrl+"/simpleLive/updateAll";
    var data = await HttpClient.instance.postJson(
      url,
      data: body,
    );
    if (data["action"]=='done') {
      return true;
    } else {
      throw data["message"];
    }
  }
  Future<Map<String, dynamic>> getAllData(String userName,String syncUrl) async {
    var url = syncUrl+"/simpleLive/getAll";
    var data = await HttpClient.instance.postJson(
      url,
      data: {
        "userName":userName
      },
    );
    if (data!=null) {
      return data;
    } else {
      return {};
    }
  }

  Future<void> addUserData(String parmsStr, String syncUrl) async{
    var url = syncUrl+"/simpleLive/addUserData";
    await HttpClient.instance.postJson(
      url,
      data: parmsStr,
    );
  }

  Future<void> delUserData(String parmsStr, String syncUrl) async{
    var url = syncUrl+"/simpleLive/delUserData";
    await HttpClient.instance.postJson(
      url,
      data: parmsStr,
    );
  }
}
