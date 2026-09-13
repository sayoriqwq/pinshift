# Pinshift 使用与审计指南

这份指南面向已经完成 [首次使用与配置](docs/getting-started.md) 的用户。Apple 账号、首次安装与续签排错见 [签名教程](docs/apple-signing.md)。

以下命令在已进入工具环境的仓库根目录执行。使用 `./bin/pinshift` 明确调用当前仓库；若已配置 direnv，确认命令来源后也可省略 `./bin/`。测试期间需要保持终端窗口运行。

## 用户只需要记住的模型

> 运行 `pinshift`，选一个地点并 Apply；它固定生效 3 分钟，也可随时点 Clear Now 真实解除。

- 没有时长设置。每次真正的新 Apply 都固定从头计时 3 分钟。
- 当前是否已有地点、立即解除是否失败、上一次响应是否丢失，都不能阻止选点或新 Apply。
- 活动期间选另一个地点并 Apply，新地点立即替换旧地点并重新计时。
- **Clear Now** 只是提前解除的便利按钮，不是完成一次使用的必需步骤。
- App 重连后，以当前 Mac 测试会话返回的状态替换本地显示。
- Mac 或 iPhone 不可达时，公开 `devicectl` 无法立即解除。失败会如实显示，前台会话保留责任并自动重试；恢复连接后也可再次点立即解除。

## 控制器更新

首次安装请先完成签名教程；以下用于更新已配置好的控制器：

```fish
./bin/pinshift setup
./bin/pinshift doctor
```

🛠️ 安装稳定签名控制器、移除旧常驻项，并执行只读环境检查。

安装器只发布稳定签名的控制器，不会注册或启动 LaunchAgent。升级旧版本时，它会停止并删除
`dev.sayori.pinshift.controller` 与旧 Cleanup Guardian 的精确 LaunchAgent 目标，并安全替换旧的前台
Controller Link。删除旧 lifecycle 文件前，已签名 candidate 会执行一次真实 `reset`；如果设备不可达或
Clear 失败，安装会明确失败且不会发布新二进制。Saved Locations、可信控制器身份和配对信任都会保留。

如果 macOS 显示 Keychain 窗口，输入登录密码并选择 **始终允许**。安装器不会删除或替换既有 TLS
身份；如果签名要求发生意外变化，它会在修改信任前停止。

## 配对

每次开始测试时运行：

```fish
./bin/pinshift
```

🔗 检查 App 签名、按需续签后启动前台 Controller Link；Ctrl-C 等待真实解除成功后退出。

已信任的 iPhone 在前台控制器启动后会自动重连。App 中应看到：

- `Local Network Permission`：已允许；
- `Controller Link`：已连接；
- `Automatic Clear`：每个地点 3 分钟后自动解除。

Injection Backend 和 Controller Link 都是当前诊断信息，不是操作门槛。只要已经选点，Apply 入口就保持
可用；尚未连接时，点击 Apply 会自动尝试连接。连接或后端当下确实不可用时，本次 Apply 会在有限时间内
明确失败，按钮仍然可用，用户可以直接重试或改选其他地点。

## 日常使用

### 选择并应用

1. 在主页顶部搜索、拖动地图，或点击地图下缘的收藏，准备待应用位置 B。经纬度输入在“更多”中。
2. 点“应用 3 分钟”，真实回执后才出现已应用位置 A。
3. 活动卡显示当前 A 和计划解除倒计时；倒计时归零不是解除成功。
4. 选择 B 后，A 和 B 同屏；点“改到这里 · 3 分钟”替换 A 并重新计时。
5. “换个地点…”直接聚焦顶部搜索；“回到当前地点”只把 B 恢复为 A，不发请求、不延时。

选点只改变 **Selected Location**，绝不会自动应用。**Applied** 表示 Mac 的 `devicectl` 后端确认了
请求；Pinshift 的新 Core Location 观测属于单独的 **Verified** 证据，不能代表所有 App 都会接受该位置。

### 提前解除

**Clear Now** 始终可见，即使界面没有活动模拟记录也可以主动请求解除。成功后显示 **Simulated Location cleared**。如果响应失败或丢失，
界面只提示未能确认，不会伪装成成功。恢复设备连接后可再次点 **Clear Now**；选点和新 Apply 不会被锁住。

后端 clear 成功也不承诺 iOS 立即产生一条新的物理位置回调。界面中保留的“最后观测位置”是历史证据，
不是当前模拟状态。

## 状态怎么理解

| 状态 | 含义 | 是否阻止新 Apply |
| --- | --- | --- |
| Selected Location | 只在 App 中选中了坐标 | 否 |
| Applied Simulation | 后端已确认设置临时地点 | 否 |
| Verified Simulation | Pinshift 收到匹配的新观测 | 否 |
| Apply outcome unknown | Apply 结果不确定，当前会话仍保留 3 分钟截止时间 | 否 |
| Clear failed | 自动或手动 clear 失败，可再次点 Clear Now | 否 |
| Simulated Location cleared | 后端已确认清除开发者位置模拟 | 否 |

