// ignore_for_file: overridden_fields
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class TwitchDanmakuArgs {
  /// 频道登录名（小写）
  final String channel;

  /// OAuth token（为空时匿名连接，不能发送）
  final String oauthToken;

  /// 自身登录名（有 token 时必填，用于 NICK）
  final String userLogin;

  TwitchDanmakuArgs({
    required this.channel,
    this.oauthToken = "",
    this.userLogin = "",
  });
}

class TwitchDanmaku extends LiveDanmaku {
  @override
  int heartbeatTime = 0;

  @override
  Function(LiveMessage msg)? onMessage;
  @override
  Function(String msg)? onClose;
  @override
  Function()? onReady;

  WebSocketChannel? _channel;
  bool _closed = false;

  late TwitchDanmakuArgs danmakuArgs;

  @override
  void heartbeat() {}

  @override
  Future start(dynamic args) async {
    danmakuArgs = args as TwitchDanmakuArgs;
    _closed = false;
    _channel = WebSocketChannel.connect(
      Uri.parse("wss://irc-ws.chat.twitch.tv:443"),
    );

    _channel!.stream.listen(
      (event) => _handleMessage(event.toString(), danmakuArgs),
      onError: (e) {
        CoreLog.error(e);
        onClose?.call("与服务器连接断开");
      },
      onDone: () {
        if (!_closed) {
          onClose?.call("与服务器连接断开");
        }
      },
      cancelOnError: true,
    );

    _send("CAP REQ :twitch.tv/tags twitch.tv/commands");
    if (danmakuArgs.oauthToken.isNotEmpty &&
        danmakuArgs.userLogin.isNotEmpty) {
      _send("PASS oauth:${danmakuArgs.oauthToken}");
      _send("NICK ${danmakuArgs.userLogin}");
    } else {
      var nick = "justinfan${Random().nextInt(90000) + 10000}";
      _send("NICK $nick");
    }
    _send("JOIN #${danmakuArgs.channel}");
  }

  void _send(String message) {
    _channel?.sink.add("$message\r\n");
  }

  void _handleMessage(String raw, TwitchDanmakuArgs args) {
    for (var line in raw.split("\r\n")) {
      if (line.isEmpty) {
        continue;
      }
      _handleLine(line);
    }
  }

  void _handleLine(String line) {
    try {
      if (line.startsWith("PING")) {
        _send(line.replaceFirst("PING", "PONG"));
        return;
      }
      if (line.startsWith("RECONNECT")) {
        onClose?.call("服务器要求重新连接");
        return;
      }

      String? tagsRaw;
      var remainder = line;
      if (line.startsWith("@")) {
        var spaceIndex = line.indexOf(" ");
        tagsRaw = line.substring(1, spaceIndex);
        remainder = line.substring(spaceIndex + 1);
      }

      var trailingIndex = remainder.indexOf(" :");
      var trailing =
          trailingIndex >= 0 ? remainder.substring(trailingIndex + 2) : "";
      var tokens = trailingIndex >= 0
          ? remainder.substring(0, trailingIndex).split(" ")
          : remainder.split(" ");

      // :nick!user@host COMMAND target
      if (tokens.length < 2) {
        return;
      }
      var command = tokens[1];
      if (command == "PRIVMSG") {
        _parsePrivmsg(tagsRaw, tokens[0], trailing);
      } else if (command == "366") {
        onReady?.call();
      }
    } catch (e) {
      CoreLog.error(e);
    }
  }

  void _parsePrivmsg(String? tagsRaw, String prefix, String text) {
    var tags = <String, String>{};
    if (tagsRaw != null) {
      for (var pair in tagsRaw.split(";")) {
        var index = pair.indexOf("=");
        if (index > 0) {
          tags[pair.substring(0, index)] =
              _unescapeTag(pair.substring(index + 1));
        }
      }
    }

    var nick = prefix.startsWith(":")
        ? prefix.substring(1).split("!").first
        : prefix;
    var userName = tags["display-name"]?.isNotEmpty == true
        ? tags["display-name"]!
        : nick;
    var colorText = tags["color"] ?? "";
    var color = colorText.startsWith("#")
        ? _parseHexColor(colorText)
        : LiveMessageColor.white;

    onMessage?.call(LiveMessage(
      type: LiveMessageType.chat,
      userName: userName,
      message: text,
      color: color,
    ));
  }

  String _unescapeTag(String value) {
    var buffer = StringBuffer();
    for (var i = 0; i < value.length; i++) {
      var c = value[i];
      if (c == r"\" && i + 1 < value.length) {
        var next = value[i + 1];
        switch (next) {
          case ":":
            buffer.write(";");
            break;
          case "s":
            buffer.write(" ");
            break;
          case r"\":
            buffer.write(r"\");
            break;
          case "r":
            buffer.write("\r");
            break;
          case "n":
            buffer.write("\n");
            break;
          default:
            buffer.write(next);
        }
        i++;
      } else {
        buffer.write(c);
      }
    }
    return buffer.toString();
  }

  LiveMessageColor _parseHexColor(String hex) {
    var value = int.tryParse(hex.substring(1), radix: 16) ?? 0;
    return LiveMessageColor(
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    );
  }

  /// IRC 行内禁止 CR/LF/NUL：替换为空格，防止多行粘贴被解析为多条 IRC 命令
  static String sanitizeIrcMessage(String m) =>
      m.replaceAll(RegExp(r'[\r\n\x00]'), ' ');

  /// 按 RFC 1459 口径将消息按 UTF-8 字节安全截断到 [maxBytes]；
  /// 以 Unicode 码元为单位缩短，不切坏代理对
  static String truncateIrcMessage(String m, {int maxBytes = 450}) {
    if (utf8.encode(m).length <= maxBytes) {
      return m;
    }
    var buffer = StringBuffer();
    var length = 0;
    for (var rune in m.runes) {
      var byteLength = utf8.encode(String.fromCharCode(rune)).length;
      if (length + byteLength > maxBytes) {
        break;
      }
      buffer.writeCharCode(rune);
      length += byteLength;
    }
    return buffer.toString();
  }

  @override
  Future<DanmakuSendResult> sendMessage(String message) async {
    // 断线/未连接必须先于成功返回；不做本地补显，避免假成功
    if (_channel == null || _closed) {
      return DanmakuSendResult(
        success: false,
        errorCode: "network_error",
        errorMessage: "与服务器连接断开",
      );
    }
    if (danmakuArgs.oauthToken.isEmpty || danmakuArgs.userLogin.isEmpty) {
      return DanmakuSendResult(
        success: false,
        errorCode: "not_login",
        errorMessage: "未配置 Twitch 账号",
      );
    }
    var safeMessage = truncateIrcMessage(sanitizeIrcMessage(message));
    _send("PRIVMSG #${danmakuArgs.channel} :$safeMessage");
    return DanmakuSendResult(success: true, needLocalEcho: true);
  }

  @override
  Future stop() async {
    _closed = true;
    onMessage = null;
    onClose = null;
    onReady = null;
    await _channel?.sink.close();
    _channel = null;
  }
}
