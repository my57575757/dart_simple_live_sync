# 抖音游客验证与骨架房兜底设计

日期：2026-10-05
涉及仓库：`dart_simple_live`（simple_live_app / simple_live_core）、`sendDanMu`（live-guard-server）

## 1. 背景与根因

- 账号被某直播间拉黑后，SSR 仅下发骨架 `roomInfo: {web_rid, web_stream_url}`；部分房间即使剥离 sessionid 匿名 GET，仍稳定只返回骨架（实测 webRid `17334779490`，连续 3 次一致；`201413078149` 匿名可拿到完整 state，抖音按房间/实验下发）。
- 真实抖音网页遇到骨架时，客户端会再调 `/webcast/room/web/enter/`（自动带 `a_bogus` 签名）hydrate。guard 未做这步，core 走 `buildOfflineDetail` 显示"未开播"，而实际在播。
- 全新设备无可信 ttwid 时，先撞「验证码中间页」（滑块），过验证拿到可信 ttwid 后游客即可观看。
- 报错点：`DouyinSite.parseRoomStateFromHtml`（simple_live_core/src/douyin_site.dart:553），以及骨架误判未开播。

## 2. 范围

- 端：simple_live_app 的 Android 与 Windows；不含 TV 端。
- 信任记录：guard 内存缓存，TTL 12 小时，容器重启失效。

## 3. 整体流程

### 3.1 guard 取房链路（改造 `/api/room/html`）

1. 登录态文档有效 → 原样返回（`guest=false`）。
2. 无效时查 trust 缓存（key=webRid）：
   - 命中：在 puppeteer 受信页面内经 CDP 携带 trust cookie 同源 fetch（剥离 sessionid），保留 3s/6s 重试；仍撞验证页 → 删除该条 trust，走下一步。
   - 未命中：现有受信匿名 fetch。
3. 结果分类（`VERIFY_PAGE_RE` 增补 `验证码中间页`、`sec_sdk_build/.../captcha` 特征）：
   - 验证页 → HTTP 200 `{code:4031, message:"需要游客验证", data:{webRid}}`。
   - 骨架房（实际可能在播）→ 方案 A：guard 用 `src/vendor/abogus.js` 给 `/webcast/room/web/enter/` 签名后请求，把返回 room 合成 core 可解析的 `{\"state\":{...}}]` 形态 HTML（见 3.3）。
   - 正常文档 → 原样返回。

### 3.2 App 侧流程

4. `/api/room/html` 返回 code 4031 → 弹「游客验证」窗（内嵌 WebView 打开 `https://live.douyin.com/<webRid>`）。
5. 用户完成滑块、页面 hydrate 成功 → 导出该域全部 cookie + UA → `POST /api/room/trust`。
6. guard 落 12h 缓存；弹窗自动关闭，App 自动重放取房进房（最多 1 次）。
7. 用户取消 → 保留现有错误提示。

### 3.3 骨架房 enter 兜底（方案 A）

- guard 侧构造 `/webcast/room/web/enter/` 请求参数（aid=6383、web_rid、enter_from=page_refresh 等，参照真实页面 reqid 647 的参数集），用 `vendor/abogus.js` 生成 `a_bogus`。
- 在受信浏览器页面内发起（sec SDK 环境一致），响应 `data.data[0]` 即完整 room（含 status、stream_url、owner）。
- 合成文档：把 enter 返回的 room/owner 包装为
  `{\"state\":{\"appStore\":{},\"roomStore\":{\"roomInfo\":{\"room\":<room>,\"anchor\":<owner>}},\"userStore\":{\"odin\":{\"user_unique_id\":<from page>}}}}]` + 结尾 `\n`，
  保证 core 正则 `\{\\"state\\":\{\\"appStore.*?\]\\n` 命中、`_getRoomDetailByWebRidHtml` 字段映射完整。
- 本质是一次游客进场；仅对骨架房触发。

## 4. API 契约

### `POST /api/room/trust`

请求：
```json
{ "webRid": "17334779490", "cookies": "ttwid=...; s_v_web_id=...; msToken=...", "ua": "Mozilla/5.0 ..." }
```
- cookies 必须含非空 `ttwid`，否则 400。
- 服务端剔除任何 `sessionid` 等账号字段。

响应：标准 `{code:0,message:"ok",data:{}}`；失败 `{code:4xx,message}`。

### `/api/room/html` 新增响应

验证页：HTTP 200，body `{code:4031, message:"需要游客验证", data:{"webRid":"..."}}`（HTTP 状态码保持 200，错误语义走 body code）。

## 5. trust 缓存

- 存储：guard 内存 `Map<webRid,{cookies,ua,expireAt}>`，TTL 12h。
- 使用：受信页面内同源 fetch，经 CDP 仅对当前请求附加 trust cookie（请求头覆盖，不写入 profile），UA 同步覆盖；始终剥离 `sessionid/passport_csrf_token` 等账号字段。
- 失效：取房再撞验证页 → 立即删条目并回 4031；不做静默续期。
- 并发：同一 webRid 的 trust 写入合并；无新锁。

## 6. App 弹窗

- 入口：仅 code 4031 时弹出。
- 隔离：
  - Android：`incognito: true` 的 InAppWebView。
  - Windows：插件（flutter_inappwebview_windows 0.6.0）不支持隐身/独立 profile 的 cookie 隔离 —— 弹窗前用 CookieManager 删除 `live.douyin.com` / `.douyin.com` 下全部 cookie（登录 cookie 已持久化 Hive，关窗后写回）；或改用独立 webViewEnvironment 临时数据目录，实现时以实测二选一。
- 完成判定：`onLoadStop` 后 URL 仍为该房间、标题 ≠「验证码中间页」、观察到 stream/enter 请求 200；"完成验证"点亮，支持自动检测直接提交。
- 提交：CookieManager 取该域全部 cookie，筛选设备类（`ttwid/s_v_web_id/msToken/UIFID` 等），排除 `sessionid`，连同 UA POST；成功后自动重放进房。
- UI：移动端全屏弹窗 / Windows 居中大对话框，标题"游客验证"，可取消，底部注明"验证结果仅保存 12 小时"。

## 7. 错误处理

- 验证页漏检：扩充特征并加真实验证页样本单测。
- enter 兜底失败（签名/请求异常）：不回假数据，回退骨架现状（未开播提示）并日志标记。
- trust 提交后取房仍失败：自动重放最多 1 次，仍失败提示手动重试，不循环弹窗。

## 8. 测试

- guard（vitest，mock fetch 不打外网）：验证页分类（含 6297 字节真实中间页样本）、trust 缓存 TTL/失效、enter 签名 URL 生成、骨架房合成 HTML 可被 core 正则命中。
- core（dart test）：合成 HTML 样本的 `parseRoomStateFromHtml` 与房间映射测试。
- App：真机手工实测 Android + Windows 全链路：验证页 → 弹窗 → 滑块 → 自动进房播放 → 杀进程重进命中 12h 缓存。

## 9. 落地顺序

1. guard：验证页特征 + 4031 响应 + trust 接口与缓存
2. guard：骨架房 enter 兜底（方案 A）
3. App：4031 识别 + 游客验证弹窗（先 Android）
4. App：Windows 弹窗与 cookie 隔离
5. 真机联调，两端各自发版
