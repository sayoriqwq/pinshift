# Pinshift 使用与审计指南

这份指南面向当前这台 Mac 和已配对的 iPhone。它既说明日常怎么用，也说明如何确认一次位置模拟
最终真的进入了清理流程。首次配置完成后，日常使用不需要重新编译控制器、重复输入 Keychain 密码
或重新输入六位配对码。

## 先记住这四条

1. 每次 Apply 都有明确期限：15、30 或 60 分钟，默认 15 分钟，没有无限模式。
2. 不管 App 是否仍在前台，清理都由 Mac 上持久化的 Cleanup Obligation 和独立 Guardian 驱动。
3. 只有公开 `devicectl clear` 成功返回，Pinshift 才会把会话视为已停止；倒计时归零或网络断开都不等于已清除。
4. Mac 和目标 iPhone 都不可达时，任何公开接口都无法立即清理；义务不会丢失，会在两者恢复可达后继续重试。

## 日常使用

### 1. 启动

连接并解锁 iPhone，确认开发者模式已开启，然后运行：

```fish
cd /Users/sayori/Desktop/remote-location
rl-start
```

🚀 启动可信控制器；保持终端窗口运行，并在 iPhone 上打开 Pinshift。

等待 App 中以下状态就绪：

- `Local Network Permission`：`Allowed`
- `Controller Link`：`Trusted controller connected`
- `Active Test Device / Xcode`：`Ready`
- `Injection Backend`：`devicectl ready`
- `Automatic Cleanup`：`Cleanup Guardian ready`

终端显示新的六位码只是备用配对信息。已信任的 iPhone 会自动连接，无需再次输入。

### 2. 选择并应用位置

1. 打开 **Choose Location**。
2. 使用地图、地点搜索或经纬度输入找到目标位置。
3. 在地图模式下点中央蓝色 `+`，把地图中心设为 **Selected Location**，再点 **Done**。
4. 在 **Time-Bounded Simulation** 中选择 15、30 或 60 分钟。
5. 点 **Start Time-Bounded Simulation**。
6. 在活动会话卡中确认结束时间、剩余时间和自动清理保护状态。
7. 如有需要，点 **Extend 15 Minutes**，或点 **Return to Normal Location** 提前结束。

选点只会更新待应用位置，不会自动修改测试位置。后端 Apply 成功后，可以打开地图、QQ 或其他目标
App 检查效果；Pinshift 自己的最新位置观测只证明 Pinshift 看到了该坐标，不代表所有 App 都会接受它。

### 3. 结束

Apply 成功后，即使不再进行任何操作，系统也会在以下时刻中最早到达的一个要求清理：

- Simulation Lease 到期；
- `rl-start` 正常退出；
- 前台 server 崩溃或被强杀后，连续 30 秒没有对应 server-owner heartbeat。

iOS App 进入后台或一次 Controller Link 断开不会触发 30 秒规则；只要 server 仍持续写心跳，会话就会
继续到已确认的租约期限。

提前结束时，**Return to Normal Location** 会先持久保存 Stop Intent。即使 Mac 暂时离线、连接正在
重建或 App 随后退出，同一请求也会在恢复连接后自动重试，不需要再次点击。界面只有在 Mac 收到明确
clear acknowledgement 后才显示 **Simulated Location cleared**。

## 状态应该怎么理解

| 状态 | 含义 | 能否证明已经恢复正常定位 |
| --- | --- | --- |
| Selected Location | 只在 App 中选中了坐标 | 不能 |
| Applied Simulation | `devicectl` 已确认设置测试位置 | 不能，表示模拟可能正在生效 |
| Verified Simulation | Pinshift 收到了匹配的新 Core Location 观测 | 不能，只是 App 侧证据 |
| Cleanup Pending | 已要求清理，但还没有成功的后端确认 | 不能，应该等待或恢复设备连接 |
| Simulated Location cleared | `devicectl clear` 已成功确认 | 可以证明开发者位置模拟已被清除 |

停止后，界面可能仍显示“最后一次观测”的旧坐标。这是 Core Location 的历史观测，不代表模拟仍然活跃；
权威清理状态以 clear acknowledgement 为准。

## 首次配置或控制器更新

首次使用，或 `rl-start` 提示控制器源码已变化时，运行：

```fish
cd /Users/sayori/Desktop/remote-location
direnv allow
rl-install
rl-doctor
```

🛠️ 准备仓库环境、安装稳定签名控制器与 Cleanup Guardian，并执行只读健康检查。

如果 macOS 显示 Keychain 窗口，输入登录密码并选择 **始终允许**。安装器会保留现有控制器身份和
iPhone 信任；失败时会恢复旧控制器与安装元数据。

## 签名续期

Personal Team 签名临近到期时，让 iPhone 通过 USB 或 Wi-Fi 对 Xcode 可达，然后运行：

