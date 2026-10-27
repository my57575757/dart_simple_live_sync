# Discord 直播中继（discord-live-relay）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新建独立 Node 服务 `discord-live-relay`：selfbot 登录 Discord，按需订阅指定服务器语音频道的 Go Live，把解密后的 RTP 用 ffmpeg 转成实时 MPEG-TS 经 HTTP 分发，并提供弹幕 WS（收发）与房间状态/健康检查 API；Docker 化部署到 NAS 并经 frp 暴露。

**Architecture:** Fastify HTTP/WS 层 + 每频道一个 StreamSession 状态机（IDLE→JOINING→WAITING_STREAM→SUBSCRIBING→RUNNING→TEARDOWN）+ 单 ffmpeg 实例 TS chunk fan-out 多订阅者；Discord 信令（裸网关 op4/op19/op20、stream voice WS v8、UDP 加密 RTP）隔离在 `src/discord/` 与 `src/stream/`；弹幕走普通消息通道，不进语音房。

**Tech Stack:** Node 22 + TypeScript 5（tsx 运行、node:test 单测）、`discord.js-selfbot-youtsuho-v13`（主参考库 aiko 版已归档）、`werift-rtp`、`sodium-plus`、`fastify`+`@fastify/websocket`、ffmpeg 子进程、Docker(node:22-slim + apt ffmpeg)。

**Spec:** `dart_simple_live/docs/10_ai_workflows/superpowers/specs/2026-10-27-discord-live-relay-design.md`（实施前通读 §4）

**参考实现（已下载核对，勿执行，只读/摘录）：** `D:/project/.discord-ref-tmp/stream-receiver.ts`（AugusDogus/discord.mov，763 行，裸信令+解密+ffmpeg 全链路已验证可用）。

## Global Constraints

- 仓库新建于 `D:/project/discord-live-relay/`，独立 git 仓库；最终 GitHub 私库 `my57575757/discord-live-relay`（push 需用户授权）。
- Node 22+；ESM（`"type":"module"`）；TypeScript strict。
- 环境变量：`DISCORD_TOKEN`（必填）、`RELAY_KEY`（必填，≥32 字符）、`PORT=8790`、`LOG_LEVEL=info`。
- 所有 `/api/**`、`/stream`、弹幕 WS 必须鉴权（`Authorization: Bearer <KEY>` 或 `?key=`），仅 `/healthz` 免鉴权；失败统一 `{"error":"<code>","message":"..."}`。
- 弹幕限流：≥800ms/条 且 20 条/分钟/连接；错误码 `rate_limited` / `forbidden` / `send_failed`。
- 日志不落消息内容，只记会话状态、SSRC、编码、错误。
- 流会话：最后订阅者断开 30s 后才 op19/op4 离房；语音 WS 断线（4015 或 <4000）1s 重连且不动 ffmpeg；30s 未出流 → 503 `not_streaming`。
- ffmpeg 输出 stdout `mpegts`；H264/H265/Opus `-c copy`；VP8/VP9 转 libx264；AV1 → 501 `codec_unsupported`；H265 必须做 NAL 头改写。
- 提交粒度：每个 Task 一次 commit（仓库初始化后）；commit message 末尾加 `Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>`。
- TDD：除「真实 Discord 信令/ffmpeg 进程」外全部先写失败测试；真实链路在 Task 8/9 手动联调（闸门，需用户 token）。

---

### Task 1: 仓库脚手架与配置加载

**Files:**
- Create: `D:/project/discord-live-relay/package.json`
- Create: `D:/project/discord-live-relay/tsconfig.json`
- Create: `D:/project/discord-live-relay/.gitignore`
- Create: `D:/project/discord-live-relay/src/config.ts`
- Create: `D:/project/discord-live-relay/src/logger.ts`
- Test: `D:/project/discord-live-relay/test/config.test.ts`

**Interfaces:**
- Produces: `loadConfig(env: NodeJS.ProcessEnv): Config`，`Config = { token:string; key:string; port:number; logLevel:'debug'|'info'|'warn'|'error' }`；`createLogger(level)` 返回 `{debug,info,warn,error}`（console 包装，JSON 行）。

- [ ] **Step 1: 环境检查与建仓**

```bash
node -v   # 必须 >= v22，低于则用 nvm-windows 切 22
mkdir -p /d/project/discord-live-relay && cd /d/project/discord-live-relay && git init
```

- [ ] **Step 2: 确认 selfbot fork 的 npm 包名与可用性**

```bash
npm view discord.js-selfbot-youtsuho-v13 version
```

有输出版本号即直接用；若 404，执行 `npm view` 查其 README 指向的包名（`npm view discord.js-selfbot-youtsuho-v13 readme` 前 20 行找 install 命令）；仍无则在 package.json 用 github 依赖 `"discord.js-selfbot-v13": "github:youtsuhodev/discord.js-selfbot-youtsuho-v13"`。记录实际选择到本 Task 提交说明。

- [ ] **Step 3: 写失败测试 `test/config.test.ts`**

