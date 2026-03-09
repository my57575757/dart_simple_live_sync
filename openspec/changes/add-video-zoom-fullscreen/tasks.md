## 1. 核心状态管理

- [x] 1.1 在 `LiveRoomController` 中添加视频缩放状态变量
  - 已在 PlayerController 中实现：`transformationController`、`isZoomed` getter、`currentZoomScale` getter
  - 最大缩放级别 4.0 已实现

## 2. PC 端手势实现

- [x] 2.1 在 `player_controls.dart` 中实现 PC 端双击处理逻辑
  - 双击时检查当前缩放状态
  - 如果已放大，恢复到 1.0
  - 如果未放大，切换全屏状态
- [ ] 2.2 在 `player_controls.dart` 中实现 PC 端鼠标拖拽逻辑
  - 双击时检查当前缩放状态
  - 如果已放大，恢复到 1.0
  - 如果未放大，切换全屏状态
- [x] 2.2 在 `player_controls.dart` 中实现 PC 端鼠标拖拽逻辑
  - 使用 `InteractiveViewer` 的 `panEnabled` 属性
  - 只有放大状态才允许拖拽
- [x] 2.3 在播放器视图中应用 `Transform` 变换
  - 已使用 `InteractiveViewer` 处理缩放和拖拽

## 3. 安卓端手势实现

- [x] 3.1 在 `player_controls.dart` 中实现安卓端双击处理逻辑
  - 与 PC 端使用统一的 `onDoubleTapZoom` 方法
- [x] 3.2 在 `player_controls.dart` 中实现安卓端触摸拖拽逻辑
  - 使用 `InteractiveViewer` 的 `panEnabled` 属性
- [x] 3.3 处理与亮度/音量手势的冲突
  - 放大状态下禁用亮度/音量手势，优先处理画面拖拽

## 实现完成

### 已完成
- [x] 1.1 在 `LiveRoomController` 中添加视频缩放状态变量
- [x] 2.1 在 `player_controls.dart` 中实现 PC 端双击处理逻辑
- [x] 2.2 在 `player_controls.dart` 中实现 PC 端鼠标拖拽逻辑
  - 使用 `InteractiveViewer` + `Obx` 响应式控制 `panEnabled`
  - 添加 `isZoomedState` 响应式变量
- [x] 2.3 在播放器视图中应用 `Transform` 变换
- [x] 3.1 在 `player_controls.dart` 中实现安卓端双击处理逻辑
- [x] 3.2 在 `player_controls.dart` 中实现安卓端触摸拖拽逻辑
- [x] 3.3 处理与亮度/音量手势的冲突
- [x] 4.1 确保缩放状态与全屏状态正确协调

### 问题修复
- [x] 修复全屏时无法拖拽的问题
  - 放宽全屏模式下手势区域判断（15%-85%）
- [x] 修复控制层随画面缩放的问题
  - 将 `playerControls` 移到 `InteractiveViewer` 外部
  - 控制层不再随画面缩放和拖拽
- [x] 修复拖拽边界问题
  - 增大 `boundaryMargin` 从 100 到 1000

### 待手动测试
- [ ] 4.2 测试横屏/竖屏切换时的缩放行为（手动测试）
- [ ] 5.1 测试 PC 端双击缩放和全屏切换（手动测试）
- [ ] 5.2 测试 PC 端拖拽放大后的画面（手动测试）
- [ ] 5.3 测试安卓端双击缩放和全屏切换（手动测试）
- [ ] 5.4 测试安卓端拖拽放大后的画面（手动测试）
- [ ] 5.5 测试与弹幕、控制栏等其他功能的兼容性（手动测试）
- [ ] 5.6 性能优化，确保 Transform 不影响帧率（手动测试）
