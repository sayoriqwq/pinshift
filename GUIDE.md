# Pinshift 使用与审计指南

这份指南面向当前这台 Mac 和已配对的 iPhone。首次配置完成后，日常使用不需要重新编译控制器、
重复输入 Keychain 密码，也不需要保持终端窗口运行。

## 用户只需要记住的模型

> 选一个地点并 Apply，它会临时生效 15 分钟；即使什么都不做，Pinshift 也会自动解除。

- 没有时长设置。每次真正的新 Apply 都固定从头计时 15 分钟。
- 当前是否已有地点、立即解除是否失败、上一次响应是否丢失，都不能阻止选点或新 Apply。
- 活动期间选另一个地点并 Apply，新地点立即替换旧地点；旧倒计时和旧 Clear 不能清掉它。
- **Clear Now** 只是提前解除的便利按钮，不是完成一次使用的必需步骤。
- App 重启或重连后，以 Mac 返回的当前状态替换本地显示。
- Mac 或 iPhone 不可达时，公开 `devicectl` 无法立即解除。Mac 会保留自动解除责任，在首次恢复可达时重试；用户操作仍保持可用。

## 首次安装或控制器更新

在仓库根目录运行：

```fish
direnv allow
pinshift-install
pinshift-doctor
```

🛠️ 安装稳定签名控制器与单一后台 authority，并执行只读环境检查。

安装器会启动 `dev.sayori.pinshift.controller` LaunchAgent。这个进程同时拥有 Controller Link、当前
临时地点状态和自动解除计时。升级旧版本时，安装器会停止并移除旧的 Cleanup Guardian LaunchAgent，
并精确停止旧 `pinshift-start` 留下的前台 Controller Link。Saved Locations、可信控制器身份和配对信任会
保留；旧 App 控制状态会被丢弃，旧 Mac 状态会先安全解除。

如果 macOS 显示 Keychain 窗口，输入登录密码并选择 **始终允许**。安装器不会删除或替换既有 TLS
身份；如果签名要求发生意外变化，它会在修改信任前停止。

## 配对

新 iPhone、App Keychain 被清除或需要刷新六位码时运行：

```fish
pinshift-start
```

🔗 重启后台 Controller Link、打印新的六位码，然后立即返回。

已信任的 iPhone 会自动重连，不需要每天运行 `pinshift-start`。App 中应看到：

- `Local Network Permission`：已允许；
- `Controller Link`：已连接；
- `Automatic Clear`：每个地点 15 分钟后自动解除。

Injection Backend 状态是当前诊断信息，不是历史状态门槛。只要 Controller Link 已连接，选点和 Apply
入口就保持可用；后端当下确实不可用时，本次 Apply 会明确失败，用户可以继续换点并重试。

## 日常使用

### 选择并应用

1. 打开 **Choose Location**。
2. 使用地图、地点搜索、经纬度输入或 Saved Locations 选择地点。
3. 点 **Apply Selected Location**。
4. 活动卡会显示权威自动解除时间和倒计时。
5. 想换地点时直接重新选点并 Apply；不需要先 Clear。

选点只改变 **Selected Location**，绝不会自动应用。**Applied** 表示 Mac 的 `devicectl` 后端确认了
请求；Pinshift 的新 Core Location 观测属于单独的 **Verified** 证据，不能代表所有 App 都会接受该位置。

### 提前解除

点 **Clear Now** 可以提前请求解除。成功后显示 **Simulated Location cleared**。如果响应失败或丢失，
界面只提示“未能确认，自动解除仍按计划执行”；选点和新 Apply 不会被锁住。

后端 clear 成功也不承诺 iOS 立即产生一条新的物理位置回调。界面中保留的“最后观测位置”是历史证据，
不是当前模拟状态。

## 状态怎么理解

