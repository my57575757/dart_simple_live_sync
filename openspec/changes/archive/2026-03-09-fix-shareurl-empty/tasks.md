## 1. 核心方法实现

- [x] 1.1 在 `simple_live_app/lib/services/db_service.dart` 中创建 `updateFollow(FollowUser follow)` 方法
  - 检查本地是否已存在相同 ID 的记录
  - 如果本地 shareUrl 有效而同步数据为空，保留本地 shareUrl
  - 调用 `followBox.put()` 写入数据

## 2. 修改 App 端同步点

- [x] 2.1 修改 `simple_live_app/lib/services/sync_service.dart:_syncFollowUserReuqest()` 使用 `updateFollow()`
- [x] 2.2 修改 `simple_live_app/lib/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart:_recovery()` 使用 `updateFollow()`
- [x] 2.3 修改 `simple_live_app/lib/modules/sync/remote_sync/room/remote_sync_room_controller.dart:onReceiveFavorite()` 使用 `updateFollow()`

## 3. 修改 TV 端代码

- [x] 3.1 在 `simple_live_tv_app/lib/services/db_service.dart` 中创建 `updateFollow(FollowUser follow)` 方法
- [x] 3.2 修改 `simple_live_tv_app/lib/services/sync_service.dart` 使用 `updateFollow()`
- [x] 3.3 修改 `simple_live_tv_app/lib/modules/sync/sync_controller.dart` 使用 `updateFollow()`

## 4. 验证与测试

- [ ] 4.1 验证现有关注用户的 shareUrl 不被同步覆盖
- [ ] 4.2 测试从云端同步时 shareUrl 为空的情况
- [ ] 4.3 测试从云端同步时 shareUrl 有效的情况
