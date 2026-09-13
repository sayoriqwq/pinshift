# Apple 账号、签名与首次真机安装

这篇文档接续 [首次使用教程第 3 步](getting-started.md#3-完成-apple-签名与首次手机安装)。先准备完整 Xcode 和仓库工具环境，再操作本页。

Pinshift 的 iPhone App 需要用你自己的 Apple 开发团队签名。Mac 控制器也需要稳定的代码签名；App 与 Mac 之间的六位码信任配对是另一个步骤，在主教程中完成。

## 账号与免费签名

个人设备测试可使用 Xcode 中的个人 Apple 账号，通常显示为 Personal Team。Apple 当前说明该方式生成的设备 provisioning profile 有效期为 7 天；不等同于 App Store 分发资格。限制以 [Apple 开发账号说明](https://developer.apple.com/help/account/basics/about-your-developer-account) 为准。

无需为了本教程先购买开发者会员。仓库目前主要验证 Personal Team 的续签流程；其他团队类型未完成同等验证。

## 1. 登录 Xcode 并准备手机

1. 在 Xcode → Settings → Apple Accounts 添加自己的 Apple 账号，完成登录要求。
2. 用数据线连接并解锁 iPhone；按提示在 Mac 和手机上确认信任。
3. 按 Xcode 提示启用手机“设置 → 隐私与安全性 → 开发者模式”，重启并完成确认。若暂时看不到该入口，先让 Xcode 识别设备。

操作依据：[Apple 真机运行说明](https://developer.apple.com/documentation/xcode/building-and-running-an-app)、[开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)。

## 2. 打开工程，选择自己的 Team

在仓库根目录执行：

```fish
open Pinshift.xcodeproj
```

📱 打开已提交的 Xcode 工程；首次安装不需要先运行 XcodeGen。

在 Xcode 中选择项目的 **Pinshift app target**，打开 **Signing & Capabilities**：

- 开启 **Automatically manage signing**。
- Team 选择自己的 Personal Team 或开发团队，不能使用维护者的 Team ID。
- Scheme 选择 **Pinshift**，运行目标选择已连接的真实 iPhone，而非模拟器。

工程通过 `Config/Signing.xcconfig` 引入可选的本地文件。你也可以将自己的 Team ID 写入 `Config/Signing.local.xcconfig`，内容格式如下（替换占位值）：

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

🔏 这是配置文件内容，不是终端命令；文件被 Git 忽略，用于保存你自己的开发团队配置。

若通过 Xcode 界面选择 Team，Xcode 可能直接修改已跟踪的工程文件；这是本地配置变更，不应把自己的团队设置当作公共项目默认值提交。后续运行 XcodeGen 前应保留本地配置，避免生成工程时丢失 Team 设置。

### 当前限制：固定 Bundle Identifier

工程和安装/续签脚本目前使用固定的 `dev.sayori.pinshift`。如果 Xcode 报标识不可用、无法注册或签名失败，当前仓库还没有可直接配置的自定义 App 标识入口。

**不能只在 Xcode 中改 Bundle Identifier 就继续按本教程运行**：续签脚本仍会查找、验证和启动原标识，改一处会造成不一致。此问题需要项目支持统一配置标识后才能解决。请保留不含账号与设备隐私的错误信息向项目反馈；本教程不声称任意新 Apple 账号都已验证可安装。

## 3. 首次 Build & Run

点击 Xcode 的 Run，等待编译、自动签名、注册设备和安装完成；如有设备信任或开发者 App 信任提示，按 Xcode/iOS 的实际提示完成，再运行一次。

完成的标志是 **Pinshift 在真实 iPhone 上打开**。仅模拟器成功、仅编译成功或仅看见 provisioning profile，都不足以完成这一步。

这一步让 Xcode 生成 App 使用的证书和 profile。仓库的 `pinshift app` 是已有配置的续签入口：没有现存 Pinshift profile 时会明确退出，不会自动完成这次首次配置。

### 返回主教程

手机能打开 App 后，回到 [安装 Mac 控制器](getting-started.md#4-安装-mac-控制器并检查)。连接尚未建立是正常的，Mac 会话与六位码配对在后续步骤完成。

## Mac 控制器签名

控制器安装器自动选择钥匙串中的代码签名身份，但只在恰好有一个有效身份时自动继续。可在本机查看：

```fish
security find-identity -v -p codesigning
```

🔎 只列出可用于签名的身份，不修改证书；无需把完整输出贴到公开 Issue。

没有有效身份时，在 Xcode 的账号/团队证书管理入口检查或创建 Apple Development 证书，再确认首次 App 安装成功。多个身份时，在当前 Fish 会话明确指定要用的证书指纹：

```fish
set -gx PINSHIFT_CODE_SIGN_IDENTITY 'YOUR_CERTIFICATE_FINGERPRINT'
pinshift setup
```

🛠️ 将占位值换成上一步中自己有效证书的指纹，再重试安装；setup 会执行真实 Clear。

使用 direnv 时，可将同一覆盖项写入 Git 忽略的 `.env.local`。普通 Nix 会话不会自动读取该文件。

若 Keychain 弹窗要求授权，确认请求来自自己刚构建、签名的控制器后，按需授权。不要删除已有配对身份或改用临时未稳定签名的二进制来绕过问题。

## 日常续签

完成首次配置后，日常 `pinshift` 会检查已有 profile，剩余不超过 24 小时时按需续签。缓存仍有效时可能跳过重建；这不证明手机一定还安装着 App。

```fish
pinshift app --force
```

♻️ 需要主动更新 App 代码或补装时，请求新签名并原位安装；不卸载现有 App。

锁屏导致启动验证延后时，先解锁，再执行：

```fish
pinshift app --launch-only
```

📲 只补做启动，不重新签名。

## 常见问题

| 提示或现象 | 处理 |
| --- | --- |
| 没有 Team / 签名需要开发团队 | 登录 Xcode、选择自己的 Team，完成首次真机运行 |
| App 标识无法注册 | 查看本文“固定 Bundle Identifier”限制，不能单改 Xcode 标识后假定脚本兼容 |
| 找不到现存 Pinshift profile | 从 Xcode 成功运行原标识的 Pinshift 一次；确认使用同一 Mac/账号 |
| 多份 profile 的 Team 或 prefix 不一致 | 检查 Xcode 账号和签名来源；不要为绕过检查批量删除证书、profile 或钥匙串 |
| 账号认证失败 | 回到 Xcode Apple Accounts 恢复登录，再运行维护命令 |
| 未产生更晚的有效期 | 脚本不会把它记作续签成功，保留现有可用安装，检查 Xcode 返回的签名问题 |
| 安装未确认 / 手机锁屏 | 恢复连接与解锁后按脚本提示重试；不通过卸载 App 来排障 |

自己的 Team 配置、证书私钥、profile、设备标识与原始安装日志不应提交公共仓库。相同 Mac 上迁移源码可保留钥匙串与手机数据；更换 Mac 时要重新配置签名和配对。
