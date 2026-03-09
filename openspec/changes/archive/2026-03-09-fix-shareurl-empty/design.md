## 上下文

当前 `DBService.addFollow()` 方法已经实现了 shareUrl 保护逻辑：当新数据的 shareUrl 为空且本地已有有效 shareUrl 时，保留原有值。

但问题在于有 3 个同步相关的地方直接调用 `followBox.put()` 绕过了这个保护：
1. `sync_service.dart:_syncFollowUserReuqest()` - 本地网络同步
2. `remote_sync_webdav_controller.dart:_recovery()` - WebDAV 同步恢复
3. `remote_sync_room_controller.dart:onReceiveFavorite()` - 远程房间同步

这些同步场景下，云端或其他设备的数据可能包含空的 shareUrl（因为不同设备获取 shareUrl 的时机不同），直接覆盖会导致本地有效的 shareUrl 丢失。

## 目标 / 非目标

**目标：**
- 确保所有写入关注数据的地方都保留有效 shareUrl
- 修复同步功能中 shareUrl 被空值覆盖的问题
- 保持现有同步逻辑的其他行为不变

**非目标：**
- 不改变 shareUrl 的获取机制（仍然只在同步时获取）
- 不修改数据模型或存储结构
- 不改变不同设备间的同步优先级策略

## 决策

### 决策 1：创建 `updateFollow` 方法替代直接 `put`

**方案：** 在 `DBService` 中新增 `updateFollow(FollowUser follow)` 方法，该方法：
- 检查本地是否已存在相同 ID 的记录
- 如果存在且本地 shareUrl 有效而同步数据为空，则保留本地 shareUrl
- 调用 `followBox.put()` 写入数据

**替代方案：**
- 方案 A：修改所有同步代码，在 put 之前手动检查 shareUrl
  - 缺点：代码重复，容易遗漏
- 方案 B：修改 `addFollow` 方法用于同步场景
  - 缺点：`addFollow` 语义上用于"添加"，用于同步不够清晰

**选择理由：** 封装到独立方法可以：
- 集中管理 shareUrl 保护逻辑
- 清晰的语义（`updateFollow` 用于更新/同步场景）
- 便于未来维护和扩展

### 决策 2：修改 3 个同步点使用新方法

修改以下位置使用 `DBService.updateFollow()`：
- `sync_service.dart:259`
- `remote_sync_webdav_controller.dart:260`
- `remote_sync_room_controller.dart:132`

## 风险 / 权衡

**风险 1：同步数据冲突**
- 如果用户在不同设备上分别关注同一主播，可能产生数据冲突
- **缓解措施：** 保持现有"云优先"或"本地优先"策略不变，只保护 shareUrl 字段

**风险 2：TV 版本遗漏**
- TV 版本有独立的 `db_service.dart` 和 `sync_controller.dart`
- **缓解措施：** 同步修改 TV 版本的对应代码

## 开放问题

无
