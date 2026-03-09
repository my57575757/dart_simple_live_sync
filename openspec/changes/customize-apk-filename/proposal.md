## 为什么

默认情况下，`flutter build apk --release` 生成的 APK 文件名为 `app-release.apk`，不够直观且不利于分发。需要修改为具有辨识度的文件名 `live_cover_by_me.apk`。

## 变更内容

- **修改**：在 `simple_live_app/android/app/build.gradle.kts` 中添加配置，自定义 APK 输出文件名为 `live_cover_by_me.apk`

## 功能 (Capabilities)

### 新增功能
- 无

### 修改功能
- 无

## 影响

- **受影响的文件**：
  - `simple_live_app/android/app/build.gradle.kts`
- **受影响的命令**：
  - `flutter build apk --release`
- **输出变更**：
  - 从 `app-release.apk` 变为 `live_cover_by_me.apk`
