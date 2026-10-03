# Tablewise

面向德扑学习与教学的 SwiftUI iOS App。当前代码提供本地手动录入、连续场次、历史回放、结算与筹码账、本地权益和条件分析、范围假设编辑、基础统计及手动备份导出/恢复。不提供 GTO 求解、AI 服务、账号、付费或云端同步。

本仓库是当前应用源码快照，不代表已完成全部功能验收或 App Store 发布。未附带审核范围库，自动参考会显示未覆盖；用户可自行建立范围假设。最低系统和真机兼容性、正式签名及发布图标仍待验证或配置。

## 构建与运行

需要 macOS、完整 Xcode、可用 iOS 模拟器、XcodeGen 2.46 或更新版本和 Python 3。Swift 6 / SwiftUI，目标 iOS 17 起，无第三方 App 运行依赖。

```sh
./scripts/build.sh
./scripts/run-simulator.sh dev
# 紧凑屏幕设备
./scripts/run-simulator.sh compact
```

构建脚本从 `ios/project.yml` 生成 Xcode 工程并编译模拟器 Debug 版本。也可打开 `ios/Tablewise.xcodeproj` 使用 Xcode。运行脚本使用专用的 Tablewise Dev 或 Tablewise Compact 模拟器；默认开发 Bundle ID 为 `dev.tablewise.app`。

本地数据仅保存在设备中；卸载前请在应用内导出备份。`.build/` 和 `.local/` 是本地构建与运行状态，不属于应用源码。
