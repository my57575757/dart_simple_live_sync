# Simple Live 发送弹幕功能设计

日期：2026-09-22
范围：simple_live_core、simple_live_app（simple_live_tv_app 暂不在本期范围）

## 1. 背景与目标

Simple Live 当前只能接收各平台弹幕，用户无法发言。本期新增「发送弹幕」能力，覆盖现有全部 5 个平台：哔哩哔哩、斗鱼、虎牙、抖音、Twitch。

设计基于 2026-09-22 的联网调研与线上验证。功能仅使用用户本人登录态调用公开接口，不做批量/机器人行为。

## 2. 各平台技术方案

| 平台 | 发送通道 | 认证凭证 | 关键工作 |
|---|---|---|---|
| 哔哩哔哩 | HTTP `POST https://api.live.bilibili.com/msg/send`，表单编码 | Cookie `SESSDATA` + `bili_jct`（现有 BiliBiliAccountService 已具备） | csrf 与 csrf_token 均取 bili_jct；roomid 必须为真实房间号；必带 Referer |
| 斗鱼 | 另连 `wss://wsproxy.douyu.com:6671~6675`（由 lapi 实时下发）；发送消息类型为 `chatmessage`（注意：接收到的弹幕广播是 `chatmsg`，二者不同） | 新增登录 Cookie：`dy_did`、`acf_uid`、`acf_stk`、`acf_ltkid` | 新增 websec 签名体系；登录后 loginreq；接收连接 danmuproxy:8506 不用于发送 |
| 虎牙 | 复用 `wss://cdnws.api.huya.com` 接收连接：先发 VerifyCookie（iCmdType=10）登录，再发 WupReq（iCmdType=3）。wup：servant=`liveui`、func=`sendMessage`、key=`tReq` | 扫码登录 Cookie：`udb_uid`、`udb_biztoken`（另有 yyuid/username/udb_guiddata） | 新增 SendMessageReq/UserId/ContentFormat/BulletFormat tars 结构 |
| 抖音 | HTTP **GET** `https://live.douyin.com/webcast/room/chat/`（旧 `/webcast/im/send/` 已废弃） | 需新增 WebView 登录获取完整 Cookie（`sessionid` 必须；现有 DouyinAccountService 仅配置 ttwid 设备标识，不是账号登录） | 复用现有 `DouyinSign.getAbogusUrl` 追加 msToken + a_bogus；bdturing 验证码拦截作为 P2 处理 |
| Twitch | IRC `PRIVMSG #channel :text`；现有接收连接为匿名 justinfan，需改为认证连接：`PASS oauth:<token>` + `NICK <自身登录名>` + `JOIN` | oauth token（现有 TwitchAccountService）；另需调一次 `helix/users` 获取自身 login | TwitchDanmakuArgs 增加 oauthToken/userLogin |

### 2.1 哔哩哔哩接口细节

- 请求：`POST https://api.live.bilibili.com/msg/send`，`application/x-www-form-urlencoded`
- 参数：`msg`（文本）、`roomid`（真实房间号，短号需经 getRoomPlayInfo 转换）、`rnd`（秒级时间戳）、`color=16777215`、`fontsize=25`、`mode=1`、`bubble=0`、`csrf`、`csrf_token`（二者值均为 cookie 中 bili_jct）
- 请求头：`Cookie`、`Referer: https://live.bilibili.com/<roomid>`（关键）、`Origin: https://live.bilibili.com`、普通 Chrome UA
- 响应：`code=0` 成功。错误码：`-101` 未登录、`-111` CSRF 失败、`-400` 参数错误、`1` 被禁言、`3` 房间锁定、`11` 频率过快、`12` 超长、`13` 房间全体禁言、`14` 仅粉丝团可发言、`15` 需绑定手机
- 频率：约 1 条/秒。官方网页端在 query 上做 wbi 签名（w_rid/wts），不带实测可用但建议后续追加防风控
- 参考：BLTH（github.com/andywang425/BLTH）

### 2.2 斗鱼协议细节

