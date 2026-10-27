# Discord Go Live 接入 SimpleLive 设计方案

日期：2026-10-27
状态：已评审（4 节设计逐节确认，用户授权按最优方案直接实施）

## 1. 背景与目标

SimpleLive 现有站点（B站/斗鱼/虎牙/抖音/Twitch）全部提供公开可直链播放的 HTTP(S) HLS/FLV
流。Discord 的「直播 / Go Live」形态完全不同：它是语音频道内的私有 WebRTC 语音栈，没有公开
播放 URL，官方 Bot API 不允许订阅屏幕分享，唯一被社区验证的接收路径是 selfbot（用户 token
模拟客户端）加语音频道、订阅流、解密 RTP。

目标：在用户经常观看的 Discord 服务器语音频道
`https://discord.com/channels/979365387705647124/979365387705647129` 上实现：

1. App 内观看 Go Live（H264/H265 视频 + Opus 音频），延迟 1–3 秒；
2. 该语音频道聊天消息的接收与发送（Discord 2022 年后语音频道自带文字聊天，直播观众面板的
   发言即落在该 GUILD_VOICE 频道上，REST 收发不需要进入语音频道）；
3. 局域网与 frp 外网均可使用；
4. 可关注、可看开播状态；复用播放页、多标签、历史、WebDAV 同步，不新增播放页面。

非目标（YAGNI）：

- 不做 Discord 公开分类/推荐/搜索（不存在公开目录）；
- 不做多服务器/多账号管理、不做私聊（@me）通话；
- 弹幕只做纯文本（emoji 短码由 Discord 渲染），不做回复/@/附件/贴纸/历史消息；
- 不做多码率切换、不做录制落盘；
- 不接入 TV App 与 console；
- 不向上游提交（selfbot 违背上游 AGENTS.md「基于公开信息、无逆向」原则，仅个人 fork）。

## 2. 已确认的关键决策

| 决策点 | 结论 |
|---|---|
| 中继技术栈/部署 | Node 22 + selfbot fork + werift-rtp + ffmpeg，NAS(192.168.31.140) Docker |
| 客户端范围 | 仅主 App（simple_live_app，手机 + Windows 桌面） |
| 账号 | 主号用户 token（风险已知，配置上保证一处可换小号） |
| 进出策略 | 网关连接常驻；仅播放期间加入语音频道，最后观众离开 30s 后退出 |
| 外网 | 走现有 frps 裸 TCP + 随机高端口 + URL key，不用明文 HTTP 域名 |
| 弹幕 | 必须支持收发；弹幕 WS 与语音流解耦，不进语音房即可收发 |
| 多观众 | ffmpeg 单实例，TS chunk 在中继内 fan-out（多标签/多端同看） |
| 输出格式 | 单连接实时 MPEG-TS over HTTP chunked（非 HLS，无磁盘切片） |

## 3. 总体架构

```
SimpleLive 主 App                              NAS 192.168.31.140 (Docker)
┌──────────────────────────┐                 ┌─────────────────────────────┐
│ DiscordSite (core)       │   HTTP + WS     │ discord-live-relay (Node22) │
│  粘贴链接→关注/播放       │  Bearer/querykey│  Fastify: REST + WS + fanout│
│  media_kit ◀── MPEG-TS ──┼◀───────────────▶│   仅播放时:                  │
│  DiscordDanmaku ◀ WS ────┼──── WS ────────▶│   selfbot 网关常驻(不进房)   │
└──────────────────────────┘                 │   op4进房→op20订阅 Go Live  │
                                             │   UDP加密RTP→解密/depay      │
        外网: frpc(小米3.10) TCP 出站         │   →本地UDP→ffmpeg→TS stdout │
        frps 112.126.78.147:47920 ◀──────────┴─────────────────────────────┘
```

两级「在场」模型：

- **网关常驻**：selfbot 客户端登录保持，账号在线但不在任何语音频道，他人不可见观看行为；
- **按需进房**：首个播放请求触发 op4 加入语音频道并订阅 Go Live；最后一个播放连接断开
  30 秒宽限后 op19 退订、op4 离开。宽限内重开免重进。
