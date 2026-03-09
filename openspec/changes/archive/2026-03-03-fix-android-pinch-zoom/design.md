## 上下文

当前 `simple_live_app` 使用 `InteractiveViewer` 实现双指缩放功能，包裹在 `Video` widget 外部。`Video` widget 的 `controls` 参数返回一个包含 `GestureDetector` 覆盖层的 widget 树，用于处理点击、双击、长按和垂直拖拽手势。

**问题**：在安卓设备上，非全屏模式下双指缩放正常工作，但在全屏模式下完全失效。

**根本原因**：
1. `GestureDetector` 在 `Video.controls` 中作为覆盖层存在
2. 虽然没有定义 `onScale*` 回调，但 `GestureDetector` 的默认 `behavior: HitTestBehavior.deferToChild` 仍会拦截触摸事件
3. Flutter 的 Gesture Arena 机制可能将双指手势误判为两个独立的单指拖拽事件
4. `InteractiveViewer` 无法接收到完整的双指捏合手势事件

## 目标 / 非目标

**目标：**
- 安卓全屏模式下双指缩放功能正常工作
- 保持现有手势处理逻辑（点击、双击、拖拽）不受影响
- 最小化代码改动，降低回归风险

**非目标：**
- 修改缩放倍数范围（当前 1.0x - 4.0x）
- 添加新的手势操作
- 修改 TV 端实现

## 决策

### 决策 1：使用 `HitTestBehavior.translucent` 让事件穿透

**选择**：在 `GestureDetector` 中添加 `behavior: HitTestBehavior.translucent`

**理由**：
- 最简单、侵入性最小的方案
- `HitTestBehavior.translucent` 允许事件穿透到下层 widget
- 不影响现有手势处理逻辑
- 可逆，易于回滚

**考虑过的替代方案**：
1. **添加 `onScale*` 回调并转发**：更复杂，需要维护额外代码
2. **移除 `GestureDetector` 覆盖层**：影响其他手势功能
3. **修改 `InteractiveViewer.boundaryMargin`**：可能无法解决根本问题

### 决策 2：同时修改 `buildFullControls` 和 `buildControls`

**选择**：在两个函数中的 `GestureDetector` 都添加 `behavior` 参数

**理由**：
- 保持一致性，避免未来出现类似问题
- 代码复用，维护成本低

### 决策 3：将手势提示条移到 `InteractiveViewer` 外部

**问题**：视频放大后，音量和亮度手势提示条位置偏移

**选择**：将手势提示条从 `Video.controls` 的 `Stack` 中移到 `buildMediaPlayer` 的顶层 `Stack` 中

**理由**：
- 手势提示条在 `InteractiveViewer` 内部时，使用 `Center` 定位
- 视频放大后，`InteractiveViewer` 的内容被变换，但 `Center` 仍以原始屏幕中心为基准
- 移到外部后，提示条始终在屏幕中心显示，不受缩放影响

### 决策 4：使用 `RawGestureDetector` 避免手势冲突

**问题**：`GestureDetector` 同时定义 `onVerticalDrag*` 和 `onScale*` 会导致手势竞争，垂直拖拽手势会"吃掉"双指缩放事件

**选择**：使用 `RawGestureDetector` 精确控制哪些手势识别器被注册，排除缩放手势识别器

**实现细节**：
- 替换 `GestureDetector` 为 `RawGestureDetector`
- 仅注册以下手势识别器：
  - `TapGestureRecognizer`：单击
  - `DoubleTapGestureRecognizer`：双击
  - `LongPressGestureRecognizer`：长按
  - `VerticalDragGestureRecognizer`：垂直拖拽
- **不注册** `ScaleGestureRecognizer`，让缩放事件穿透到 `InteractiveViewer`

**理由**：
- `RawGestureDetector` 提供对手势识别器的精确控制
- 避免 Flutter Gesture Arena 中的手势竞争
- `InteractiveViewer` 直接接收并处理双指缩放事件
- 保持其他手势功能不受影响

## 风险 / 权衡

| 风险 | 缓解措施 |
|------|----------|
| `HitTestBehavior.translucent` 可能导致其他手势冲突 | 测试所有现有手势（点击、双击、拖拽），如有问题回滚 |
| 仅修复安卓，iOS 可能出现不同行为 | 在 iOS 设备上测试，必要时单独处理 |
| `media_kit_video` 未来更新可能改变事件处理 | 记录此设计决策，便于未来排查 |
