## 上下文

当前应用使用 `media_kit` 作为视频播放内核，通过 `Video` 组件渲染画面。画面缩放模式（`scaleMode`）通过 `BoxFit` 枚举控制（适应、拉伸、铺满、16:9、4:3），但缺乏连续缩放能力。

现有手势交互：
- 单击：显示/隐藏控制器
- 双击：全屏/退出全屏
- 垂直滑动：调节亮度/音量
- 长按：显示关注列表
- 锁定状态：禁用所有手势

技术栈约束：
- Flutter 3.38
- GetX 状态管理
- media_kit_video 2.0.0 视频渲染

## 目标 / 非目标

**目标：**
- 实现 1.0x - 4.0x 连续缩放
- 支持双指触摸和鼠标拖拽平移
- 支持键盘快捷键操作
- 缩放倍数提示 UI
- 边界限制，画面不超出视频范围
- 与现有手势系统无缝集成

**非目标：**
- 不支持小于 1.0x 的缩小（画面不能比原始尺寸更小）
- 不支持小窗模式下的缩放
- 不支持记忆每个直播间的缩放偏好（后续功能）
- 不修改 media_kit 底层渲染逻辑

## 决策

### 1. 使用 InteractiveViewer 作为缩放/平移容器

**选择：** `InteractiveViewer` (Flutter 内置)

**替代方案：**
- 手动实现 `Transform + GestureDetector`
- 使用 `media_kit` 原生 mpv 缩放参数

**理由：**
- `InteractiveViewer` 内置双指缩放、平移、边界检测、弹性动画
- 减少手势冲突处理代码
- 性能优秀（GPU 加速 Transform）
- 代码量少，维护成本低

**风险：** `InteractiveViewer` 默认允许缩小到 < 1.0x，需要通过 `onInteractionEnd` 回调限制

### 2. 双击行为：基于缩放状态分流

**选择：** 检测当前缩放倍数，> 1.0x 时重置，否则全屏

**替代方案：**
- 保留双击全屏，使用三击重置
- 添加设置选项让用户选择

**理由：**
- 符合用户直觉（放大后双击恢复是常见模式）
- 减少手势复杂度
- 代码实现简单

### 3. 键盘快捷键映射

**选择：**
- `+` / `-` → 缩放增减（步进 0.5x）
- `方向键` → 平移画面（每次 50px）
- `Home` → 重置缩放和平移

**理由：**
- 符合桌面端用户习惯
- 与常见图片查看器一致
- 通过 `RawKeyboardListener` 实现，仅当播放器焦点时响应

### 4. 边界限制策略

**选择：** `InteractiveViewer.boundaryMargin` 设置为视频边界，配合自定义 `onInteractionEnd` 校验

**理由：**
- `InteractiveViewer` 内置边界检测
- 防止画面移出过多导致无法恢复

### 5. 缩放提示 UI 实现

**选择：** 复用现有的 `showGestureTip` / `gestureTipText` 状态和 UI 组件

**理由：**
- 保持 UI 一致性
- 减少新增代码
- 已有 2 秒自动消失逻辑（通过 `hideSeekTipTimer`）

## 风险 / 权衡

### 风险 1: InteractiveViewer 与 GestureDetector 手势冲突

**问题：** `InteractiveViewer` 可能拦截垂直滑动手势，影响亮度/音量调节

**缓解措施：**
- 测试手势优先级
- 如有冲突，使用 `GestureDetector` 包裹 `InteractiveViewer` 外层，通过 `HitTestBehavior` 控制
- 垂直滑动区域（屏幕中间 2/4）优先识别亮度/音量手势

### 风险 2: 桌面端鼠标滚轮缩放冲突

**问题：** 原生 `InteractiveViewer` 不支持 Ctrl+ 滚轮缩放

**缓解措施：**
- 外层包裹 `Listener` 监听 `onPointerSignal`
- 检测 `HardwareKeyboard.instance.isControlPressed`
- 手动更新 `TransformationController`

### 风险 3: 性能问题

**问题：** 直播场景下实时 Transform 可能掉帧

**缓解措施：**
- `InteractiveViewer` 使用 GPU 加速
- 避免在 `onInteractionUpdate` 中执行重计算
- 如发现问题，降级为仅支持缩放结束后的静态 Transform

### 风险 4: 键盘焦点管理

**问题：** 桌面端需要播放器获得焦点才响应快捷键

**缓解措施：**
- 使用 `FocusScope` 和 `FocusNode` 管理焦点
- 点击播放器区域自动获取焦点
- 提供视觉焦点指示（可选）

## 迁移计划

无数据迁移需求。纯 UI/交互增强功能。

部署步骤：
1. 合并代码
2. 全平台测试（Android/iOS/Windows/macOS）
3. 重点测试手势冲突场景
4. 回滚策略：如问题严重，回退 commit 即可（无数据变更）

## Open Questions

1. **键盘快捷键是否需要在移动端禁用？**
   - 当前设计：键盘事件自然仅在桌面端触发，无需特殊处理

2. 是否需要支持触摸板双指缩放（笔记本）？
   - `InteractiveViewer` 默认支持，待测试验证

3. 缩放步进值是否可配置？
   - 当前固定 0.5x 步进，后续可通过设置调整