- **弹幕独立**：聊天走网关消息事件 + REST，整个生命周期不加入语音频道。

协议层（裸 op4/op19/op20、stream voice WS、UDP 解密）全部隔离在中继 `src/discord/`，
HTTP/WS 层不感知协议；上游 selfbot fork 失效时只改这一模块，App 不需要重新发版。

## 4. 中继详细设计（discord-live-relay）

独立 Node 仓库（GitHub 私库 `my57575757/discord-live-relay`），镜像
`192.168.31.140:6006/discord-live-relay:latest`。

### 4.1 技术选型与参考实现

- selfbot 库：`discord.js-selfbot-youtsuho-v13`（主库 `discord.js-selfbot-v13` 已于
  2025-10 归档，该 fork 2026-09 仍活跃）；
- RTP：`werift-rtp`（RtpPacket 反序列化）；
- 解密：AES256-GCM 用 Node 内置 `crypto.subtle`；XChaCha20-Poly1305 用 `sodium-plus`；
- 转封装：ffmpeg 子进程；
- HTTP/WS：Fastify + `@fastify/websocket`；
- 参考实现：`AugusDogus/discord.mov`（index.ts + src/stream-receiver.ts，2026-02 可用），
  其裸网关信令与接收链路已逐行核对，本设计在其上做三处改造：
  输出文件 mkv → stdout MPEG-TS；写死 H265 → 动态 codec 探测；无重连 → 会话级重连。
- 关于库补丁：discord.mov 携带的 patch 修的是库自带 VoiceConnection（endpoint 端口剥离、
  op12 streams SSRC 映射）。本方案不使用库的语音连接类、信令全部自写，**不打该补丁**，
  其 SSRC 映射逻辑仅作参考。

### 4.2 HTTP / WS API

基址 `http://<relay>:8790`，所有 `/api` 与流、WS 端点需鉴权：`Authorization: Bearer <KEY>`
或 `?key=<KEY>`（播放 URL 优先用 LivePlayUrl.headers 传 Authorization，media_kit 不支持
时退化为 query key）。

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/healthz` | 无需鉴权；返回 `{loggedIn, accountName, userId, gatewayPing, lastGatewayReconnect}` |
| GET | `/api/v1/channels/:guild/:channel` | 房间状态（不进房）：`{streaming, streamer:{id,name,avatar}, channelName, chatChannelId}` |
| GET | `/api/v1/channels/:guild/:channel/stream` | `video/mp2t` chunked，播放端点；多连接 fan-out |
| WS | `/api/v1/channels/:guild/:channel/danmaku` | 弹幕长连（不进语音房） |

弹幕 WS 协议（JSON 文本帧）：

- 服务端→客户端：
  - `{"type":"chat","id","userName","nickname","avatar","content","createdAt","self":false}`
    （nickname 优先取服务器成员昵称，无则用户名）
  - `{"type":"presence","streaming":bool,"streamer":{...}|null}`（语音状态变化时推送，
    含进房即推一次当前态）
  - `{"type":"send_ok","clientMsgId"}` / `{"type":"error","code","message","clientMsgId"}`
- 客户端→服务端：仅 `{"type":"send","content":"...","clientMsgId":"..."}`
- 自己发送的消息靠网关事件 author.id 过滤不回声；App 以 send_ok 确认本地乐观上屏。
- 限流：≥800ms/条、20 条/分钟，超限 error code `rate_limited`；
  无发送权限 Discord REST 返回 403 → error code `forbidden`；其他失败 `send_failed`。

错误响应统一 JSON：`{"error":"<code>","message":"..."}`，主要 code：
`unauthorized`(401)、`not_streaming`(503, 30s 内未出流)、`session_failed`(502)、
`relay_not_logged_in`(503)、`codec_unsupported`(501)、`bad_channel`(400)。

### 4.3 流会话状态机

每个 `(guild, channel)` 一个 Session；Session 内单条 ffmpeg 管道 + 订阅者集合。

```
IDLE
  │ 首个 GET /stream
  ▼
