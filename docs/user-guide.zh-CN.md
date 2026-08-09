# Pinshift 使用说明

这份说明面向当前这台 Mac 和已配对的 iPhone。日常使用不需要重新编译控制器、输入
Keychain 密码或重复输入六位配对码。

## 每次开始使用

1. 连接并解锁 iPhone，确认手机已开启开发者模式。
2. 在终端进入仓库并启动控制器：

   ```fish
   cd /Users/sayori/Desktop/remote-location
   rl-start
   ```

3. 保持这个终端窗口运行，打开 iPhone 上的 **Pinshift**。
4. 等待 App 中的 Controller 与自动清理状态就绪：

   - `Local Network Permission`：`Allowed`
   - `Controller Link`：`Trusted controller connected`
   - `Active Test Device / Xcode`：`Ready`
   - `Injection Backend`：`devicectl ready`
   - `Automatic Cleanup`：`Cleanup Guardian ready`

终端显示新的六位码是正常的备用配对信息。已信任的 iPhone 会自动连接，不需要输入该码。

## 设置模拟地址

1. 在 App 中打开 **Choose Location**。
2. 在地图上移动到目标位置。
3. 点地图中央蓝色 `+`，把地图中心保存为 `Selected Location`。
4. 点右上角 **Done** 返回主页面。
5. 在 **Time-Bounded Simulation** 中选择 15、30 或 60 分钟；默认是 15 分钟，不提供无限时长。
6. 点 **Start Time-Bounded Simulation**。
7. Apply 成功后，使用会话卡查看清理时间、倒计时和自动清理保护。可在卡片中延长 15 分钟或立即恢复正常定位。
8. 打开 QQ、地图或其他目标 App 检查位置。Pinshift 的最新位置观察只是独立证据，不代表清理状态。

也可以使用地点搜索或手动输入经纬度。选择地址只会更新待选位置；只有点击
**Apply Selected Location** 才会真正修改系统提供给其他 App 的测试位置。

## 结束使用与自动清理

Apply 成功后可以不再进行任何操作。系统会在以下三个时刻中最早到达的一个进入同一清理流程：

- 会话卡显示的 15、30 或 60 分钟 Simulation Lease 到期；
- `rl-start` 正常退出；
- foreground server 崩溃或被强杀后，连续 30 秒收不到对应 server-owner heartbeat。

iOS App 进入后台或一次 Controller Link 网络断开不会触发 30 秒规则；只要 server 仍在持续写入心跳，
本次测试会继续到已确认的租约期限。

若要提前结束，在会话卡中点 **Return to Normal Location**。App 会先持久保存 Stop Intent；如果 Mac
暂时离线、Controller Link 正在重连，或 App 随后被关闭，同一请求会在恢复连接后自动重试，不需要
再次点击。只有 Mac 上公开的 `devicectl ... location clear` 成功后，界面才会显示
**Simulated Location cleared**。倒计时到零但尚未收到确认时，界面只会显示等待清理，不会假报成功。

`rl-install` 安装的 macOS Cleanup Guardian 由 launchd 独立保活。Apply 只有在 Guardian 报告健康并且
Cleanup Obligation 已持久保存时才会执行。如果整台 Mac 或 iPhone 暂时不可达，清理义务会保留；同一台
Mac 与 iPhone 恢复可达并解锁后，Guardian 会自动重试。iOS App 本身没有公开 API 可以执行这项开发者
服务清理，因此 Mac 关机且手机不可达期间无法完成清理，但也不会丢失清理义务。

手动恢复仍可运行：

```fish
cd /Users/sayori/Desktop/remote-location
rl-reset
```

## 首次配置或控制器代码更新后

正常情况下不需要运行这一节。首次配置，或终端提示
`The controller source changed after installation` 时，执行：

```fish
cd /Users/sayori/Desktop/remote-location
direnv allow
rl-install
```

如果 macOS 出现 Keychain 窗口，输入 Mac 登录密码并选择 **始终允许**。安装器会保留现有
控制器身份和手机信任；失败时会恢复旧的控制器与安装元数据。

## App 签名续期

Personal Team 签名临近到期时，连接或通过 Wi-Fi 保持 iPhone 可达，然后运行：

```fish
cd /Users/sayori/Desktop/remote-location
rl-resign-app
```

🔏 检查期限，并在剩余不超过 24 小时时自动续签、验证和原位安装。

命令不会卸载 App，因此会尽量保留本机收藏和设置。它只会暂存与 Pinshift bundle ID
完全匹配的旧 profile；开始安装前的构建或签名校验失败时会恢复旧 profile。安装请求发出后，
断连或超时无法证明手机端是否已经更新，因此命令会保留新 profile、候选 App 和私有诊断目录，
并明确提示结果不确定，不会伪装成已回滚。需要立即刷新时可运行 `rl-resign-app --force`。
如果手机锁屏，续签和安装仍可能完成；解锁后手动打开 App，或运行
`rl-resign-app --launch-only` 完成启动验证。

首次使用该命令前，Xcode 必须已经登录 Apple Account，并至少成功签名构建过一次。如果
Xcode 登录失效或要求双重验证，按命令提示在 **Xcode → Settings → Apple Accounts** 中完成。

## 检查环境

遇到无法连接、按钮变灰或手机不就绪时，先运行只读检查：

```fish
cd /Users/sayori/Desktop/remote-location
rl-doctor
```

按失败项给出的恢复提示处理。常见情况如下：

- **找不到 iPhone**：重新连接数据线，解锁手机，确认双方仍互相信任。
- **Controller Link 未连接**：确认 `rl-start` 的终端仍在运行，并保持 App 在前台片刻。
- **Apply 按钮为灰色**：先选择位置，并等待 Controller Link 与 Injection Backend 就绪。
- **控制器源码已变化**：运行一次 `rl-install`，不要改用 `swift run`。
- **App 无法启动或签名过期**：运行 `rl-resign-app --force`。如果提示 Xcode 账号失效，
  先在 Xcode 的 Apple Accounts 设置中重新登录，再重试。
- **换新手机或清除了 App Keychain**：运行 `rl-start`，把终端显示的当次六位码输入 App，
  只需重新配对一次。

## 常用命令

| 命令 | 用途 |
| --- | --- |
| `rl-start` | 启动可信控制器；默认运行一小时 |
| `rl-start --seconds 86400` | Controller Link 最长运行一天；App 中的 Simulation Lease 仍由 15/30/60 分钟选择决定 |
| `rl-reset` | 加入同一持久清理流程，幂等清除可能仍在生效的模拟位置 |
| `rl-doctor` | 只读检查 Xcode、iPhone、签名和控制器状态 |
| `rl-install` | 首次安装或源码变化后更新稳定签名控制器 |
| `rl-resign-app` | 签名剩余不超过 24 小时时续签并原位安装 App |
| `rl-resign-app --force` | 立即请求更新的 profile、验证并原位安装 |
| `rl-resign-app --launch-only` | 不续签，只在已解锁手机上完成启动验证 |