- wsproxy 列表获取：`GET https://www.douyu.com/lapi/live/gateway/web/<rid>?isH5=1`（lapi 实时下发，实测返回 5 个在线网关）
- 二进制帧（小端）：length(4) + length(4) + msgtype=689(2) + encrypted=0(1) + reserved=0(1) + STT(UTF-8) + `\0`
- STT：`key@=value/`，`@` 转义为 `@A`、`/` 转义为 `@S`
- chatmessage 字段：`type@=chatmessage/rid@=<房间>/content@=<内容>/col@=0/dy@=<设备ID>/sender@=<UID>/pe@=0/ifs@=0/nc@=0/dat@=0/rev@=0/tts@=<秒>/cst@=<毫秒随机>/admzq@=0/`
- loginreq：`type@=loginreq/roomid@=x/username@=visitor../uid@=x/ver@=20220825/aver@=218101901/ct@=0/`，另需 `vk` 及 ltkid/stk/devid
- websec 签名：调 `https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption` 取 key/rand_str/enc_time；`u=rand_str`，循环 enc_time 次 `u=MD5(u+key)`，`sign=MD5(u+key+rid+ts)`（登录/心跳场景为 rid+did+ts）
- 回执：发送成功无独立 ACK，收到自己的弹幕广播即成功；应答有 chatres、h5cs（result 字段）；禁言为 newblackres（含 sid/endtime）；错误含 errorrid
- 参考：OrdinaryRoad/ordinaryroad-barrage-fly（2026-01 仍活跃）

### 2.3 虎牙协议细节

- 外层命令：`WebSocketCommand{iCmdType(short), vData(bytes)}`；类型 1 RegisterReq、3 WupReq（发弹幕）、4 WupRsp、7 Push、10 VerifyCookieReq、11 VerifyCookieRsp
- VerifyCookie：`WSVerifyCookieReq{lUid, sUA, sCookie(整串 cookie), sGuid}`，回执 iValidate==0 为成功
- SendMessageReq 字段（tag 顺序）：0 `UserId tUserId`、1 long `lTid`、2 long `lSid`、3 string `sContent`、4 int `iShowMode=0`、5 `ContentFormat tFormat`、6 `BulletFormat tBulletFormat`、7 vector `vAtSomeone`、8 long `lPid`（主播 yyuid）
- UserId：0 long lUid、1 string sGuid、2 string sToken、3 string sHuYaUA（`webh5&<版本号>&websocket`）、4 string sCookie（`udb_uid=<yyuid>; udb_biztoken=<biztoken>`）、5 int iTokenType、6 string sDeviceInfo、7 string sQIMEI
- ContentFormat（tag 0-5）：iFontColor、iFontSize、iPopupStyle、iNickNameFontColor、iDarkFontColor、iDarkNickNameFontColor
- BulletFormat（tag 0-8）：iFontColor、iFontSize、iTextSpeed、iTransitionType、tBorderGroundFormat 等
- 回执：`SendMessageRsp{int iStatus(tag0), MessageNotice tNotice(tag1)}`；部分房间强制绑手机、约 20s 发言间隔
- 发弹幕无需 JS 逆向签名；仅账密登录需 md5（本期采用扫码登录规避）
- 参考：ligb888/huya-danmu（Node，sendMsg 完整实现）、xyxyxiaoyan/HuyaSender（Java，扫码登录）

### 2.4 抖音接口细节

- 请求：GET `https://live.douyin.com/webcast/room/chat/`
- 业务参数：`room_id`（长 ID）、`content`、`type=0`、`rtf_content`、`emoji_id`、`camera_id`、`team_id`、`paste_edit_method`
- 公共参数：`aid=6383`、`app_name=douyin_web`、`live_id=1`、`device_platform=web`、`language`、`enter_from`、`cookie_enabled`、`screen_width/height`、`browser_name/version`、`os_name/version`
- 签名：构造完整 URL 后经 `DouyinSign.getAbogusUrl(url, ua)` 追加 `msToken` 与 `a_bogus`
- Cookie：sessionid 必须；ttwid、odin_tt、passport_csrf_token、msToken 等
- 请求头：`Referer: https://live.douyin.com/<web_rid>`、UA、Cookie
- 响应：`{"status_code":x,"data":{"message","prompts"}}`；0 成功、8 未登录、9 封禁、50001 禁言、50004 敏感词、50008 发言受限、3009008 频率过快、10011 参数错误
- bdturing 验证码（响应头 `bdturing-verify`）：P2，先返回明确错误；备选方案为隐藏 WebView 中在页面 JS 环境内发送
- 接收用 PushFrame WebSocket 不承载发送，客户端只回 ack