JOINING   裸网关 op4 {guild_id, channel_id, self_mute:true, self_deaf:false, self_video:false}
  │       等自己 VOICE_STATE_UPDATE 拿 session_id（15s 超时）
  ├─ voiceState.streaming=true ─────────────┐
  ▼                                         │
WAITING_STREAM （监听 voiceStateUpdate）     │
  │ 主播开播                                │
  ▼                                         │
SUBSCRIBING ◀───────────────────────────────┘
  │ op20 {stream_key: `guild:${guild}:${channel}:${streamerUserId}`}
  │ 集齐 STREAM_CREATE(rtc_server_id) + STREAM_SERVER_UPDATE(token,endpoint)
  │ + session_id（15s 超时 → not_streaming）
  ▼
CONNECTED
  │ stream voice WS: wss://<endpoint>/?v=8
  │ IDENTIFY {server_id,user_id,session_id,token,video:true,streams:[{type:video,rid:100,quality:100}]}
  │ ← HELLO → 周期 HEARTBEAT {t, seq_ack}
  │ ← READY {ssrc, ip, port, modes}
  │ UDP IP discovery（74B 请求，SSRC=ourAudioSsrc）→ 本地 IP/port
  │ SELECT_PROTOCOL {protocol:udp, codecs:全量表, data:{address,port,
  │   mode: 优先 aead_aes256_gcm_rtpsize，退化 aead_xchacha20_poly1305_rtpsize}}
  │ ← SELECT_PROTOCOL_ACK {secret_key, mode} → 建解密器
  │ op12 VIDEO {audio_ssrc:ourSsrc, video_ssrc:0, rtx_ssrc:0, streams:[]}
  │ ← op12（对端）{video_ssrc, audio_ssrc, streams:[{ssrc,rtx_ssrc}]} → 记录三路 SSRC
  │ MEDIA_SINK_WANTS {[ssrc]:100, any:100}
  │ 起 ffmpeg：解密 RTP → 本地 UDP×2 → ffmpeg SDP 输入 → stdout MPEG-TS
  ▼
RUNNING（TS chunk fan-out 给所有播放连接）
  │ 最后订阅者断开 → 30s 宽限（有新订阅则取消）
  ▼
TEARDOWN  draining 1s（flush jitter buffer）→ ffmpeg SIGTERM
          op19 退订 → op4 {channel_id:null} 离开 → 回 IDLE
