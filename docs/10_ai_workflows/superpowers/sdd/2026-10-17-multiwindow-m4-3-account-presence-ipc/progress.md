# SDD ledger — plan: docs/10_ai_workflows/superpowers/plans/2026-10-17-multiwindow-m4-3-account-presence-ipc.md

分支：feat/m4-3-presence-ipc（就地分支，不用 worktree）
BASE（Task 1 派单前）：de0990b4c3c6e139e7306548bb79a1766d539133
测试基线：234；analyze 基线 22 条（2 warning + 20 info）

## Pre-flight 冲突扫描（派单前）

| 对/任务 | 共享面 | 结论 |
|---|---|---|
| T1↔T2 | douyin_presence_gateway.dart、presence_claimant.dart、live_room_controller.dart、douyin_presence_gateway_test.dart | T1 立接口/串行域，T2 在其上做 #3–#7 与 reason 细分；顺序执行，T2 文本给的是 T1 后形态。无矛盾。 |
| T2↔T8 | routes/app_pages.dart kShell 守卫块（T2 注入 isAccountLoggedIn 闭包；T8 注册 MainPresenceService + 委托） | 同一代码块不同行，T8 文本基于 T2 后形态。顺序执行即可。 |
| T1↔T10↔T11 | live_room_controller.dart（T1 换型/发送改道，T10 implements+装配，T11 子窗绑定） | T11 消费 T1 的 debugBindPresenceClient/_doEnterViaGateway 与 T9 coordinator、T10 resolver；类型链已核对（applySuspended 全 Future<void>）。 |
| T2↔T10 | applySuspended 签名链（端口→控制器→适配器→RemotePresenceTab→PresenceApplyTarget→coordinator） | 自审发现 T2 漏改 _ControllerPresenceTab override，已在计划中补上（invalid_override 预防）。 |
| T3↔T10 | tab_store.dart presenceGateway 字段（T3 换 PresenceBatchReleaser?，T10 构造传 coordinator） | 命名一致，coordinator implements 该接口。 |
| T7↔T8 | MainPresenceService 由 T7 新建、T8 在 app_pages 注册并接线 default 委托 | T8 同时改 main_data_plane_service 构造；T7 不碰该文件。 |
| T9↔T10 | IpcPresenceCoordinator（T9 新建，T10 子引擎 bootstrap 装配） | resolver 闭包接 controllerForTabId（T10 新增接口方法）。Ruling 已在计划内：闭包解析而非 coordinator 直接依赖 registry。 |
| T7↔T9 | SubPresencePort（T7 新建 Dmw 实现+抽象，T9 消费） | 单向依赖。 |
| T4↔T7↔T9 | PresenceProtocol encode/decode 命名 | 已核对：encodeRegister/decodeRegister/decodeClaim/encodeClaimOk/encodeClaimFailure/decodeClaimResult/encodeSendResult/decodeSendResult/decodeApplyEnter/decodeTabApply/mRegister/mClaim 等跨任务一致。 |
| 各任务自身 | 测试 vs 代码 | T11 toast 用例依赖 smart_dialog pump 时序，属实施期验证项，非计划矛盾；计划已给 3s 冲 Timer。 |

Ruling: 扫描无阻断性冲突，全部按 T1→T13 顺序派单。T2/T8 同块编辑严格串行。

## 任务进度