运行中的 Mac 会话是唯一状态权威。App 重连后会用它的 snapshot 覆盖本地显示；不会重放旧的持久
Stop、延长或后台清理请求。

## 故障恢复

先运行只读检查：

```fish
./bin/pinshift doctor
```

🩺 检查 Xcode、iPhone、签名、控制器身份和设备服务，不修改系统设置。

常见路径：

- **已有前台会话**：回到原来的 `pinshift` 终端；要重开时先按 Ctrl-C 完成清理。重复启动会在清理前被拒绝，不会影响原会话的地点。
- **找不到 iPhone**：重新连接数据线，解锁手机，确认 Mac 与 iPhone 仍互相信任。
- **Controller Link 未连接**：确认 `pinshift` 的前台终端仍在运行；需要时重新启动并配对。
- **Apply 按钮不可用**：确认已经选点；Controller Link、活动或重试状态都不会禁用按钮。
- **本次 Apply 失败**：按界面显示恢复 Xcode/设备连接，然后直接重试或应用其他地点。
- **控制器源码已变化**：运行 `pinshift setup`，不要用 `swift run` 代替已签名控制器。
- **App 签名过期或安装未确认**：按终端提示恢复账号登录、设备连接和解锁，再运行 `pinshift`；日常恢复不需要选择额外参数。

需要紧急幂等解除时运行：

```fish
./bin/pinshift clear
```

🧹 直接执行一次真实 clear，不启动或恢复任何常驻服务。

## 签名续期

日常只运行 `pinshift`：它检查 App 签名，剩余不超过 24 小时时按需续签。需要单独维护时运行：

```fish
./bin/pinshift app
```

🔏 验证新 profile 并原位更新 Pinshift，不卸载 App。

需要立即刷新时使用：

```fish
./bin/pinshift app --force
```

♻️ 立即请求新 profile、验证并原位安装。

手机锁屏只导致启动验证延后；解锁后可运行：

```fish
./bin/pinshift app --launch-only
```

📱 不重新签名，只补做启动验证。

## 结束与恢复

正常 Ctrl-C 会先发起真实解除，失败继续留在前台等待设备恢复，成功后才退出。终端会显示明确的
再次中断强制退出提示；强制退出留下的未确认模拟不会被报告成已解除。下次显式运行 `pinshift`
会先尝试遗留清理，即使没有本地活动记录。失败不阻止新的合法 Apply。

Mac 睡眠期间不保证计时器执行；存活会话恢复运行后处理已到期责任。进程被杀、断电或终端直接
关闭后没有后台保证。不要把手机退出 Pinshift 当作结束模拟：Mac 仍按原期限处理解除。

历史功能验收步骤见 [验收清单](docs/evidence/spec-24-owner-acceptance.md)。它是开发阶段的检查记录，不是新用户安装前置要求；后续接受范围见 [坐标修复记录](docs/evidence/coordinate-semantics-fix.md)。

## 审计

确认旧常驻 authority 已移除：

```fish
launchctl print gui/(id -u)/dev.sayori.pinshift.controller
```

🔎 正常结果是找不到该服务；安装器不再注册 LaunchAgent。

测试期间检查唯一的前台 Controller Link：

```fish
pgrep -af '.build/controller/bin/pinshift-controller link serve'
```

🧭 只应在 `pinshift` 终端运行期间看到一个前台进程。

导出 Mac 侧诊断：

```fish
./bin/pinshift logs --copy-to .build/audit/(date +%Y%m%d-%H%M%S)
```

📦 复制脱敏诊断事件和元数据，不触发 Apply、Clear 或恢复操作。

历史真机验证记录保留在 [docs/evidence](docs/evidence/)；其中旧 Lease/Guardian 实验是历史证据，不是
当前产品协议。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `pinshift` / `pinshift start` | 检查签名、按需续签，再启动前台控制器；保持终端运行 |
| `pinshift clear` | 紧急执行一次真实 clear，不启动常驻进程 |
| `pinshift setup` | 首次安装或源码变化后更新稳定签名控制器，并移除旧常驻项 |
| `pinshift doctor` | 只读检查开发环境和控制器状态 |
| `pinshift app` | 签名临近到期时续签并原位安装 App |
| `pinshift app --force` | 立即请求新 profile、验证并原位安装 |
| `pinshift app --launch-only` | 不续签，只补做启动验证 |
| `pinshift logs --copy-to <目录>` | 导出 Mac 侧诊断包 |

原来的 `pinshift-start`、`pinshift-reset`、`pinshift-install` 等脚本继续作为兼容实现保留；日常使用
不再需要记住它们。`pinshift-controller` 是底层维护接口，不是普通测试入口。