```typescript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loadConfig } from '../src/config.ts';

const base = { DISCORD_TOKEN: 'tok', RELAY_KEY: 'x'.repeat(32), PORT: '8790', LOG_LEVEL: 'info' };

test('loadConfig parses valid env', () => {
  const c = loadConfig({ ...base });
  assert.equal(c.token, 'tok');
  assert.equal(c.port, 8790);
});

test('loadConfig rejects missing token', () => {
  assert.throws(() => loadConfig({ ...base, DISCORD_TOKEN: '' }), /DISCORD_TOKEN/);
});

test('loadConfig rejects short key', () => {
  assert.throws(() => loadConfig({ ...base, RELAY_KEY: 'short' }), /RELAY_KEY/);
});

test('loadConfig applies defaults', () => {
  const c = loadConfig({ DISCORD_TOKEN: 't', RELAY_KEY: 'y'.repeat(32) });
  assert.equal(c.port, 8790);
  assert.equal(c.logLevel, 'info');
});

test('loadConfig rejects bad log level', () => {
  assert.throws(() => loadConfig({ ...base, LOG_LEVEL: 'trace' }), /LOG_LEVEL/);
});
```

- [ ] **Step 4: 跑测试确认失败**

```bash
npm i -D typescript tsx @types/node
node --import tsx --test test/config.test.ts
```
Expected: FAIL（模块不存在）

- [ ] **Step 5: 写 `src/config.ts`**

```typescript
export type LogLevel = 'debug' | 'info' | 'warn' | 'error';
export interface Config { token: string; key: string; port: number; logLevel: LogLevel }

export function loadConfig(env: NodeJS.ProcessEnv): Config {
  const token = env.DISCORD_TOKEN?.trim() ?? '';
  if (!token) throw new Error('DISCORD_TOKEN is required');
  const key = env.RELAY_KEY?.trim() ?? '';
  if (key.length < 32) throw new Error('RELAY_KEY is required and must be >=32 chars');
  const port = Number(env.PORT ?? '8790');
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT invalid');
  const logLevel = (env.LOG_LEVEL ?? 'info') as LogLevel;
  if (!['debug', 'info', 'warn', 'error'].includes(logLevel)) throw new Error('LOG_LEVEL invalid');
  return { token, key, port, logLevel };
}
```

`src/logger.ts`：

```typescript
import type { LogLevel } from './config.ts';
export type Logger = Record<LogLevel, (msg: string, meta?: Record<string, unknown>) => void>;
export function createLogger(level: LogLevel): Logger {
  const order: LogLevel[] = ['debug', 'info', 'warn', 'error'];
  const min = order.indexOf(level);
  return Object.fromEntries(
    order.map((lvl) => [
      lvl,
      (msg: string, meta?: Record<string, unknown>) => {
        if (order.indexOf(lvl) < min) return;
        const line = JSON.stringify({ ts: new Date().toISOString(), level: lvl, msg, ...meta });
        (lvl === 'error' ? console.error : console.log)(line);
      },
    ]),
  ) as Logger;
}
```

- [ ] **Step 6: package.json / tsconfig / .gitignore**

package.json（Step 2 确定 selfbot 包名后替换；其余照写）：

```json
{
  "name": "discord-live-relay",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=22" },
  "scripts": {
    "start": "node --import tsx src/server.ts",
    "test": "node --import tsx --test test/*.test.ts",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@fastify/websocket": "^11.0.0",
    "discord.js-selfbot-youtsuho-v13": "*",
    "fastify": "^5.0.0",
    "sodium-plus": "^0.9.0",
    "werift-rtp": "^0.8.8",
    "ws": "^8.19.0"
  },
  "devDependencies": { "@types/node": "^22", "@types/ws": "^8", "tsx": "^4", "typescript": "^5" }
}
```

tsconfig：`{"compilerOptions":{"target":"ES2023","module":"NodeNext","moduleResolution":"NodeNext","strict":true,"noUncheckedIndexedAccess":true,"skipLibCheck":true,"types":["node"],"noEmit":true},"include":["src","test"]}`

.gitignore：`node_modules/\n.env\nrelay.env\n*.log\n`

- [ ] **Step 7: 安装并跑测试/类型检查**

```bash
npm install
node --import tsx --test test/config.test.ts
npx tsc --noEmit
```
Expected: 5 tests PASS；typecheck 通过（selfbot 类型缺失则在 src 内统一 `import { Client } from 'discord.js-selfbot-youtsuho-v13'`，必要时建 `src/types/discord-selfbot.d.ts` 声明模块）。

- [ ] **Step 8: 提交**

```bash
git add -A && git commit -m "chore: relay 脚手架与配置加载"
```

---

### Task 2: Fastify 骨架、鉴权插件、统一错误体

**Files:**
- Create: `src/http/auth.ts`
- Create: `src/http/build-server.ts`
- Create: `src/server.ts`
- Test: `test/http-auth.test.ts`

**Interfaces:**
- Produces: `buildServer(deps: { config: Config; logger: Logger }): FastifyInstance`；当前只挂 `/healthz`（静态 `{loggedIn:false}`）与鉴权插件，后续 Task 挂路由。