```

第二个及以后的播放连接：Session 处于 JOINING/WAITING/SUBSCRIBING 时挂起等同一个就绪 promise；
RUNNING 时立即加入订阅者集合（直接挂流即可，ffmpeg 周期性关键帧，mpv 首帧等待同 HLS 行为）。

### 4.4 RTP 解密与转发（已核实的协议细节）

- 语音 op 表：0 IDENTIFY / 1 SELECT_PROTOCOL / 2 READY / 3 HEARTBEAT / 4 SELECT_PROTOCOL_ACK
  / 5 SPEAKING / 6 HEARTBEAT_ACK / 7 RESUME / 8 HELLO / 9 RESUMED / 11 CLIENTS_CONNECT /
  12 VIDEO / 13 CLIENT_DISCONNECT / 14 SESSION_UPDATE / 15 MEDIA_SINK_WANTS。
- codecs 协商表（payload type）：opus/120；H264 101(rtx 102)；H265 103(rtx 104)；
  VP8 105(rtx 106)；VP9 107(rtx 108)；AV1 109(rtx 110)。SIMULCAST 声明
  `[{type:"video",rid:"100",quality:100}]`。
- 外 UDP 包：末 4 字节为 nonce；AES256 时 12B nonce 左填 0，XChaCha20 时 24B；
  AAD = RTP 固定头(12+4×CSRC)+扩展头存在时 4B；密文解密后与 AAD 拼回完整 RTP，
  用 werift-rtp 反序列化，清除 extension 后重新序列化再喂 ffmpeg。
- 三路 SSRC：对端视频 SSRC、音频 SSRC、RTX SSRC。RTX 包剥前 2 字节（OSN）、把 SSRC/PT
  改写为视频主路后注入。
- H265 坑：Discord 的 HEVC NAL 头 nuh_layer_id=8、tid=0，ffmpeg 报 Multi-layer HEVC，
  必须改写成 layer_id=0、temporal_id_plus1=1（含 AP 聚合包内每个 NAL）。
- ffmpeg 输入：本地两 UDP 端口（避开 RTP/RTCP 端口对撞），SDP 经 stdin 给
  `-f sdp -i -`，参数 `-reorder_queue_size 500 -max_delay 500000 -err_detect ignore_err
  -fflags +genpts+discardcorrupt -analyzeduration 1M -probesize 1M`；
  等 ffmpeg stderr 首输出现后再开始转发，之前的包丢弃（自然等下一个关键帧）。

### 4.5 Codec 策略

op12 只给 SSRC 不给编码，SDP 必须先生成：

1. 首包前按 H264 起 ffmpeg（桌面客户端默认编码）；
2. 用解密后 RTP payload type 探测：101 H264 保持；103 H265 热重启 ffmpeg 换 SDP 一次
   （首个 GOP 内，用户基本无感），并启用 HEVC NAL 头改写；
3. 105 VP8/107 VP9：ffmpeg 转码分支（解码转 H264，TS 内统一 H264+Opus）；
4. 109 AV1：当前不硬撑，会话以 HTTP 501 `codec_unsupported` 失败并在日志记录（Debian
   bookworm ffmpeg 对 AV1 RTP depay 支持不稳定），等待实际遇到再评估；
5. 输出统一 `mpegts`：H264/H265/Opus 直接 `-c copy`；转码时
   `-c:v libx264 -preset veryfast -c:a copy`，`-flush_packets 1` 保证实时下发。

### 4.6 fan-out

- ffmpeg stdout 由单一 reader 按 chunk 轮播给订阅者响应流；每订阅者有界队列（高水位
  8MB），慢消费者掉队只断开该连接，不影响其他订阅者和 ffmpeg；
- 订阅者计数归零时启动 30s 离开定时器；新订阅取消定时器；
- 单 Session 同一把锁保证 JOINING/SUBSCRIBING 不重入。

### 4.7 容错与重连

| 故障 | 行为 |
|---|---|
| stream voice WS 关闭 4015 或 code<4000 | 1s 后重连 stream WS（IDENTIFY/SELECT_PROTOCOL 全流程），ffmpeg 不动，播放器卡顿 1–3s 不断流 |
| op4 语音会话失效（4006 等） | Session 整体销毁回 IDLE 重建，最多 3 轮指数退避 1/2/4s；仍失败 → 播放连接 502 session_failed |
| 主网关断线 | selfbot 库自动重连；READY 后对所有活跃 Session 补发 op4 |
| 主播停播（self_stream=false / STREAM_DELETE） | 播放流立即 EOF（与其他站点「直播结束」一致）；弹幕 WS 收 presence 推送；Session 回 WAITING_STREAM，30s 宽限后离房 |
| token 失效（网关 4004） | 全局 logged_out：/healthz 反映；一切会话拒绝 `relay_not_logged_in` |
| ffmpeg 崩溃 / UDP 20s 无包 | Session 销毁，播放连接 502；弹幕 WS 不断 |
| 进房/订阅 30s 未出流 | 播放连接 503 not_streaming |

### 4.8 配置

环境变量（env file，NAS 上 0600，不进 git、不进 App）：

- `DISCORD_TOKEN`（必填，用户 token）
- `RELAY_KEY`（必填，32 字节随机，hex/base64url）
- `PORT=8790`
- `LOG_LEVEL=info`（默认不落消息内容，只记会话状态与 SSRC/编码）

无状态、不挂数据卷。

## 5. core 层设计（simple_live_core）

新增：

- `lib/src/discord/discord_site.dart`：`DiscordSite extends LiveSite`
- `lib/src/discord/discord_danmaku.dart`：`DiscordDanmaku extends LiveDanmaku`
- `lib/src/discord/discord_config.dart`：relayBase/key 持有与 URL 拼装、链接解析
- 在 simple_live_core.dart 导出
- `test/discord/`：纯单测（不打真实网络）

`DiscordSite({required String relayBase, required String key})`：

| LiveSite 成员 | 实现 |
|---|---|
| id/name | `discord` / `Discord` |
| roomId | `"$guildId/$channelId"` |
| 链接解析（静态方法） | 接受 `https://discord.com/channels/<g>/<c>`、`discord://`、裸 `g/c`；拒绝 @me、非数字；中继状态端点做最终校验 |
| getRoomDetail | GET channel 状态 → LiveRoomDetail（title=频道名，userName=开播者昵称/频道名，status=streaming，userAvatar=开播者头像，url=原始 discord 链接，data=`{g,c,chatChannelId}`，danmakuData=WS URL 与鉴权） |
| getPlayQualites | 固定一条「原画」 |
| getPlayUrls | `[relayBase]/api/v1/channels/g/c/stream`，headers 带 `Authorization: Bearer key`（LivePlayUrl.headers 已支持） |
| getLiveStatus | channel 状态端点 streaming 字段；关注轮询专用，不进语音房 |
| getDanmaku | 返回 DiscordDanmaku，参数由 detail.danmakuData 透传 |
| 分类/推荐/搜索/锚点/SC | 默认空实现 |

