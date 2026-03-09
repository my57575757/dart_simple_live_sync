## 为什么

当前播放器缺少视频画面缩放和全屏切换的便捷操作方式。用户需要通过菜单或按钮进行操作，不够直观。添加双击和拖拽手势可以显著提升用户体验，让画面控制更加自然和高效。

## 变更内容

- 为 PC 端（Windows/macOS/Linux）添加视频画面双击手势控制
- 为安卓端添加视频画面双击和拖拽手势控制
- 实现画面缩放状态管理和全屏切换逻辑

## 功能 (Capabilities)

### 新增功能
- `video-zoom-gesture`: 视频画面缩放手势控制
  - PC 端：双击放大/恢复，拖拽移动放大后的画面
  - 安卓端：双击放大/恢复，拖拽移动放大后的画面
- `video-fullscreen-gesture`: 视频全屏切换手势控制
  - PC 端：未放大状态下双击切换全屏
  - 安卓端：未放大状态下双击切换全屏

### 修改功能

## 影响

- 受影响的代码：
  - `simple_live_app/lib/modules/live_room/player/` - 播放器控制组件
  - `simple_live_tv_app/lib/modules/live_room/player/` - TV 版播放器控制组件
- 依赖：可能需要引入手势识别相关的 Flutter 包（如 `gesture_touch` 或使用内置 `GestureDetector`）
- 平台差异：PC 端使用鼠标事件，安卓端使用触摸事件