- [ ] **Step 1: 写失败测试 `test/http-auth.test.ts`**

```typescript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import Fastify from 'fastify';
import { authPlugin } from '../src/http/auth.ts';

async function app(key = 'k'.repeat(32)) {
  const f = Fastify();
  await f.register(authPlugin, { key });
  f.get('/api/v1/ping', async () => ({ ok: true }));
  f.get('/healthz', { 'websocket': undefined as never, config: { public: true } } as never, async () => ({ loggedIn: false }));
  return f;
}

test('bearer token accepted', async () => {
  const f = await app();
  const r = await f.inject({ method: 'GET', url: '/api/v1/ping', headers: { authorization: 'Bearer ' + 'k'.repeat(32) } });
  assert.equal(r.statusCode, 200);
});

test('query key accepted', async () => {
  const f = await app();
  const r = await f.inject({ method: 'GET', url: '/api/v1/ping?key=' + 'k'.repeat(32) });
  assert.equal(r.statusCode, 200);
});

test('missing key -> 401 error envelope', async () => {
  const f = await app();
  const r = await f.inject({ method: 'GET', url: '/api/v1/ping' });
  assert.equal(r.statusCode, 401);
  assert.equal(JSON.parse(r.body).error, 'unauthorized');
});

test('healthz is public', async () => {
  const f = await app();
  const r = await f.inject({ method: 'GET', url: '/healthz' });
  assert.equal(r.statusCode, 200);
});
```

- [ ] **Step 2: 跑测试确认失败**

`node --import tsx --test test/http-auth.test.ts` → FAIL（模块不存在）

- [ ] **Step 3: 实现 `src/http/auth.ts`**

用 Fastify 路由级 hook：`onRequest` 中若 `routeOptions.config?.public === true` 放行；否则比对 `authorization` 去掉 `Bearer ` 前缀与 query `key`，常量时间比较（`crypto.timingSafeEqual`，长度不同直接拒）；失败 `reply.code(401).send({error:'unauthorized',message:'invalid or missing key'})`。导出 `authPlugin = fp(async function(f, opts:{key:string}){...})`（用 `fastify-plugin`，若不想加依赖则手写一个注册函数直接在 buildServer 中 `server.addHook('onRequest', ...)`——选后者，零新依赖：不使用 fp）。

最终实现形态（不用 fp）：在 `build-server.ts` 内 `server.addHook('onRequest', makeAuth(config.key))`；`makeAuth` 放 `auth.ts` 导出并单测：`makeAuth(key): onRequestHandler`。测试相应改为直接测 handler（构造假 req/reply）或对 buildServer inject。**以 buildServer inject 为准**，auth.ts 导出 `makeAuth`，buildServer 注册。

- [ ] **Step 4: 实现 `src/http/build-server.ts` 与 `src/server.ts`**

buildServer：创建 Fastify({logger:false})、注册 `@fastify/websocket`、addHook makeAuth、挂 `/healthz`（public config）返回 deps 传入的 health provider（Task 3 后替换为真实登录态；本 Task 先静态 `{loggedIn:false}`）；统一 `setErrorHandler`：503/502/501 等用 `{error,message}` 形态。
server.ts：`const config=loadConfig(process.env); const logger=createLogger(config.logLevel); const app=buildServer({config,logger,health:()=>({loggedIn:false})}); app.listen({port:config.port,host:'0.0.0.0'});` 监听 SIGTERM 优雅 close。

- [ ] **Step 5: 测试通过 + 手起服务冒烟**

```bash
node --import tsx --test test/http-auth.test.ts
DISCORD_TOKEN=x RELAY_KEY=$(node -e "console.log('k'.repeat(32))") npx tsx src/server.ts &
curl -s localhost:8790/healthz ; curl -s -o /dev/null -w '%{http_code}\n' localhost:8790/api/v1/ping
```
Expected: healthz 200；无 key 401。

- [ ] **Step 6: 提交** `feat: HTTP 骨架与 key 鉴权`

---

### Task 3: Discord 客户端封装与频道状态端点

**Files:**
- Create: `src/discord/discord-client.ts`
- Create: `src/stream/channel-state.ts`（类型 + 纯函数）
- Modify: `src/http/build-server.ts`（挂 `GET /api/v1/channels/:guild/:channel`）
- Test: `test/channel-state.test.ts`

**Interfaces:**
- `interface ChannelState { streaming: boolean; streamer: { id:string; name:string; avatar:string|null }|null; channelName: string; chatChannelId: string }`
- `selectStreamer(voiceStates: Map<string, RawVoiceState>, channelId: string): RawVoiceState | null`（纯函数：该频道内 `self_stream===true` 的成员，取第一个）。
- `class DiscordClient { constructor(token, logger); start():Promise<void>; get selfId():string; get loggedIn():boolean; get gatewayPing():number; getChannelState(guildId, channelId): Promise<ChannelState>; onVoiceStateUpdate(cb:(guildId:string, st:RawVoiceState)=>void):void; sendGateway(op:number, d:object):void; onRaw(t:string, cb:(p:any)=>void):void; sendMessage(channelId:string, content:string):Promise<void>; onChatMessage(channelIds: ReadonlySet<string>, cb:(m:ChatMessage)=>void):void }`
- `ChatMessage = { id:string; channelId:string; authorId:string; userName:string; nickname:string; avatar:string|null; content:string; createdAt:number }`

