## 上下文

当前 `DBService.addFollow()` 方法直接覆盖已有记录，不检查 shareUrl 是否有效。当用户从非关注入口（如历史记录、搜索）进入抖音直播间后再关注，会导致原有的有效 shareUrl 被空字符串覆盖。

## 目标 / 非目标

**目标：**
- 修改 `addFollow` 方法，在保存前检查：如果原记录已有有效 shareUrl 且新数据为空，则保留原值

**非目标：**
- 不修改其他入口的 shareUrl 传递逻辑
- 不修改 LiveRoomDetail 等数据模型

## 决策

在 `db_service.dart` 的 `addFollow` 方法中添加判断逻辑：
```dart
var existing = followBox.get(follow.id);
if (existing != null && existing.shareUrl.isNotEmpty && follow.shareUrl.isEmpty) {
  follow.shareUrl = existing.shareUrl;
}
```

## 风险 / 权衡

- **风险极低**：仅修改保存逻辑，不影响读取或展示
- **无需迁移**：现有数据不会被破坏，只是保存时保护有效值