```fish
cd /Users/sayori/Desktop/remote-location
rl-resign-app
```

🔏 在剩余不超过 24 小时时续签、验证并原位安装 Pinshift。

命令不会卸载 App，因此会尽量保留收藏、设置和控制器信任。需要立即刷新时使用
`rl-resign-app --force`；如果手机锁屏导致启动验证延后，解锁后打开 Pinshift，或运行：

```fish
rl-resign-app --launch-only
```

📱 不重新签名，只在已解锁手机上补做启动验证。

Xcode 必须保持 Apple Account 登录。如果登录过期、需要双重验证或开发者协议有更新，请先在
**Xcode → Settings → Apple Accounts** 中完成交互。

## 故障恢复

先运行只读检查：

```fish
cd /Users/sayori/Desktop/remote-location
rl-doctor
```

🩺 检查 Xcode、iPhone、签名、控制器身份和设备服务，不修改系统设置。

常见恢复路径：

- **找不到 iPhone**：重新连接数据线，解锁手机，确认 Mac 与 iPhone 仍互相信任。
- **Controller Link 未连接**：确认 `rl-start` 仍在运行，并让 Pinshift 在前台停留片刻。
- **Apply 按钮不可用**：先选择位置，等待 Controller Link、Injection Backend 与 Cleanup Guardian 全部就绪。
- **控制器源码已变化**：运行 `rl-install`，不要用 `swift run` 代替日常控制器。
- **App 无法启动或签名过期**：运行 `rl-resign-app --force`；如有账号错误，先恢复 Xcode 登录。
- **更换手机或清除了 App Keychain**：重新运行 `rl-start`，输入当次六位码完成一次新配对。

需要手动加入同一持久清理流程时运行：

```fish
cd /Users/sayori/Desktop/remote-location
rl-reset
```

🧹 幂等请求清除可能仍在生效的模拟位置；失败时保留 Cleanup Pending 以便后续重试。

## 审计一次清理

### 快速检查

1. 在 App 会话卡确认是否显示 **Simulated Location cleared**，或仍处于 **Cleanup Pending**。
2. 检查 Guardian 是否由 launchd 保持：

   ```fish
   launchctl print gui/(id -u)/dev.sayori.remotelocation.cleanup-guardian
   ```

   🛡️ 显示 Cleanup Guardian 的当前 launchd 状态和最近退出结果。

3. 查看持久生命周期记录中的非敏感摘要：

   ```fish
   jq '{
     schemaVersion,
     active: (
       .active
       | if . == null then null else {
           phase,
           generationID,
           leaseExpiresAt,
           retryAttempt,
           nextRetryAt,
           lastFailure
         } end
     ),
     lastStoppedGenerationID
   }' "$HOME/Library/Application Support/Pinshift/SimulationLifecycle/lifecycle.json"
   ```

   🔎 `active: null` 表示 Mac 没有未完成的清理义务；非空记录应按 phase 和 retry 字段继续追踪。

4. 必要时导出 Mac 侧诊断包：

   ```fish
   rl-diagnostics --copy-to .build/audit/(date +%Y%m%d-%H%M%S)
   ```

   📦 复制脱敏的 Mac 诊断事件和元数据，不触发 Apply、Stop 或任何恢复操作。

Pinshift 内的 **Test Diagnostics** 可单独导出 iOS 侧记录。两侧记录通过 request ID、generation ID 和
时间线关联；不要把只有一侧的“请求已发送”当成 clear acknowledgement。

### 审计判定

- **通过**：同一 generation 最终有后端 clear success，持久记录不再有 active obligation，App 重连后显示已清除。
- **等待恢复**：状态为 Cleanup Pending，且日志显示 Mac、Xcode device service 或目标 iPhone 暂时不可达。
- **需要处理**：Guardian 未加载、持续崩溃，或恢复设备可达后仍反复出现相同非暂态错误。

本轮真机自动清理验证记录见
[eventual-cleanup-verification-2026-08-09.md](docs/evidence/eventual-cleanup-verification-2026-08-09.md)。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `rl-start` | 启动可信控制器；默认运行一小时 |
| `rl-start --seconds 86400` | 让 Controller Link 最长运行一天；不会延长 App 中选择的 Simulation Lease |
| `rl-reset` | 幂等请求清除模拟位置，并沿用持久重试流程 |
| `rl-doctor` | 只读检查开发环境和控制器状态 |
| `rl-install` | 首次安装或源码变化后更新稳定签名控制器与 Guardian |
| `rl-resign-app` | 签名临近到期时续签并原位安装 App |
| `rl-resign-app --force` | 立即请求新 profile、验证并原位安装 |
| `rl-resign-app --launch-only` | 不续签，只补做启动验证 |