- [ ] **Step 1: 写失败测试 `test/channel-state.test.ts`**（纯函数）

用例：无成员→streamer null；有成员未开播→false；一人 `self_stream:true`→命中且 streaming true；多人取第一个开播者。RawVoiceState 最小字段 `{user_id, channel_id, self_stream}`，name/avatar 由 getChannelState 用 client 用户缓存补。

- [ ] **Step 2: 跑确认失败** → 模块不存在。

- [ ] **Step 3: 实现 `src/stream/channel-state.ts`**（类型 + selectStreamer，10 余行）

- [ ] **Step 4: 实现 `src/discord/discord-client.ts`**

基于 selfbot 库 `Client`：
- `new Client({ checkUpdate:false })`；`client.login(token)`；ready 后 resolve start；`debug` 事件接 logger.debug；
- 持有 `voiceStates: Map<guildId, Map<userId, RawVoiceState>>`，监听 raw `VOICE_STATE_UPDATE` 维护（channel_id 为 null 时删除）；
- `getChannelState`：从库 cache 取 `client.guilds.cache.get(guildId)?.channels.cache.get(channelId)`，频道类型必须是语音（GUILD_VOICE=2 / GUILD_STAGE_VOICE=13），否则抛 `badChannel`（400）；channelName=channel.name；chatChannelId=channelId；streamer 用 selectStreamer + `client.users.cache.get` 补 name/avatar（avatar URL：`https://cdn.discordapp.com/avatars/{id}/{avatar}.png?size=64`，无 avatar 用默认头像 id 规则或 null）；
- `sendGateway`：`(this.client.ws as any).broadcast({op, d})`（参考 index.ts 的 cast 做法）；
- `onRaw`：`client.on('raw', packet => packet.t===t && cb(packet.d))` 形态包装；
- `sendMessage`：`client.channels.fetch(channelId)` 后 `channel.send(content)`；403 抛带 `code='forbidden'` 的自定义错 `DiscordRestError`；rate limit（http 429）抛 `code='rate_limited'`；
- `onChatMessage`：`client.on('messageCreate', m => { if(channelIds.has(m.channelId) && m.author?.bot===false) cb(map(m)) })`；nickname=`(m.member as any)?.nick ?? m.author.username`；userName=`m.author.username`。
- 导出 `DiscordRestError extends Error { constructor(public code:string){} }`。
- 包裹对库的所有 import 于本文件，其他模块只依赖上面的接口。

- [ ] **Step 5: buildServer 接真实状态**

依赖改为 `{ config, logger, discord: DiscordClient }`；启动时 `await discord.start()` 后再 listen（catch 登录失败：logger.error 后仍 listen，healthz 报 loggedIn:false）。
`GET /api/v1/channels/:guild/:channel`：调 `discord.getChannelState`；`DiscordRestError code badChannel`→400；未知错→500 `internal`。
`/healthz`：`{ loggedIn: discord.loggedIn, accountName, userId, gatewayPing, lastGatewayReconnect }`（accountName 取 client.user.username，无则 null）。

- [ ] **Step 6: 测试通过**：`node --import tsx --test test/channel-state.test.ts && npx tsc --noEmit`

- [ ] **Step 7: 提交** `feat: Discord 客户端封装与频道状态端点`

---

### Task 4: 弹幕 WebSocket（收发、限流、self 过滤、presence）

**Files:**
- Create: `src/chat/rate-limiter.ts`
- Create: `src/chat/chat-hub.ts`
- Modify: `src/http/build-server.ts`（WS 路由）
- Test: `test/rate-limiter.test.ts`, `test/chat-hub.test.ts`

**Interfaces:**
- `class RateLimiter { constructor(minGapMs:number, perMinute:number); allow(): boolean }`（滑动窗口）。
- `class ChatHub { constructor(deps:{ discord: Pick<DiscordClient,'onChatMessage'|'sendMessage'|'selfId'>, logger }); attach(guildId, channelId, socket): void }`；socket 为最小接口 `{ send(s:string):void; close():void; readyState:number }`。
- 入站帧 `{type:'send', content:string, clientMsgId:string}`；出站帧见 spec §4.2。

- [ ] **Step 1: 写失败测试 `test/rate-limiter.test.ts`**

用例：首次 allow true；同刻第二次 false；虚拟时间（注入 `now: ()=>number` 构造参数，默认 Date.now）推进 801ms 后 true；1 分钟内第 21 次 false；61s 后恢复。

- [ ] **Step 2: 写失败测试 `test/chat-hub.test.ts`**（假 discord + 假 socket）