### 2.5 Twitch 协议细节

- 连接 `wss://irc-ws.chat.twitch.tv:443`；登录态下：`CAP REQ :twitch.tv/tags twitch.tv/commands`、`PASS oauth:<token>`、`NICK <自身 login>`、`JOIN #<channel>`
- 发送：`PRIVMSG #<channel> :<text>`
- 自身 login：token 配置后调 `GET https://api.twitch.tv/helix/users`（无 query 参数，带 Authorization）取 data[0].login，缓存在 TwitchSite/TwitchAccountService
- Twitch 不会把自己的 PRIVMSG 回环，需要 needLocalEcho 本地插入

## 3. Core 层设计

### 3.1 LiveDanmaku 接口扩展

```dart
class DanmakuSendResult {
  final bool success;
  final String errorCode;
  final String errorMessage;
  final bool needLocalEcho; // Twitch=true：服务器不回环，本地插入消息
}

class LiveDanmaku {
  // 现有成员不变
  Future<DanmakuSendResult> sendMessage(String message);
}
```

### 3.2 各实现改动

- **BiliBiliDanmaku**：sendMessage 内 POST 表单；从 cookie 正则提取 bili_jct（`bili_jct=([^;]+)`）；roomId 取 args.roomId
- **DouyuDanmaku**：args 增加 cookie/登录字段；start 时若已登录，内部另建 wsproxy WebSocket（lapi 取列表），完成 websec loginreq；sendMessage 走该连接；未登录返回未登录错误。接收连接逻辑保持不变
- **HuyaDanmaku**：连接 onReady 后，已登录则先 VerifyCookie 再视为就绪；新增 tars model：`huya_send_message_req.dart`（含 UserId/ContentFormat/BulletFormat），按 2.3 tag 编号；sendMessage 编码 WupReq
- **DouyinDanmaku**：sendMessage 拼 GET URL → getAbogusUrl 签名 → HttpClient 发起请求 → 解析 status_code
- **TwitchDanmaku**：args 增加 oauthToken、userLogin；有 token 时用认证序列（PASS/NICK）；sendMessage 发 PRIVMSG，返回 needLocalEcho=true

### 3.3 Site 改动

- DouyuSite：新增 `cookie` 字段；getRoomDetail 构造 danmakuData 时带入
- HuyaSite：新增 `cookie` 字段，danmakuData 增加登录信息（现有 HuyaDanmakuArgs 已含 topSid/subSid/ayyuid）
- TwitchSite：新增 `userLogin` 字段（token 存在时惰性获取），TwitchDanmakuArgs 增加 oauthToken/userLogin
- BiliBiliSite/DouyinSite：cookie/userId 现有字段已满足

## 4. App 层设计

### 4.1 新增账号服务

- **DouyuAccountService**（GetxService，仿 BiliBiliAccountService）：
  - WebView 登录页打开 `https://www.douyu.com`，登录成功提取完整 cookie；校验 `acf_uid`、`acf_stk` 存在
  - LocalStorageService 新增 `kDouyuCookie`；同步 DouyuSite.cookie
- **HuyaAccountService**：
  - 优先扫码登录（请求虎牙扫码登录接口 + 轮询），取得含 udb_uid/udb_biztoken 的 cookie
  - 扫码接口失效时降级 WebView 登录 `https://www.huya.com`
  - LocalStorageService 新增 `kHuyaCookie`；同步 HuyaSite.cookie
