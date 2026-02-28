## 为什么

当前应用缺乏对直播画面的精细控制能力，用户无法放大查看画面细节（如游戏直播中的小地图、教学直播中的文字等），限制了观看体验。需要通过双指缩放和拖拽功能增强画面交互能力。

## 变更内容

- **新增**: 双指捏合缩放功能，支持 1.0x - 4.0x 缩放范围
- **新增**: 双指拖拽平移画面功能
- **新增**: 鼠标拖拽平移功能（桌面端）
- **新增**: 键盘快捷键支持（+/- 缩放，方向键平移，Home 重置）
- **新增**: 缩放倍数提示 UI（显示 2 秒后消失）
- **新增**: 放大状态下双击重置缩放
- **修改**: 双击行为逻辑（放大时重置，否则全屏）
- **新增**: 平移边界限制，画面不超出视频范围

## 功能 (Capabilities)

### 新增功能
- `pinch-zoom`: 双指缩放核心功能，包括缩放控制、倍数限制、状态管理
- `pan-control`: 画面平移控制，包括触摸/鼠标拖拽、边界限制
- `zoom-shortcuts`: 键盘快捷键支持，包括缩放、平移、重置快捷键
- `zoom-indicator`: 缩放倍数提示 UI，包括显示逻辑和动画效果

### 修改功能
- (无现有功能需求变更)

## 影响

- **代码**: 
  - `player_controller.dart`: 新增 `PlayerZoomMixin`，添加 `TransformationController` 和缩放相关方法
  - `player_controls.dart`: 修改 `buildFullControls` 和 `buildControls`，包裹 `InteractiveViewer`
  - `live_room_page.dart`: 修改 `buildMediaPlayer`，同步添加 `InteractiveViewer`
  - `live_room_controller.dart`: 切换直播间时重置缩放状态
  
- **UI**: 
  - 新增缩放倍数提示组件（类似现有亮度/音量提示）
  - 双击手势行为变更
  
- **交互**:
  - 锁定状态下禁用缩放/平移
  - 小窗模式禁用缩放
  - 切换直播间重置缩放状态