用例：
1. discord 来消息（authorId≠selfId）→ socket 收到 `type:'chat'` 且字段映射正确；
2. authorId===selfId → 不推送；
3. 收到 send 帧 → 调 discord.sendMessage，成功回 send_ok（带 clientMsgId）；
4. limiter 拒绝 → error rate_limited，且不调 sendMessage；
5. sendMessage 抛 DiscordRestError('forbidden') → error forbidden；
6. 两个 socket 同频道，消息广播给两者；一个 close 后不再收到；
7. `broadcastPresence(payload)`（presence 由 Task 7/9 的会话桥接触发，本 Task 先在 hub 暴露方法并测试）→ 所有 socket 收到 presence 帧。

- [ ] **Step 3: 跑确认失败。**

- [ ] **Step 4: 实现 rate-limiter.ts 与 chat-hub.ts**

hub 内部维护 `Map<string, Set<socket>>`（key `guild:channel`）；构造时注册一次 discord.onChatMessage，回调按 channelId 找集合广播；attach 时：每连接 new RateLimiter(800,20)，解析 JSON（try/catch，坏帧直接 error `bad_frame` 不关闭），content trim 后空串回 `send_failed`、超 2000 字符截断或拒（拒：`too_long`）；sendMessage 成功 → send_ok；DiscordRestError → 其 code；其他 → send_failed。close 时删引用。
广播序列化函数 `toChatFrame(m)` / `toPresenceFrame(p)` 导出供测试。

- [ ] **Step 5: buildServer 注册 WS 路由**

`GET /api/v1/channels/:guild/:channel/danmaku`（websocket: true）：握手时同样校验 key（query key 为主）；连接后 `chatHub.attach(guild, channel, ws)`，记录 logger.info `chat open/close`（不含内容）。WS 鉴权失败：`socket.close(4401,'unauthorized')` 并 return。

- [ ] **Step 6: 全部测试 + typecheck 通过后提交 `feat: 弹幕 WS 收发与限流`**

---

### Task 5: 流会话状态机与 fan-out（不接真实 Discord）

**Files:**
- Create: `src/stream/session-manager.ts`
- Create: `src/stream/stream-session.ts`
- Test: `test/stream-session.test.ts`

**Interfaces:**
- `interface StreamTransport {
     join(guildId:string, channelId:string): Promise<{ sessionId:string }>;
     leave(): Promise<void>;
     subscribe(guildId:string, channelId:string, streamerUserId:string): Promise<StreamTransportInfo>;
     unsubscribe(): Promise<void>;
   }`（Task 7 真实实现；测试用假实现）
- `interface StreamReceiver {
     start(transport: StreamTransportInfo, onChunk:(buf:Buffer)=>void): Promise<void>; // READY 到出流
     stop(): Promise<void>;
   }`（Task 6 真实实现）
- `StreamTransportInfo = { token:string; endpoint:string; serverId:string; sessionId:string; userId:string }`
- `class StreamSession {
     constructor(key:string, deps:{ transport:StreamTransport; makeReceiver:()=>StreamReceiver; logger:Logger; idleTeardownMs?:number });
     addSubscriber(send:(chunk:Buffer)=>void, onEnd:(err?:Error)=>void): ()=>void; // 返回退订函数
     get state(): SessionState;
   }`
- `class SessionManager { get(guildId,channelId,deps): StreamSession }`

- [ ] **Step 1: 写失败测试 `test/stream-session.test.ts`**（假 transport/receiver，用 deferred 控制时序）

用例：
1. 首个 addSubscriber → join+subscribe 各调用一次，state 到 RUNNING，receiver.onChunk 的 chunk 到达订阅者；
2. RUNNING 中第二订阅者不再 join/subscribe，也收到后续 chunk；
3. 一个订阅者抛错/退订，另一订阅者与 receiver 不受影响；
4. 全部退订后不立即 leave：idleTeardownMs 注入 50ms，50ms 内新订阅不触发 unsubscribe/leave；超过 50ms 无订阅 → unsubscribe+leave 各一次，回 IDLE；
5. join 失败 → 两个等待订阅者都收到 onEnd(error)，state 回 IDLE 可重试；
6. subscribe 抛 `not_streaming`（自定义 `SessionError(code,httpStatus)`）→ 订阅者收到该错；
7. 并发布尔：两个 addSubscriber 在 join 完成前到达，join 只一次（用 promise barrier 计数断言）。

- [ ] **Step 2: 跑确认失败。**

- [ ] **Step 3: 实现 stream-session.ts**

状态机字段与迁移严格按 spec §4.3；要点：
- `#readyPromise` 合并并发首订阅；JOINING 调 transport.join；随后由 `presenceProvider`/transport 查询当前是否 streaming（构造注入 `isStreamingNow:()=>Promise<{streaming:boolean; streamerUserId?:string}>`）决定直接 subscribe 还是 WAITING（等待 `setStreaming(true)` 通知，Session 暴露 `notifyVoiceState(streaming, streamerUserId)` 由 Task 9 的 raw 监听调用）；
- RUNNING：`makeReceiver()` → `receiver.start(info, chunk => broadcast(chunk))`；
- broadcast：每订阅者队列用 `highWaterMarkBytes=8*1024*1024`；同步尝试 `send(chunk)`（订阅 send 返回 false/抛错或待发字节超限 → 立即关闭该订阅者 onEnd(new Error('slow_consumer'))）；
- 退订到 0 → setTimeout teardown（默认 30000），teardown：receiver.stop→unsubscribe→leave→IDLE；新订阅清除 timer；
- 致命错误：onEnd 所有订阅者、teardown、state IDLE。

