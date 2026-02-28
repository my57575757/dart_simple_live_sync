## 1. 核心缩放功能

- [x] 1.1 在 `player_controller.dart` 的 `PlayerStateMixin` 中添加 `TransformationController transformationController`
- [x] 1.2 在 `PlayerStateMixin` 中添加 `resetZoom()` 方法，重置缩放到 Matrix4.identity()
- [x] 1.3 在 `PlayerGestureControlMixin` 中添加 `onDoubleTapZoom(TapDownDetails details)` 方法，实现双击分流逻辑（放大时重置，否则全屏）
- [x] 1.4 在 `PlayerGestureControlMixin` 中添加 `onInteractionEnd()` 回调方法，限制缩放范围 1.0x - 4.0x
- [x] 1.5 在 `PlayerStateMixin` 中添加 `currentZoomScale` getter，从 TransformationController 读取当前缩放倍数

## 2. InteractiveViewer 集成

- [x] 2.1 修改 `live_room_page.dart` 的 `buildMediaPlayer()`，用 `InteractiveViewer` 包裹 `Video` 组件
- [x] 2.2 设置 `InteractiveViewer.minScale = 1.0` 和 `maxScale = 4.0`
- [x] 2.3 绑定 `TransformationController` 到 `InteractiveViewer`
- [x] 2.4 设置 `InteractiveViewer.boundaryMargin` 为视频边界
- [x] 2.5 修改 `player_controls.dart` 的 `GestureDetector.onDoubleTapDown` 调用 `controller.onDoubleTapZoom`
- [x] 2.6 修改 `player_controls.dart` 的 `buildControls()`（非全屏模式），同步添加 `InteractiveViewer`（通过 buildMediaPlayer 统一处理）
- [x] 2.7 修改 `live_room_page.dart` 的 `buildMediaPlayer()`，同步添加 `InteractiveViewer` 包裹

## 3. 平移功能

- [x] 3.1 在 `PlayerStateMixin` 中添加 `isZoomed` getter，判断当前缩放倍数是否大于 1.0x
- [x] 3.2 在 `InteractiveViewer` 中启用平移（默认已启用）
- [ ] 3.3 测试双指拖拽平移功能
- [ ] 3.4 测试鼠标拖拽平移功能（桌面端）

## 4. 键盘快捷键支持

- [x] 4.1 在 `live_room_page.dart` 中添加 `KeyboardListener` 包裹 InteractiveViewer
- [x] 4.2 创建 `FocusNode` 管理播放器焦点（`playerFocusNode`）
- [x] 4.3 在 `PlayerGestureControlMixin` 中添加 `handleKeyboardKey(KeyEvent event)` 方法，处理 +/- 键
- [x] 4.4 在 `PlayerGestureControlMixin` 中添加 `handleKeyboardKey(KeyEvent event)` 方法，处理方向键
- [x] 4.5 在 `PlayerGestureControlMixin` 中添加 `handleKeyboardKey(KeyEvent event)` 方法，处理 Home 键
- [x] 4.6 在 `PlayerGestureControlMixin` 中添加 `zoomBy(double step)` 方法，按步进值缩放
- [x] 4.7 在 `PlayerGestureControlMixin` 中添加 `panBy(double dx, double dy)` 方法，按偏移量平移

## 5. 缩放倍数提示 UI

- [x] 5.1 在 `PlayerStateMixin` 中复用 `showGestureTip` 和 `gestureTipText` 状态
- [x] 5.2 在 `PlayerGestureControlMixin` 中添加 `showZoomIndicator(double scale)` 方法
- [x] 5.3 在 `zoomBy()` 中调用 `showZoomIndicator` 更新提示
- [x] 5.4 在键盘缩放时调用 `showZoomIndicator`
- [ ] 5.5 测试提示 2 秒后自动消失

## 6. 状态管理和边界条件

- [x] 6.1 在 `PlayerGestureControlMixin` 中处理锁定状态：`lockControlsState` 为 true 时禁用缩放/平移（在 zoomBy/panBy 中）
- [x] 6.2 在 `PlayerGestureControlMixin` 中处理小窗模式：`smallWindowState` 为 true 时禁用缩放（在 zoomBy/panBy/showZoomIndicator 中）
- [x] 6.3 在 `live_room_controller.dart` 的 `resetRoom()` 方法中调用 `resetZoom()`
- [ ] 6.4 在 `live_room_controller.dart` 的 `onInit()` 中初始化焦点管理

## 7. 桌面端鼠标滚轮支持

- [x] 7.1 在 `InteractiveViewer` 外层包裹 `Listener` 组件
- [x] 7.2 实现 `onPointerSignal` 处理 `PointerScrollEvent`
- [x] 7.3 检测 `HardwareKeyboard.instance.isControlPressed`
- [x] 7.4 更新 `TransformationController` 实现 Ctrl+ 滚轮缩放

## 8. 测试和验证

- [ ] 8.1 测试移动端双指缩放（Android/iOS）
- [ ] 8.2 测试桌面端鼠标拖拽（Windows/macOS/Linux）
- [ ] 8.3 测试键盘快捷键（桌面端）
- [ ] 8.4 测试锁定状态下禁用缩放
- [ ] 8.5 测试小窗模式禁用缩放
- [ ] 8.6 测试切换直播间重置缩放
- [ ] 8.7 测试双击行为（放大时重置，否则全屏）
- [ ] 8.8 测试缩放边界限制（1.0x - 4.0x）
- [ ] 8.9 测试平移边界限制
- [ ] 8.10 测试缩放倍数提示显示和消失
