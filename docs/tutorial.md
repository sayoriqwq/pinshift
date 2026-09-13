# 开发环境补充

新用户先读 [首次使用与配置](getting-started.md)；Apple 账号、Team、首次手机安装和续签集中在 [签名教程](apple-signing.md)。日常操作见 [GUIDE](../GUIDE.md)。本页只补充维护工程时需要的信息。

## 环境与入口

`flake.nix` / `flake.lock` 声明并锁定 Fish、jq、XcodeGen 的环境，目前仅提供 Apple Silicon macOS 输出。Swift 编译器来自完整 Xcode，Swift Package Manager 根据 `Package.swift` / `Package.resolved` 解析依赖。Nix 不安装 Xcode，也不创建 Apple 账号或设备签名。

`.envrc` 为可选的 direnv 集成，加载 `.env.local` 并将仓库 `bin` 加入 PATH。手动 `nix develop --command fish` 不执行 `.envrc`，需按首次教程设置必要的环境变量，并使用 `./bin/pinshift`。

## 工程与本地签名

仓库已提交 `Pinshift.xcodeproj`，普通使用无需生成工程。修改 `project.yml` 后，在 Nix 工具环境、仓库根目录执行：

```fish
xcodegen generate
```

🏗️ 重新生成 Xcode 工程；检查差异，避免提交自己的 Team 或设备配置。

本地开发团队配置放在 Git 忽略的 `Config/Signing.local.xcconfig`，由 `Config/Signing.xcconfig` 引入；首次教程说明了具体写法。直接在 Xcode 中编辑的项目设置可能在重新生成时丢失。

## 本地文件的职责

| 位置 | 用途 |
| --- | --- |
| `.env.local` | direnv 使用的可选路径、设备或证书覆盖项 |
| `Config/Signing.local.xcconfig` | 自己的开发团队配置 |
| `.build/controller` | 已签名控制器安装，不只是编译缓存 |
| `.build/resign-profile-backups` | 续签过程保留的恢复材料 |
| Mac Application Support 下的 Pinshift 数据 | 配对关联状态、会话及诊断数据，独立于 Git |
| iPhone App 数据 | 收藏、设置与本地诊断；升级应原位安装 |

移动仓库后重新安装控制器；在新入口验证完成前保留旧安装和必要配置。不要将整个 `.build` 或 App 数据一概当作无用缓存删除。历史实验与当前协议的区别见 [GUIDE](../GUIDE.md) 和 [ADR](adr/)。