`DiscordDanmaku`：

- `start(args)`：args 为 `{wsUrl}`（鉴权编码在 URL 或子协议头），用
  `web_socket_channel` 连接（core 已用纯 Dart 包优先，实施时确认 pubspec）；
  断线指数退避重连；
- chat → `LiveMessage(type: chat, userName: nickname, message: content, isSelf: self)`；
- presence → `DiscordDanmaku.onPresence` 专用回调（不污染 LiveMessage 通用模型）；
- `sendMessage`：发 `{type:send,clientMsgId,content}`，以 clientMsgId 等 send_ok/error
  完成 Future，映射 DanmakuSendResult：forbidden / rate_limited / network_error / 成功；
- `stop()`：关 WS。

单测：WS JSON 报文→LiveMessage 映射、发送结果码映射、链接解析各形态与非法输入、URL 拼装
与鉴权头。WS 用本地 `HttpServer` 脚本化报文做假服务。

## 6. App 层设计（simple_live_app）

1. `Constant.kDiscord = "discord"`；`app/sites.dart` 注册站点（logo
   `assets/images/discord.png`），site 实例由设置值构造，设置变化时重建（参照
   TwitchAccountService.setSite 注入模式）。
2. 设置：新增「Discord 直播」分区
   - 中继内网地址（默认 `http://192.168.31.140:8790`）、外网地址（
     `http://112.126.78.147:47920`）、RELAY_KEY；
   - 「测试连接」调 /healthz：显示登录账号名、网关 ping；logged_out 红字提示改 NAS 环境变量；
   - 内外网自动选择：App 启动与网络切换事件时并发 GET 两地址 /healthz（1.5s 超时），
     先通者缓存；都不通保留上次选择。持久化用 LocalStorageService。
3. 添加频道：Discord 站点页（分类/推荐为空）显示空状态卡片「添加 Discord 频道」→ 弹窗粘贴
   链接 → core 解析 → getRoomDetail 验证 → 写入关注（FollowService 现有链路）。之后从关注
   列表进入，复用房间页/多标签/历史/同步。
4. 关注轮询：现有 follow_service 对 discord 站点走 getLiveStatus（中继网关缓存，不进房）。
5. 弹幕：播放页发送链路站点无关，零 UI 改动；补 `forbidden`（提示无发言权限）、
   `rate_limited`（发言过快）文案到 danmakuErrorText。
6. 未开播点播放：房间页对 discord 站点先看 detail.status，未开播给「未开播」提示并保持弹幕
   WS 在线；主播开播 presence 推送仅弹「已开播，点击播放」提示，不自动拉流。
7. 中继未配置：站点空态提示去设置；不发请求。
8. TV / console 不注册。

## 7. 部署

### 7.1 NAS

目录 `/volume1/Packages/discord-relay/`：