- **DouyinAccountService 改造**：
  - 现状仅支持手工配置 ttwid（设备标识，用于接收弹幕）；新增 WebView 登录 `https://live.douyin.com`，登录成功提取完整 cookie（校验 `sessionid` 存在）
  - 设备 ttwid 配置与账号登录两套凭证合并为一份完整 cookie 发送；LocalStorageService 新增 `kDouyinLoginCookie`（或复用现有 kDouyinCookie 存完整串）
  - 账号页抖音项增加登录态展示与退出登录（退出后保留/清空 ttwid 二选一，默认退回 ttwid 模式）
- 新增/改造的服务均在 main.dart 注册（跟随现有 account service 注册位置）

### 4.2 账号管理页

`account_page.dart`：斗鱼、虎牙两项由「无需登录/禁用」改为正常可点（已登录显示用户名 + 退出图标）；抖音项在现有 ttwid 配置之外增加账号登录状态与登录/退出入口；顶部说明文字更新为「登录后可在直播间发送弹幕、观看高清晰度直播」。

### 4.3 UI 入口

- **底部输入栏**：竖屏房间页 `buildBottomActions` 上方新增一行：「说点什么…」输入框（TextField，圆角边框）+ 发送按钮；平板布局同步处理
  - 未登录点击：toast/确认对话框 → 跳账号管理
  - 发送中：按钮 loading；成功清空输入；失败 toast 平台返回的错误文案
- **全屏控制栏**：player_controls.dart 全屏按钮组（弹幕开关按钮附近）新增弹幕图标，点击弹居中输入对话框（TextField + 发送），复用同一发送方法
- **LiveRoomController.sendDanmaku(String text)**：trim 与空值/长度校验 → `liveDanmaku.sendMessage()` → needLocalEcho 时向消息列表插入 LiveMessage（chat 类型，当前平台用户名）

### 4.4 错误文案映射

App 层将 errorCode 映射为中文文案：未登录 → 引导登录；禁言/封禁 → 「你已被禁言」；频率 → 「发言太快，请稍后再试」；敏感词 → 「内容包含敏感词」；抖音验证码 → 「需要完成验证码，请稍后重试」（P2 再提供 WebView 发送入口）。

弹幕长度：输入框 maxLength，B站按 20 字（无特殊权限），其余按平台通用上限。

## 5. 测试策略

- Core 单元测试（无网络）：bili_jct 提取、斗鱼 websec 循环 MD5 签名（构造 key/rand_str/enc_time 向量）、STT 转义、虎牙 SendMessageReq tars 编码字节断言
- Core 网络测试：沿用现有真实网络测试风格，各平台 sendMessage 测试通过本地环境变量提供测试 cookie，无凭证时自动 skip
- App 测试：sendDanmaku 的未登录拦截、空消息、成功/失败 mock、needLocal 本地插入
- 手工验证：Android 真机逐平台 登录 → 进入房间 → 发一条弹幕 → 确认回环/本地显示；全屏弹框发送；错误场景（未登录、高频）

## 6. 实施顺序

1. Core：DanmakuSendResult + 接口 + BiliBiliDanmaku（端到端链路跑通）
2. Twitch 认证连接 + sendMessage
3. 抖音：DouyinAccountService WebView 登录改造 + room/chat + 签名
4. 斗鱼：DouyuAccountService（WebView 登录）+ wsproxy 连接 + websec 签名 + chatmessage
5. 虎牙：HuyaAccountService（扫码登录）+ VerifyCookie + SendMessageReq tars
6. App：底部输入栏 + 全屏弹框 + 错误映射 + 账号页接入
7. 测试与真机验证

## 7. 风险

- 斗鱼 websec 签名为现行线上方案，但字段可能随版本调整，需以实测为准；参考实现 ordinaryroad-barrage-fly
- 虎牙 SendMessageReq 结构以抓包为准，房间策略（绑手机/等级/20s 间隔）可能阻止发言
- 抖音 a_bogus 已内置在项目 quickjs 脚本中，若线上版本升级导致签名失效，发送会被风控拦截；备选隐藏 WebView 桥接发送（P2）
- B站不带 wbi 签名时高频/多账号可能吞弹幕甚至封 SESSDATA，客户端保持 1 条/秒以下