- [ ] **Step 4: 实现 session-manager.ts**

`Map<string, StreamSession>`，key `${guild}:${channel}`；get 时惰性创建，deps 工厂注入。

- [ ] **Step 5: 测试 + typecheck 通过，提交 `feat: 流会话状态机与 TS fan-out`**

---

### Task 6: RTP 管道纯函数与 ffmpeg TS 进程

**Files:**
- Create: `src/stream/codecs.ts`
- Create: `src/stream/crypto.ts`
- Create: `src/stream/ffmpeg.ts`
- Test: `test/codecs.test.ts`

**Interfaces:**
- `CODECS` 全量表 / `PT_TO_CODEC` / `buildSdp(videoPort:number, audioPort:number, codec:'H264'|'H265'): string` / `fixHevcNalHeader(buf:Buffer, payloadOffset:number):void` / `rewriteRtx(p: RtpPacket, videoSsrc:number, videoPt:number): Buffer`（剥 2B OSN、改 ssrc/pt 后 serialize）/ `detectCodec(pt:number): 'H264'|'H265'|'VP8'|'VP9'|'AV1'`
- `createDecryptor(mode:string, secretKey:Buffer): { decrypt(ciphertext:Buffer, nonce:Buffer, aad:Buffer):Promise<Buffer> }`（aead_aes256_gcm_rtpsize 用 crypto.subtle；aead_xchacha20_poly1305_rtpsize 用 sodium-plus）
- `startFfmpeg(codec:'H264'|'H265'|'VP8'|'VP9', opts:{onExit:(code:number|null)=>void}): Promise<{ proc:ChildProcess; videoPort:number; audioPort:number; ready:Promise<void>; stdout:Readable }>`（VP8/VP9 用转码参数）

- [ ] **Step 1: 写 `test/codecs.test.ts` 失败测试**

- buildSdp：H264 含 `a=rtpmap:101 H264/90000` 与 `m=audio {port}`；H265 PT=103 且无 H264 fmtp；
- fixHevcNalHeader：构造 2 字节头 `[0x09&保留F位, 0x00]` 单 NAL 与 AP(type 48，含 1 个子 NAL)，断言改写后 byte0 最低位为 0、byte1===0x01，子 NAL 同样被改；
- PT_TO_CODEC[101/103/105/109] 映射；
- detectCodec(103)==='H265'；
- rewriteRtx：手工构造 RtpPacket（werift-rtp 的 RtpPacket.serialize）payload=`[OSN hi,OSN lo, 0x67,...]`、ssrc=rtxSsrc、pt=102 → 输出 ssrc=videoSsrc、pt=101、payload 已剥 2 字节。

- [ ] **Step 2: 跑确认失败。**

- [ ] **Step 3: 实现 codecs.ts**

CODECS/SIMULCAST_STREAMS、buildSdp、fixHevcNalHeader(At)、parseIpDiscoveryResponse 全部按参考实现 35–253 行原样移植（已验证）；detectCodec 查 PT_TO_CODEC；rewriteRtx 用 `RtpPacket.deSerialize`→改 header.ssrc/header.payloadType、payload.subarray(2)→serialize。

- [ ] **Step 4: 实现 crypto.ts**

AES256Decryptor/Chacha20Decryptor 按参考实现 95–136 行移植；`createDecryptor(mode, key)` 工厂；mode 白名单外抛错。

- [ ] **Step 5: 实现 ffmpeg.ts**

- `allocateFreshUdpPorts(20 次避让 RTP/RTCP 对撞)` 同参考；
- spawn 参数（与参考的关键差异：输出 stdout TS）：

```
ffmpeg -reorder_queue_size 500 -max_delay 500000 -err_detect ignore_err
  -fflags +genpts+discardcorrupt -f sdp -analyzeduration 1M -probesize 1M
  -protocol_whitelist file,udp,rtp,pipe,fd -i -
  <视频编码参数> -c:a copy -f mpegts -flush_packets 1 pipe:1
```

H264/H265：`-c:v copy`；VP8/VP9：`-c:v libx264 -preset veryfast -pix_fmt yuv420p -b:v 4000k`。
SDP 仍写 stdin 并 end；stderr 首 data → ready resolve；std0 继承丢弃、stderr 消费防阻塞；onExit 回调。VP8/VP9 SDP 的 PT/rtpmap 相应生成（VP8/90000、VP9/90000）。
- ready 前到达的包由 receiver 丢弃（同参考）。

- [ ] **Step 6: 测试 + typecheck；另做 ffmpeg 存在性检查**

