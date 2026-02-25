## 为什么

当前关注列表中保存的 shareUrl 字段可能为空字符串，导致后续无法正确获取直播间详情。这是因为从非关注入口（历史记录、搜索等）进入直播间时 shareUrl 为空，保存关注时会覆盖掉原有的有效值。

## 变更内容

- 修改 `DBService.addFollow()` 方法，当原有关注用户已保存有效的 shareUrl，且新数据 shareUrl 为空时，保留原有的 shareUrl 不被覆盖

## 功能 (Capabilities)

### 新增功能
- `shareurl-preservation`: 修复 shareUrl 为空时覆盖有效值的问题

### 修改功能
（无）

## 影响

- `simple_live_app/lib/services/db_service.dart` - addFollow 方法
