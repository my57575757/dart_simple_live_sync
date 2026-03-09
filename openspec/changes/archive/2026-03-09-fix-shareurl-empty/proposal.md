## 为什么

shareUrl 在多处入口（历史记录、搜索结果、工具箱解析等）进入直播间时传入空值，导致关注用户的 shareUrl 字段偶尔为空，只有在后续同步操作后才能获取到正确值。这影响了抖音直播间链接的完整性和用户体验。

## 变更内容

- 调查 shareUrl 为空的具体场景和传播路径
- 修复同步功能中直接调用 `followBox.put()` 绕过 shareUrl 保护逻辑的问题
- 确保所有写入关注数据的地方都保留有效 shareUrl

## 功能 (Capabilities)

### 新增功能

### 修改功能
- `shareurl-preservation`: 增强 shareUrl 的获取逻辑，确保在首次进入直播间时就能获取并保存有效的 shareUrl，而不仅仅依赖于保存关注时的保留逻辑

## 影响

- 受影响的代码：
  - `simple_live_app/lib/routes/app_navigation.dart` - 导航参数传递
  - `simple_live_app/lib/routes/app_pages.dart` - 路由参数绑定
  - `simple_live_app/lib/modules/live_room/live_room_controller.dart` - shareUrl 使用和保存逻辑
  - `simple_live_app/lib/services/db_service.dart` - 关注数据保存逻辑
  - `simple_live_app/lib/services/follow_service.dart` - 关注列表同步逻辑
- 现有规范 `specs/shareurl-preservation/spec.md` 需要扩展，增加 shareUrl 获取时机的需求