`ffmpeg -version`（本机若无：Windows 装 ffmpeg 或把该 Task 的手动验证推迟到 Docker；CI 型单测不启动进程）。提交 `feat: RTP codec/解密工具与 ffmpeg TS 进程`。

---

### Task 7: 真实 StreamReceiver（voice WS + UDP + 动态 codec）【需联调，先写完不接真号】

**Files:**
- Create: `src/stream/stream-receiver.ts`
- Create: `src/discord/stream-transport.ts`

**Interfaces:**
- 实现 Task 5 的 `StreamReceiver` 与 `StreamTransport`。
- `StreamReceiver` 事件化回调构造：`new StreamReceiver(logger)`；`start(transport: StreamTransportInfo, onChunk)`、`stop()`。

- [ ] **Step 1: 实现 stream-receiver.ts**

以 `.discord-ref-tmp/stream-receiver.ts` 为底做**定向改造**（不是复制整个文件，逐函数对照）：

1. 删除文件落盘、remuxFile、outputPath/filename、mkdirSync；
2. `spawnFfmpeg(codec)` 改为调 Task 6 的 `startFfmpeg`，stdout 接到 `onChunk`（flowing 模式直接 data 事件回调）；
3. codec 不再写死 spawn H265：op12 拿到对端 SSRC 后以 **H264** 启动；在 `onUdpMessage` 内视频包首次探到 PT：
   - PT=101 保持；PT=103 → 停掉当前 ffmpeg（SIGTERM，换端口重新 allocate），以 H265 重启并启用 HEVC NAL 改写，状态变量 `wireVideoCodec` 此后锁定；
   - PT=105/107 → 以 VP8/VP9 转码模式重启一次；PT=109 → `fatal(new SessionError('codec_unsupported',501))`；
4. 保留：voice op 表、IDENTIFY/HEARTBEAT/READY/UDP discovery/SELECT_PROTOCOL/ACK/op12/MEDIA_SINK_WANTS 全流程、AAD/nonce 切分与解密、RTX 分支、去 extension 重序列化、关键帧门限（首视频包等 AP/关键帧）；
5. WS close 重连：`code===4015 || code<4000` → 1s 重跑 `connect()`（重发 IDENTIFY 起全流程），重连期间不杀 ffmpeg；连续 5 次重连失败 → fatal SessionError('session_failed',502)；
6. `stop()`：stopped→清心跳→关两个 UDP→关 WS→SIGTERM ffmpeg 并等 exit（2s 超时），**不 remux**。

- [ ] **Step 2: 实现 stream-transport.ts**

按参考 index.ts 已核实写法（对 DiscordClient 薄封装）：
- `join(guild,channel)`：`discord.sendGateway(4,{guild_id:guild, channel_id:channel, self_mute:true, self_deaf:false, self_video:false})`；等 raw `VOICE_STATE_UPDATE` 过滤 `d.user_id===discord.selfId && d.channel_id===channel` 取 `d.session_id`，15s 超时；
- `leave()`：op4 channel_id:null；
- `subscribe(guild,channel,streamerUserId)`：stream_key=`guild:${guild}:${channel}:${streamerUserId}`；注册一次性 raw 监听收集 `STREAM_CREATE`(d.rtc_server_id) 与 `STREAM_SERVER_UPDATE`(d.token,d.endpoint)；`STREAM_DELETE`→reject SessionError('not_streaming',503)；齐了 + join 的 sessionId → resolve StreamTransportInfo；发 op20；15s 超时 not_streaming；
- `unsubscribe()`：op19 同 stream_key；
- 并发原语：每操作一个 promise + 清理函数，禁止重复订阅。

- [ ] **Step 3: typecheck 通过**（无真实网络测试），提交 `feat: Discord stream 信令与 RTP 接收器（TS 输出+动态编码+重连）`。

---

### Task 8: /stream HTTP 端点与端到端闸门（需用户 token）

**Files:**
- Modify: `src/http/build-server.ts`
- Create: `src/presence-bridge.ts`
- Modify: `src/server.ts`（装配）

- [ ] **Step 1: 装配**

server.ts：创建 DiscordClient 并 start；ChatHub；StreamTransport（包 discord）；SessionManager（makeReceiver 注入 `()=>new StreamReceiver(logger)`，isStreamingNow 用 `discord.getChannelState`，transport 即 stream-transport）。
`GET /api/v1/channels/:guild/:channel/stream`（query/header key）：
- 未登录 → 503 relay_not_logged_in；bad_channel→400；
- 取 session；`reply.raw` 写响应头 `Content-Type: video/mp2t`、`Cache-Control: no-store`、`Connection: keep-alive`、200；
- `session.addSubscriber(chunk => reply.raw.write(chunk), err => { try{reply.raw.end()}catch{} })`；
- 连接 `close`/`error` → 调退订；
- addSubscriber 异步抛 SessionError：若响应头发了就 destroy 连接；未发则按 httpStatus 返回 JSON 错误体（在 addSubscriber 的 ready promise 失败路径上区分：先 await ready（不写流头），成功后再写 200 与订阅）。

- [ ] **Step 2: presence-bridge**

