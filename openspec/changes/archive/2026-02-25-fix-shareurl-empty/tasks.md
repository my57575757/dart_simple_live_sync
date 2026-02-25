## 1. 修改 DBService.addFollow 方法

- [x] 1.1 在 `simple_live_app/lib/services/db_service.dart` 的 `addFollow` 方法中添加判断逻辑：如果已存在记录且原 shareUrl 非空，而新 shareUrl 为空，则保留原值
