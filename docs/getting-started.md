# 首次使用与配置

从刚克隆的仓库开始，依次完成：工具环境 → Apple 签名与首次手机安装 → Mac 控制器 → 配对 → 第一次应用。完成一次后，日常只需启动控制器；见 [使用指南](../GUIDE.md)。

本教程使用仓库自带的 Nix 环境和 `./bin/pinshift` 入口，不依赖维护者的 Home Manager、全局命令或旧工作目录。仓库当前仍有个人环境限制，尤其是固定 App 标识；遇到下述已知限制时，不代表你的配置操作有误。

## 1. 确认使用条件

| 项目 | 当前要求 |
| --- | --- |
| Mac | Apple Silicon；仓库的 flake 目前只提供 `aarch64-darwin` 环境 |
| Xcode | 完整 Xcode 27 工具链，包含 `devicectl device simulate location`；仅 Command Line Tools 不够 |
| macOS | 必须满足所安装 Xcode 的系统要求，见 [Apple 对照表](https://developer.apple.com/xcode/system-requirements) |
| iPhone | 开发者自有真机，可用数据线连接、解锁、信任 Mac 并启用开发者模式 |
| iOS | 工程最低部署目标是 iOS 18；这不是 iOS 18 起所有版本均经过定位后端验证的承诺，需由当前 Xcode 的设备支持与后续检查确认 |
| Apple 账号 | 在 Xcode 中登录自己的账号，用自己的开发团队签名；首次步骤见下一篇签名教程 |
| 网络 | 首次下载 Nix/Swift 依赖、Xcode 登录与签名需要联网；App 与 Mac 还需允许本地网络通信 |

当前维护者验证环境是 macOS 27、Xcode 27 与个人 iPhone；其他系统组合尚未全面验证。上海地图坐标转换也仅有当前环境的地标级证据，详见 [坐标修复范围](evidence/coordinate-semantics-fix.md)。

先安装完整 Xcode，打开一次，按界面完成许可与所需组件下载。然后按 [Nix 官方 macOS 安装说明](https://nix.dev/install-nix) 安装 Nix，重新打开终端，确认 `nix --version` 能输出版本。无需安装 NixOS、nix-darwin 或 Home Manager。

## 2. 克隆并进入工具环境

```fish
git clone https://github.com/sayoriqwq/pinshift.git
cd pinshift
nix --extra-experimental-features 'nix-command flakes' develop --command fish
```

📦 克隆项目并进入提供 Fish、jq 和 XcodeGen 的终端环境；已克隆的用户只需进入自己的仓库路径，执行最后一行。

第一次会下载依赖，等待命令完成。此后的代码块都在这个 Fish 终端、仓库根目录执行。Swift 依赖会在首次构建时由 Swift Package Manager 获取，不需要再执行类似 `pnpm install` 的独立步骤。Nix 的行为见 [nix develop 官方说明](https://nix.dev/manual/nix/stable/command-ref/new-cli/nix3-develop.html)。

```fish
pwd
type -a fish jq xcodegen
./bin/pinshift help
```

🔎 确认目录、工具来源与仓库入口；此处只显示帮助，不安装或操作手机。

仓库入口默认使用 `/Applications/Xcode-beta.app/Contents/Developer`。若你的 Xcode 安装为 `Xcode.app`，在本次 Fish 会话设置：

```fish
set -gx PINSHIFT_DEVELOPER_DIR /Applications/Xcode.app/Contents/Developer
```

🧰 指定实际安装的完整 Xcode 路径；按你的安装位置修改，不改变系统全局 `xcode-select`。

```fish
env DEVELOPER_DIR="$PINSHIFT_DEVELOPER_DIR" xcodebuild -version
```

🔍 已显式设置该变量时，用这条命令核对选中的 Xcode；使用默认 Beta 路径时，把上一步的路径设为 `/Applications/Xcode-beta.app/Contents/Developer` 后再检查。

普通 `nix develop` 不会读取 `.envrc` 或 `.env.local`。自定义变量需在每次新会话设置；想自动加载可在首次流程完成后使用本文末尾的 direnv 方式。

## 3. 完成 Apple 签名与首次手机安装

现在打开 [Apple 账号、签名与首次真机安装](apple-signing.md)，完成到“返回主教程”为止。

**继续的条件：手机已经能打开从 Xcode 安装的 Pinshift，Mac 上已生成有效的开发签名证书。** 不要把 `pinshift app` 当作首次签名向导：当前脚本需要已有的 Pinshift provisioning profile 才能续签。

## 4. 安装 Mac 控制器并检查

保持 iPhone 数据线连接、解锁和信任状态。在前面的 Fish 环境执行：

```fish
./bin/pinshift setup
```

🛠️ 构建并签名仓库内的 Mac 控制器；安装过程中会执行真实 Clear 以清理遗留模拟，不是只读检查。

只有 setup 成功后才执行：

```fish
./bin/pinshift doctor
```

🩺 检查已安装控制器、Xcode、设备与身份；doctor 依赖已安装的控制器，不能作为干净克隆后的第一步。

安装产物位于本仓库 `.build/controller`。不要在日常使用期间把整个 `.build` 当缓存删除。若签名证书数量报错，见 [Mac 控制器签名](apple-signing.md#mac-控制器签名)。

## 5. 启动、配对并第一次使用

```fish
./bin/pinshift
```

🔗 检查 App 签名并按需续签，随后启动 Mac 前台会话；保留这个终端窗口。

打开手机上的 Pinshift，允许定位与本地网络权限。在“更多”的连接入口中，按提示使用 Mac 终端提供的六位码完成首次信任配对。同一台 Mac 的既有配对通常可复用。

搜索一个你认识的公开地点，确认地图上的待应用位置，再点“应用 3 分钟”。选择本身不会发起模拟，Apply 才会。可点“立即解除”提前结束；结束 Mac 会话时按 Ctrl-C，等待真实解除成功后退出。若设备不可达，保持会话并恢复连接；按提示强制退出期间没有后台清理保证。

后端 Apply/Clear 成功与其他 App 刷新位置是不同事实。第一次使用应同时确认连接状态、界面结果与实际使用体验，不以一张地图图钉作为所有 App 正常的证明。

## 6. 以后怎么启动、更新与迁移

新终端中进入仓库，重新执行第 2 步的 Nix 环境命令和必要的 Xcode 路径设置，再运行 `./bin/pinshift`。签名通常由日常入口按需维护；异常时看 [签名排错](apple-signing.md#常见问题)。

更新代码后，若提示控制器源码变化，重新执行 `./bin/pinshift setup`。需要把更新后的 iPhone 代码立即安装到设备时，执行 `./bin/pinshift app --force`；普通启动可能因现有签名尚有效而跳过 App 重建。命令细节见 [使用指南](../GUIDE.md)。

迁移仓库时保留自己的 `Config/Signing.local.xcconfig` 和按需使用的 `.env.local`，在新目录重新安装控制器；确认新入口可用后再删除旧目录。Git 克隆不会搬移钥匙串、证书、签名 profile 或手机数据。跨 Mac 迁移需要在新 Mac 重新完成签名和配对，不能只复制源码。

## 可选：用 direnv 自动进入环境

Nix 是上述教程的工具环境提供者；direnv 只是免去每次手动进入环境的便利层。

安装 [direnv](https://direnv.net/docs/installation.html)、配置对应的 [shell hook](https://direnv.net/docs/hook.html)，并安装启用 [nix-direnv](https://github.com/nix-community/nix-direnv#installation) 以支持仓库的 `use flake`。查看仓库 `.envrc` 后，在根目录执行：

```fish
direnv allow
type -a pinshift
```

🌱 授权本目录加载环境，确认命令列表第一项是当前仓库的 `bin/pinshift`。

首次出现 `.envrc is blocked` 是尚未授权；`cache invalidated` 后出现 `Renewed cache` 和 `export` 通常表示首次缓存建立完成。`use_flake: command not found` 则需检查 nix-direnv 是否启用。迁移路径后需重新授权。

使用此方式时，可把需要的覆盖项写进 Git 忽略的 `.env.local`，参考 [示例](../.env.example)。不需要的项保持注释；不要填假设备名称。此后在仓库内可直接使用 `pinshift`，无需个人全局入口。

## 卡住时先看这里

| 现象 | 下一步 |
| --- | --- |
| `nix` 找不到 | 完成 Nix 安装并重开终端；项目不会替你安装 Nix |
| 没有 `devShells.x86_64-darwin` | 当前 flake 不支持 Intel Mac，不是重新授权 direnv 能解决的问题 |
| `fish` / `jq` 找不到 | 重新进入 Nix 环境，不要跳过第 2 步直接调用脚本 |
| Xcode 路径不存在 / 没有所需 devicectl 子命令 | 检查完整 Xcode 的安装路径和版本，不能用 Command Line Tools 代替 |
| 没有配对手机 / 多台手机 | 连接、解锁并信任；多台时在会话设置 `PINSHIFT_DEVICE` 为实际设备名称或标识 |
| `No existing Pinshift app profile was found` | 返回签名教程，先从 Xcode 成功安装一次 |
| `Expected one valid code-signing identity` | 按签名教程创建或明确选择自己的开发证书 |
| 提示 App 准备未确认但控制器仍启动 | 不代表手机 App 已装好，先单独解决上方签名/安装错误 |

本文按当前源码与官方配置说明整理；尚未在没有维护者既有证书、工具和配对的全新 Mac 上完成端到端验证。