`discord.onVoiceStateUpdate` → 更新对应 session.notifyVoiceState；同时向 ChatHub 广播 presence（streaming + streamer 摘要），供 App 「已开播」提示。

- [ ] **Step 3: 本地起服务（token 闸门）**

向用户索取 `DISCORD_TOKEN`（用户放入本机 `D:/project/discord-live-relay/.env`，gitignore 已忽略；AI 不代存），生成 RELAY_KEY：

```bash
node -e "console.log(require('crypto').randomBytes(32).toString('base64url'))"
npx tsx --env-file=.env src/server.ts
```

- [ ] **Step 4: 端到端验收（目标房间 979365387705647124 / 979365387705647129，主播开播时）**

```bash
# 状态
curl -s -H "Authorization: Bearer $K" http://127.0.0.1:8790/api/v1/channels/979365387705647124/979365387705647129 | jq
# 流（VLC 或 ffplay 打开）
ffplay -fflags nobuffer -headers "Authorization: Bearer $K" \
  http://127.0.0.1:8790/api/v1/channels/979365387705647124/979365387705647129/stream
```

验收点：出画面与声音、延迟 ≤3s、日志中编码（H264/H265 路径都验到，验不到 H265 则在日志确认 PT=101 即可）、第二播放端 fan-out 正常、关闭两端后 30s 日志出现 op19/op4 离房、未开播时 503 not_streaming。

- [ ] **Step 5: 弹幕验收**

```bash
npx wscat -c "ws://127.0.0.1:8790/api/v1/channels/979365387705647124/979365387705647129/danmaku?key=$K"
# 发 {"type":"send","content":"relay test","clientMsgId":"1"}，Discord 客户端应看到；频道内他人发言应推送 chat 帧
```

- [ ] **Step 6: 提交** `feat: /stream 端点与会话装配（E2E 通过）`（若验收发现问题，修复后提交，commit 说明实测现象）。

---

### Task 9: 容错收尾与全量测试

**Files:** 视 Task 8 实测修修补补；补 `test/session-reconnect.test.ts`（如可纯测）

- [ ] **Step 1:** 主网关 ready 后对活跃 session 重放 join 的钩子（discord-client 暴露 onReady 事件，session-manager 监听后对 RUNNING/WAITING session 调 `rejoin()`：重发 op4）。
- [ ] **Step 2:** UDP 20s 无包看门狗：receiver 收包时间戳，定时器超时 → fatal session_failed。
- [ ] **Step 3:** `npm test` 全绿、`tsc --noEmit` 干净；跑 30 分钟稳定性观察（主播在播时）：日志无异常重连风暴、内存平稳。
- [ ] **Step 4:** 提交 `fix: 网关重放与无包看门狗等容错收尾`。

---

### Task 10: Docker、NAS 部署与 frp

**Files:**
- Create: `Dockerfile`
- Create: `.dockerignore`
- Create: `deploy/compose.yml`
- Create: `deploy/relay.env.example`
- Create: `README.md`（含 token 获取手册 §spec 7.3、frp 配置、API 说明）

- [ ] **Step 1: Dockerfile**

```dockerfile
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
 && rm -rf /var/lib/apt/lists/* && useradd -r -u 10001 app
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev || npm install --omit=dev
COPY . .
USER app
EXPOSE 8790
CMD ["node", "--import", "tsx", "src/server.ts"]
```

（部署在 NAS 内网，镜像体积不敏感；base 走 NAS mirror 配置在 dockerd 而非 Dockerfile。）

- [ ] **Step 2: 本地构建冒烟**

`docker build -t 192.168.31.140:6006/discord-live-relay:dev .`，`docker run --rm --env-file .env -p 8790:8790 ...` 重复 Task 8 的 curl。

- [ ] **Step 3: 推送镜像（用户授权后）**

`docker push 192.168.31.140:6006/discord-live-relay:latest`（仓库 192.168.31.140:6006，HTTP insecure registry 配置沿用现有）。

- [ ] **Step 4: NAS 部署**（SSH 群晖 1235，docker 用 root + 绝对路径，遵记忆 nas-access）

建 `/volume1/Packages/discord-relay/relay.env`（0600，真实 token/key）与 compose.yml：

```yaml
services:
  discord-live-relay:
    image: 192.168.31.140:6006/discord-live-relay:latest
    env_file: /volume1/Packages/discord-relay/relay.env
    ports:
      - "192.168.31.140:8790:8790"
    restart: unless-stopped
```

`docker compose up -d` 后局域网 curl healthz。

- [ ] **Step 5: frp**

小米 3.10 frpc.toml 加 spec §7.2 的 tcp/47920 proxy 后 reload；**请用户在阿里云安全组放行 47920/TCP**；外网 `curl http://112.126.78.147:47920/healthz` 验收；外网 VLC + wscat 复验 Task 8 用例。

- [ ] **Step 6:** GitHub 建私库并推送（用户授权时）：`my57575757/discord-live-relay`。
- [ ] **Step 7:** 提交 `build: Dockerfile/compose/README 与部署配置`。计划 1 完成，回报实测结果，再写计划 2（core）。
