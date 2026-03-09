## 上下文

Flutter 默认生成的 APK 文件名为 `app-release.apk` 或 `app-debug.apk`，不利于分发和品牌识别。

## 目标 / 非目标

**目标：**
- 修改 `flutter build apk --release` 输出的 APK 文件名为 `live_cover_by_me.apk`
- 保持构建配置简单，不引入额外脚本

**非目标：**
- 修改 APK 内部结构或签名配置
- 为不同 flavor 配置不同文件名

## 决策

### 决策 1：在 build.gradle.kts 中使用 `applicationVariants.all` 配置输出文件名

**选择**：在 `android` 块中添加 `applicationVariants.all` 配置

**理由**：
- Gradle 原生支持，不需要额外脚本
- 配置简单，易于维护
- 适用于所有构建变体

**替代方案**：
1. **使用 Flutter 的 `--output` 参数**：需要每次构建时手动指定
2. **使用构建后脚本重命名**：增加复杂度，可能失败

## 风险 / 权衡

| 风险 | 缓解措施 |
|------|----------|
| Gradle 配置错误导致构建失败 | 测试构建命令，确保语法正确 |
| Flutter 升级可能影响配置 | 记录配置位置，便于未来调整 |