- `relay.env`（0600）：`DISCORD_TOKEN=...`、`RELAY_KEY=...`
- compose：端口仅绑局域网 `192.168.31.140:8790:8790`，`restart: unless-stopped`
- 镜像：Dockerfile `node:22-slim`（经 NAS registry-mirror:6007 缓存）+ apt ffmpeg
  （bookworm 版含 libx264/libvpx），非 root 用户；构建后 push
  `192.168.31.140:6006/discord-live-relay:latest`。

### 7.2 frp

小米 3.10 frpc 增加：

```toml
[[proxies]]
name = "discord-relay"
type = "tcp"
localIP = "192.168.31.140"
localPort = 8790
remotePort = 47920
```

阿里云安全组放行 47920/TCP。外网基址 `http://112.126.78.147:47920`。

### 7.3 Token 获取手册（写入中继 README）

1. Chrome 登录 Discord → F12 → Network → 任一 API 请求的 `authorization` 请求头；
2. 写入 relay.env 重启容器；不落地 git/App；
3. 失效场景：改密码、异地验证、条款确认；表现 healthz logged_out / 网关 4004；重新取值；
4. 换小号只改 env 文件一处。

## 8. 安全与封号风险

- selfbot 违反 Discord ToS，主号有被封风险（用户已知并选择主号，保留一处换小号能力）。
- 缓解：网关行为最小化（只收必要事件、不刷接口、不拉成员列表）；手动发言 + 强制节流；
  仅播放期间进语音房；出口为家庭宽带 IP，与日常客户端同源，不挂代理；日志不落消息内容。
- 公网链路为明文 HTTP，RELAY_KEY 出现在 URL（具备播放+发言权限）：可随时轮换；在家自动
  内网直连；不与其他服务复用。后续加密优先非标端口 HTTPS（固定证书），
  不使用明文 HTTP 域名（已有阿里云备案抽查 403 教训）。

## 9. 测试策略

- relay（node test runner）：key 鉴权、限流、fan-out 队列与慢消费者剔除、会话状态迁移
  （事件源假实现）、WS 协议编解码、codec PT 探测决策。信令层 `src/discord/` 不 mock
  Discord，靠手动联调验收。
- core（dart test）：见 §5。
- 手动联调验收顺序：
  1. 中继本机 `curl -H "Authorization: Bearer …" …/stream` → VLC/ffplay 播放目标房间；
  2. wscat 弹幕收发（Discord 客户端对照可见）；
  3. Docker 部署 + frp 外网重复 1、2；
  4. App 内网播放/弹幕/关注状态/多标签双开；
  5. App 外网（流量）播放与发言。

## 10. 里程碑

| | 内容 | 验收 |
|---|---|---|
| M1 | 中继骨架：网关登录、裸 op4/op20 信令、stream receiver（解密/depay/H265 修正）、ffmpeg→TS、单频道 Session + fan-out 结构 | 本机 VLC 播放目标房间（H264/H265 各验证到一次） |
| M2 | 弹幕 WS 收发/限流/self 过滤、/healthz、channel 状态端点、presence 推送 | wscat 联调通过 |
| M3 | Dockerfile + compose + 私有仓库 push + frpc 配置 + README | 外网 VLC/wscat 全链路 |
| M4 | core DiscordSite/DiscordDanmaku + dart test | 单测全绿 |
| M5 | App 注册/设置页/内外网探测/添加频道/文案/多标签 | §9 全部手动验收；自有渠道发版 |

依赖与阻塞：M1/M2 联调需要用户提供主号 token；M3 需要用户放行阿里云安全组 47920；
M5 发版走 live-cover-release skill，push 需用户授权。

## 11. 实施期需现场确认的开放项

1. selfbot fork 在 Node 22 下的实际可用性：M1 第一步先跑「登录 + 收到目标频道
   VOICE_STATE_UPDATE」最小脚本，作为继续投入的闸门；
2. 目标房间主播实际编码（H264/H265）与开播时段，决定 codec 热重启路径能否当场验收到；
3. media_kit 对 chunked `video/mp2t` + Authorization 头的接受度，不通则退化为 query key。