| 状态 | 含义 | 是否阻止新 Apply |
| --- | --- | --- |
| Selected Location | 只在 App 中选中了坐标 | 否 |
| Applied Simulation | 后端已确认设置临时地点 | 否 |
| Verified Simulation | Pinshift 收到匹配的新观测 | 否 |
| Apply outcome unknown | Apply 结果不确定，Mac 仍持有原截止时间 | 否 |
| Automatic clear retrying | 已到截止时间，但设备暂时不可达或 clear 失败 | 否 |
| Simulated Location cleared | 后端已确认清除开发者位置模拟 | 否 |

Mac 是唯一状态权威。App 重连后会用 Mac snapshot 覆盖本地显示；不会重放旧的持久 Stop、延长或保护
确认请求，因为这些概念已经不再存在。

## 故障恢复

先运行只读检查：

```fish
pinshift-doctor
```

🩺 检查 Xcode、iPhone、签名、控制器身份和设备服务，不修改系统设置。

常见路径：

- **找不到 iPhone**：重新连接数据线，解锁手机，确认 Mac 与 iPhone 仍互相信任。
- **Controller Link 未连接**：确认后台服务状态；需要新配对码时运行 `pinshift-start`。
- **Apply 按钮不可用**：先确认已经选点且 Controller Link 已连接；活动或重试状态本身不会禁用按钮。
- **本次 Apply 失败**：按界面显示恢复 Xcode/设备连接，然后直接重试或应用其他地点。
- **控制器源码已变化**：运行 `pinshift-install`，不要用 `swift run` 代替已签名控制器。
- **App 签名过期**：运行 `pinshift-resign-app --force`；账号错误需要先恢复 Xcode 登录。

需要紧急幂等解除时运行：

```fish
pinshift-reset
```

🧹 暂停后台 authority、执行一次直接 clear，再恢复同一个后台 authority。

## 签名续期

Personal Team 签名剩余不超过 24 小时时运行：

```fish
pinshift-resign-app
```

🔏 验证新 profile 并原位更新 Pinshift，不卸载 App。

需要立即刷新时使用：

```fish
pinshift-resign-app --force
```

♻️ 立即请求新 profile、验证并原位安装。

手机锁屏只导致启动验证延后；解锁后可运行：

```fish
pinshift-resign-app --launch-only
```

📱 不重新签名，只补做启动验证。

## 审计

检查单一后台 authority：

```fish
launchctl print gui/(id -u)/dev.sayori.pinshift.controller
```

🔎 显示后台 Controller Link 与自动解除 authority 的运行状态。

查看持久状态的非敏感摘要：

```fish
jq '{
  schemaVersion,
  current: (
    .current
    | if . == null then null else {
        operationID,
        phase,
        automaticClearAt,
        retryAttempt,
        nextClearAttemptAt,
        lastClearFailure
      } end
  )
}' "$HOME/Library/Application Support/Pinshift/SimulationLifecycle/lifecycle.json"
```

🧭 `current: null` 表示 Mac 当前没有临时模拟；非空记录显示当前 operation 和自动解除进度。

导出 Mac 侧诊断：

```fish
pinshift-diagnostics --copy-to .build/audit/(date +%Y%m%d-%H%M%S)
```

📦 复制脱敏诊断事件和元数据，不触发 Apply、Clear 或恢复操作。

历史真机验证记录保留在 [docs/evidence](docs/evidence/)；其中旧 Lease/Guardian 实验是历史证据，不是
当前产品协议。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `pinshift-install` | 首次安装或源码变化后更新稳定签名控制器与后台 authority |
| `pinshift-start` | 需要配对时刷新后台进程并打印六位码；立即返回 |
| `pinshift-reset` | 紧急幂等 clear，并恢复后台 authority |
| `pinshift-doctor` | 只读检查开发环境和控制器状态 |
| `pinshift-resign-app` | 签名临近到期时续签并原位安装 App |
| `pinshift-resign-app --force` | 立即请求新 profile、验证并原位安装 |
| `pinshift-resign-app --launch-only` | 不续签，只补做启动验证 |
