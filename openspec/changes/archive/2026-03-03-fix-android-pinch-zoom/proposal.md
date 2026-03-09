## 为什么

安卓端双指缩放在全屏模式下完全失效，导致用户无法在全屏观看直播时进行缩放操作。问题根因是 `Video` widget 内部的 `GestureDetector` 覆盖层拦截了触摸事件，导致 `InteractiveViewer` 无法接收到双指捏合手势。

## 变更内容

- **修改**：在 `player_controls.dart` 中的两个 `GestureDetector`（`buildFullControls` 和 `buildControls`）添加 `behavior: HitTestBehavior.translucent`，使触摸事件能够穿透到 `InteractiveViewer`
- **修改**：在 `GestureDetector` 中添加 `onScaleStart`、`onScaleUpdate`、`onScaleEnd` 回调（如方案 A 无效时的备选方案）

## 功能 (Capabilities)

### 新增功能
<!-- 引入的新功能。将 <name> 替换为 kebab-case 标识符（例如：user-auth, data-export）。每个功能将创建 specs/<name>/spec.md -->
- 无

### 修改功能
<!-- 现有功能，其需求发生变更（不仅仅是实现）。
     仅当规范级行为发生变更时才在此列出。每个都需要一个增量规范文件。
     使用项目目录中 specs/ 的现有规范名称。如果没有需求变更，请留空。 -->
- 无

## 影响

- **受影响的文件**：
  - `simple_live_app/lib/modules/live_room/player/player_controls.dart`
- **受影响的平台**：Android（主要）、iOS（可能）
- **依赖项**：无新增依赖
- **风险**：低 - 仅修改手势事件处理行为，不影响其他功能