- Task 1: complete — commit 4ddc1f1（BASE de0990b）。评审 PASS+APPROVED。测试 234→243 全绿，analyze 22 条零新增。合法偏离：DouyinDanmakuArgs 去 const（core 构造非 const）。Nits（不阻断）：①presence_gateway_controller_test 新增用例对新旧路径区分度弱，真正锚点在 reroute 新文件 ②action not_login 文案不对称（T2 登录态注入时可统一）③网关两 AsHolder 闭包重复（T2 细分 reason 时可抽）④local_presence_client import 非字典序（lint 未启用 ordering）。
- Task 2: fix round 1 — commit 479b9fc（BASE 4ddc1f1）评审 Spec PASS / 质量 CHANGES-REQUESTED。Ruling: 接受 major-1——心跳 beat 不经 _serialized，404 reregister 的 await 期间 holder 可能已切换，else/catch 无条件 _suspend(旧tab) 会误取消新 holder 的 Timer。spec §6.3「reregister 失败转 suspended」语义约束为「该 tab 仍持有时」，与 inRoom 分支 L516 复检同源；补 holder 归属守卫，不违背 spec。代价：若判错（实际未切换）后果是旧 holder 少一次 suspend——代码路径上 arbiter.holder 是唯一事实源，不会判错。major-2（#4 用例无法回归 Timer 泄漏）同批以 fakeAsync periodicTimerCount==0 补强。nit（onClose 未置 null Timer、_beatInFlight 跨 holder 保守跳过一拍）park 不改。
- Task 2: complete — fix commit 8774514（BASE 479b9fc），scoped re-review APPROVED（major-1/major-2 均 RESOLVED，无新 finding）。major-1 修法：reregister 成功/失败/catch 三分支 + inRoom 复检均加 arbiter.holder 持有权守卫，finally 仅复位 _beatInFlight。major-2 实证：交错用例切 479b9fc 实测红（suspended 0 vs 1），恢复 8774514 绿；#4 加 periodicTimerCount==0（生产修复主体已落地，该断言属回归锁定）。测试 243→251 全绿（+8），analyze 22 条零新增。计划文本回写 commit 2f8aa91。观察项（不修）：follow_douyin_queue_test「队头失败本轮不暂停」1 次 flake，隔离/复跑全绿，疑既存时序敏感，建议后续单独稳定化。
- Task 3: complete — commit ce20d8b（BASE 55d15cd）。评审 PASS+APPROVED，无 major/minor。PresenceBatchReleaser 单方法接口落地，网关 implements（合法偏离：batchRelease 补 @override），TabStore 字段换型 presenceGateway 名不变，_batchClosing/_batchGuarded 门控三批量方法（单标签 close 不受门）。测试 251→252（#8 用例反事实推演确认旧码必红，回归有效），analyze 22 零新增，build windows --debug 成功。Ruling: brief Step 6 grep「shell 零命中」与 Step 4(b) 逐字注释自相矛盾——字段文档注释提及 DouyinPresenceGateway 属说明性文本，接受，grep 意图（无 import/代码耦合）已满足。Nits parked：①room_shell_page 关窗路径不等待批量摘栈完成即销毁进程，在途 exit HTTP 可能被截断（brief 既定终态幂等语义推论，影响可忽略，T10/集成知悉）②tab_strip unawaited 批量调用的失效 tabId 错误为既存行为，实际不可达。
- Task 4: fix round 1 — commit 72a65d8（BASE 6bf32b9）主体评审 Spec PASS / 质量 APPROVED（2 minor + 1 nit）。Ruling: 虽双结论通过，仍在 T7 接线前修一轮——minor-1 为 decodeClaim/decodeApplyEnter 对内层 Map 非 String 键（如 guardExtra:{1:'x'}）抛 _TypeError 而非返回 null，违反协议「错类型→null」承诺；spec §8 虽允许「false/异常结果」且现状 fail-closed（invoke 报错→子端 ipcFailed，不入栈不发 HTTP），但 T7 handler 将按 decode 恒不抛设计，凭据边界宜严格。修法：Map.from 前加 keys.every((k)=>k is String)。minor-2 为测试漏钉（ipcFailed 抛 ArgumentError、空 cookie/webRid 合法、非 String cookie 值脱敏 <cookie:0chars> 等），同批补。nit（encodeGuardSend 不校验 kind/content 一致性，内部编码器自造报文 decode 必 null）park。合法偏离：测试两处补 const 消 lint。
- Task 4: complete — fix commit bf41740（BASE 72a65d8），scoped re-review APPROVED（minor-1/minor-2 均 RESOLVED，无残留）。硬化：decodeClaim/decodeApplyEnter 在 Map.from 前加 keys.every((k)=>k is String)，decode 恒不抛；测试在既有 4 个 test() 内补 16 条断言（非 String 键回归钉经红证：旧码 LinkedHashMap.from 抛 _TypeError；ipcFailed 抛 ArgumentError、空 cookie/webRid 合法、非 String cookie 脱敏 <cookie:0chars> 等）。测试计数仍 256（断言净增、test() 数不变），analyze 22 零新增。commit 72a65d8+bf41740。
