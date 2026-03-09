## 上下文

当前播放器使用 `media_kit_video` 包提供视频播放功能，已有基础的手势处理（`onDoubleTapDown`、`onTap` 等）。但双击功能未实现画面缩放和全屏切换的完整逻辑。

现有代码结构：
- `player_controls.dart` - 播放器 UI 控件，包含手势事件绑定
- `player_controller.dart` - 播放器控制器，处理业务逻辑
- 使用 `GestureDetector` 处理触摸事件
- PC 端使用 `MouseRegion` 处理鼠标事件

## 目标 / 非目标

**目标：**
- 实现 PC 端和安卓端的双击手势控制（缩放 + 全屏）
- 实现放大后的画面拖拽移动
- 保持与现有播放器控制逻辑的兼容性
- 不破坏现有的弹幕、亮度/音量调节等功能

**非目标：**
- 不支持捏合缩放（pinch-to-zoom）
- 不支持键盘快捷键控制缩放
- 不修改 TV 版本（TV 版使用不同的播放器实现）

## 决策

### 决策 1：使用 Flutter 内置 GestureDetector 处理手势

**方案：** 使用 `GestureDetector` 的 `onDoubleTap`、`onDoubleTapDown` 处理双击事件，使用 `onPanUpdate` 处理拖拽事件。

**替代方案：**
- 方案 A：使用第三方手势库（如 `gesture_touch`）
  - 缺点：增加依赖，学习成本
- 方案 B：使用 `Listener` 处理原始指针事件
  - 缺点：需要手动实现双击检测逻辑，复杂度高

**选择理由：** Flutter 内置的 `GestureDetector` 已经提供了完善的手势识别，且现有代码已在使用。

### 决策 2：画面缩放使用 Transform 实现

**方案：** 使用 `Transform.scale` 和 `Transform.translate` 组合实现画面缩放和位移。

**替代方案：**
- 方案 A：修改 `media_kit_video` 的渲染参数
  - 缺点：需要深入理解 media_kit 内部实现，可能影响稳定性
- 方案 B：使用 `ClipRect` + `Transform` 组合
  - 缺点：增加布局复杂度

**选择理由：** `Transform` 是 Flutter 标准的变换方式，性能好且易于实现。

### 决策 3：缩放状态管理

**方案：** 在 `LiveRoomController` 中添加以下状态：
- `videoScale` (double) - 当前缩放级别（1.0 = 原始大小，2.0 = 200%）
- `videoOffset` (Offset) - 画面偏移量
- `isFullscreen` (bool) - 全屏状态（已有 `fullScreenState`）

**选择理由：** 集中管理状态便于协调缩放和全屏逻辑。

### 决策 4：双击逻辑优先级

**方案：** 
1. 双击时首先检查当前缩放状态
2. 如果已放大（scale > 1.0），则恢复原始大小
3. 如果未放大（scale == 1.0），则切换全屏状态

**选择理由：** 符合用户直觉 - 先处理画面大小，再处理窗口状态。

### 决策 5：拖拽边界限制

**方案：** 拖拽时限制画面偏移量，确保不会出现空白区域。计算公式基于缩放级别和画面尺寸。

**选择理由：** 提供更好的用户体验，避免无效拖拽。

## 风险 / 权衡

**风险 1：与现有手势冲突**
- 现有代码有亮度/音量调节的垂直拖拽手势
- **缓解措施：** 拖拽时检查缩放状态，只有放大状态才允许水平/自由拖拽；或添加拖拽方向判断

**风险 2：PC 端和安卓端行为差异**
- PC 使用鼠标，安卓使用触摸
- **缓解措施：** 使用统一的 `GestureDetector`，Flutter 会自动处理平台差异

**风险 3：性能影响**
- Transform 操作可能影响渲染性能
- **缓解措施：** 使用 `RepaintBoundary` 优化重绘，限制最大缩放级别（如 400%）

## 开放问题

无
