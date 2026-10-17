# M4-2 数据面收尾 Minor 补丁设计（独立小计划）

> 状态：设计待审
> 日期：2026-10-17
> 来源：M4-2 SDD ledger 中 park 到 M4-3 的 Minor（T5 M-1/M-2、T6 M-1/M-2/M-3）
> 与终审 FW-1，统一重新编号 D1–D6。
> 执行顺序：**先于 M4-3 账号面计划**（半天量，独立分支，合回 my_dev 后
> M4-3 从新 my_dev 切出）。

## 1. 目标与边界

只收口 M4-2 数据面已识别的健壮性与测试债，不改协议、不改载荷、不加功能。
行为变化仅限：存储层异常不再穿透 dmw handler、外部 reload 回调异常不再
成为未捕获错误、子引擎 reload Timer 可取消。Android/TV 零变化（数据面
仅在 Windows 主子引擎注册）。

## 2. 条目

### D1（T5 M-1）外部 onSettingsChanged 回调异常隔离

- 现状：`MainDataPlaneService._scheduleReload`（main_data_plane_service.dart:104）
  直接 `onSettingsChanged?.call()`；`SubDataPlaneClient._scheduleReload`
  （sub_data_plane_client.dart:59）Timer 内直接调用，reconcile（:50）
  同步直接调用。回调是外部注入点（生产为 AppSettingsController.reloadFromStorage），
  其异常会穿透为未捕获 async 错误（Timer 回调）或打断 reconcile。
- 改动：三处调用包 try/catch，`Log.d('设置 reload 回调异常：$e')`，
  不影响后续防抖与数据面状态。
- 测试：各 1 例——注入抛异常回调，主端 box 变更/fakeAsync 100ms 后
  不抛、后续变更仍能再次调度；子端 reconcile 捕获后仍完成 seedReplace。

### D2（T5 M-2）主端 handler 落盘失败的错误语义

- 现状：handleCall 中 kvSet/kvDelete/kvClear/volumeSet/followSet/
  followRemove 的 await 落盘未包 try（followRemove 见
  main_data_plane_service.dart:219-224；historyAdd :226-236 已包）。
  Hive 写抛错时异常经 method channel 逸出，子端 RemoteKvBox 乐观态
  与主端不一致且无 false 回执。
- 改动：每个落盘 await 包 try/catch（含 _withRemoteFlag 体内），
  catch → `Log.d(...)` + `return false`；注意 `_withRemoteFlag` 的
  finally 必须在异常路径仍复位 `_remoteWrite`（现结构 finally 已保证，
  评审时核验）。dp_ready（纯读）与 historyAdd 不动。
- 测试：storage/db 假实现抛异常时，六方法各返回 false 且不抛；
  成功路径仍 true（既有测试回归）。

### D3（T6 M-1）kindVolume 畸形值处理显式化

- 现状：sub_data_plane_client.dart:94 非 num 值走 `seedVolume(key, null,
  deleted: value==null)`。**实施实证（SDD Task 3）修正了原判断**：
  String 畸形值产生的是 `seedVolume(null, deleted: false)`，而
  InMemoryDBService.seedVolume 的 deleted/value 两分支均不命中
  （in_memory_services.dart:75-81），本就是静默忽略——原 spec
  「String 被当作删除」系误读，现状语义已正确，只是靠隐式 fallthrough
  意外正确。输入只来自受信主端，生产不可达。
- 改动（零行为变化的显式化重构）：写清三分支——`e.clear` 清空；
  `deleted==true || value == null` 删除；`value is num` 转 double 写入；
  其余（String 等）落到分支外即忽略，与 shield「非 String 忽略」对称。
- 测试：并入 D4 表驱动；'junk' 用例在重构前后均绿，为锚点而非红测。

### D4（T6 M-3）volume 三分支表驱动测试

- 新增表驱动单测覆盖 kindVolume：double/int 正常写入、clear、
  deleted 标志、显式 null、String 畸形忽略，五输入各断言
  InMemoryDBService 落地状态（exportVolumes）。

### D5（T6 M-2）SubDataPlaneClient.dispose

- 新增 `void dispose() => _reloadTimer?.cancel();`。
- 生产现状子引擎为进程级生命周期、无销毁钩子，本条目**不新增接线点**
  （M4-3 presence coordinator 同为进程级，不调它）；交付方法 + 测试，
  供未来引擎/窗口级销毁出现时直接可用。
- 测试：fakeAsync 中触发 _scheduleReload 后 dispose，100ms 后回调
  未被调用；dispose 后再收 handleChanged 不抛。

### D6（FW-1）真实 Hive put/delete 的 temp-dir 回归

- 现状：真实 Hive 仅 clear 路径有 temp-dir 回归（T5 第 12 例）；
  put/delete 穿主端 handler 的端到端路径无自动化，`_remoteWrite`
  owner-reload 行为只靠源码与手工取证。
- 改动：复用 T5 clear 例的 temp-dir 夹具（setUp/tearDown 开/删箱，
  tempDir 创建移入 try 内或补 finally 清理——一并修掉 ledger 记录的
  夹具 Minor），新增 1–2 例：dp_kv_set/dp_kv_delete 真实 Hive 落盘后，
  主端 owner reload 被调度（fakeAsync 100ms 观察注入回调恰好触发），
  且 watch 扇出仍只发一次（既有 fake 端口断言不回归）。

## 3. 文件与测试

- 改：`lib/app/multiwindow/data/main_data_plane_service.dart`、
  `lib/app/multiwindow/data/sub_data_plane_client.dart`。
- 测：既有对应测试文件内增量新增约 8 例（D1×2、D2×3 合并参数化、
  D3+D4 表驱动 1 组、D5×1、D6×1–2）。
- 不新增生产文件、不改协议、不改 app_pages/bootstrap 注册。

## 4. 门禁

- `C:/tools/flutter347/flutter/bin/flutter.bat analyze` 零新增告警；
- 全量 `flutter test` 绿（基线 227，完成后约 235）；
- `flutter build windows --debug` 成功（落盘路径改动，跑一次）；
- GUI 无新增项：改动均为错误路径，常规设置/关注操作冒烟随 M4-3
  GUI 清单第 1 项回归抽验覆盖。
