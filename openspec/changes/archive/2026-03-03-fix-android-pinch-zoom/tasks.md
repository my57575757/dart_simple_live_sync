## 1. 修改 GestureDetector 配置

- [x] 1.1 在 `buildFullControls` 的 `GestureDetector` 中添加 `behavior: HitTestBehavior.translucent`
- [x] 1.2 在 `buildControls` 的 `GestureDetector` 中添加 `behavior: HitTestBehavior.translucent`
- [x] 1.3 导入 `HitTestBehavior`（如果需要）

## 2. 验证与测试

- [ ] 2.1 在安卓设备上测试全屏模式双指缩放
- [ ] 2.2 验证非全屏模式双指缩放仍然正常工作
- [ ] 2.3 验证其他手势（点击、双击、拖拽）不受影响
- [x] 2.4 运行 `flutter analyze` 确保无静态分析错误

## 3. 修复手势提示条位置

- [x] 3.1 将手势提示条移到 `InteractiveViewer` 外部
- [x] 3.2 验证放大后提示条位置正确

## 4. 音量键缩放方案

- [x] 4.1 修改双击逻辑：放大时重置，1x 时进入/退出全屏
- [x] 4.2 添加 `volumeKeyZoom` 方法处理音量键缩放
- [x] 4.3 在 `handleKeyboardKey` 中添加音量键检测（全屏时）
- [x] 4.4 将手势提示条移到 `InteractiveViewer` 外部
- [x] 4.5 修改 `boundaryMargin` 允许拖拽
- [x] 4.6 移除 `smallWindowState` 限制，让全屏时能正常缩放
- [x] 4.7 修改 `Offstage` 为 `Visibility` 确保提示条正确显示

## 4. 添加 GestureDetector 缩放回调

- [x] 4.1 在 `GestureDetector` 中添加 `onScaleStart/Update/End` 回调
- [x] 4.2 实现增量缩放逻辑并转发给 `transformationController`

## 5. 使用 RawGestureDetector 避免手势冲突

- [x] 5.1 将 `buildFullControls` 的 `GestureDetector` 替换为 `RawGestureDetector`
- [x] 5.2 将 `buildControls` 的 `GestureDetector` 替换为 `RawGestureDetector`
- [x] 5.3 移除缩放手势识别器，让 `InteractiveViewer` 直接处理缩放

## 6. 使用 Listener 处理音量/亮度调节

- [x] 6.1 将 `player_controls.dart` 中的垂直拖拽改为 `Listener` 实现
- [x] 6.2 单击和双击由外层 `RawGestureDetector` 处理
- [x] 6.3 `Listener` 不参与 Gesture Arena，避免与 `InteractiveViewer` 竞争
