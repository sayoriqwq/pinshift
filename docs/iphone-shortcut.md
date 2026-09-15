# 从 iPhone 准备使用 Pinshift

日常入口是独立的 iOS 快捷指令「准备使用 Pinshift」：在 Mac 按需检查签名、续签并原位安装，启动或复用前台 Simulation Controller，随后在 Pinshift 内选点并应用。即使 Pinshift 因签名过期打不开，快捷指令仍可作为恢复入口。

**条件：Mac 已开机、同一用户已登录、未睡眠，iPhone 能访问 Mac 的局域网地址。** 还需要 Xcode 能连接活动测试设备；仅 SSH 网络畅通不足以证明无线真机安装或位置模拟可用。本功能不负责开机、唤醒、无人登录、跨公网连接或自动应用地点。

## 1. 先完成一次本机使用

按 [首次使用与配置](getting-started.md) 完成 Apple 账号、开发签名、真机安装、控制器安装和 App 配对。在 Mac 运行一次 `pinshift`，确认 iPhone 能建立 Controller Link、应用并解除；然后在 Mac 终端按 Ctrl-C 等待正常解除完成。

SSH 密钥授权和 App 的 Trusted Controller 配对是两套独立授权。SSH 允许触发 Mac 准备操作；App 配对允许控制位置模拟。既有 App 配对不能代替下面的 SSH 配置。

## 2. 开启 Mac 远程登录

在「系统设置 → 通用 → 共享 → 远程登录」开启服务，在允许访问的用户中只选择实际运行 Pinshift 的已登录用户。记下界面显示的用户名和 Mac 地址。无需开启远程管理或远程 Apple 事件。设置路径和访问范围见 [Apple 远程登录说明](https://support.apple.com/en-au/guide/mac-help/mchlp1066/mac)。

初次配置在 Mac 前完成；若系统在运行时要求控制 Terminal、访问开发证书或解锁设备，按真实提示处理。不要用无人值守或常驻服务替代这个前台会话。

## 3. 创建 iPhone 专用密钥并限制授权

在 iPhone「快捷指令」中新建「准备使用 Pinshift」，添加「通过 SSH 运行脚本」（Run Script over SSH）。设置：

| 字段 | 内容 |
| --- | --- |
| 主机 | 上一步的 Mac 局域网地址或可解析的本地主机名 |
| 端口 | `22`（使用系统默认远程登录时） |
| 用户 | 上一步获准远程登录的 Mac 短用户名 |
| 认证 | SSH 密钥；在密钥设置中生成专用密钥并复制公钥 |
| 输入 | 留空 |

不同 iOS 版本的动作名称和密钥界面可能不同，以手机实际界面为准。只把**公钥**传到 Mac；不要导出私钥或把密码填入共享材料。首次连接如出现主机身份确认，应核实目标是自己的 Mac。

在 Mac 已配置的项目 Fish 环境内执行：

```fish
pinshift register-remote
```

🔧 生成本机专用 `~/.local/bin/pinshift-prepare-remote`，固定仓库、Nix 与开发工具路径和当前设备选择；先设置日常使用所需的 `PINSHIFT_DEVICE`、`PINSHIFT_DEVELOPER_DIR`，以及有多个签名身份时选用的 `PINSHIFT_CODE_SIGN_IDENTITY` 再注册。注册会捕获这些值，之后变更时需重新注册。

在 Mac 创建或打开授权文件：

```fish
mkdir -p ~/.ssh
touch ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
open -e ~/.ssh/authorized_keys
```

🔑 打开公钥授权文件，保留已有内容，在末尾添加下一段的一整行。将示例用户名替换为自己的绝对路径，将示例密钥类型和公钥内容替换为手机复制的真实公钥。

```text
restrict,command="/Users/YOUR_USER/.local/bin/pinshift-prepare-remote" ssh-ed25519 YOUR_IPHONE_PUBLIC_KEY pinshift-iphone
```

🔒 这是授权文件内容，不是终端命令；真实公钥类型以手机导出内容为准。不要把同一公钥额外添加成另一条无限制授权行。路径有空格等特殊字符时必须按 OpenSSH 的 `command` 引号规则处理，不能直接拼入。

固定入口只接受空请求或 `prepare`，其他命令或参数会被拒绝。快捷指令使用下面固定的 `prepare`，不要传入用户输入、剪贴板或分享表单内容。

授权行的 `restrict` 禁止端口、代理和 X11 转发、PTY 与用户 SSH rc；`command` 将这把密钥绑定到固定入口。不能只设置快捷指令中的脚本文本却给公钥无约束的 shell 权限。语义见 [OpenSSH authorized_keys 说明](https://man.openbsd.org/sshd.8#AUTHORIZED_KEYS_FILE_FORMAT)。这只约束该密钥，不改变其他密钥或系统密码登录设置。

## 4. 组装快捷指令

按顺序添加以下动作，作为可复用的最小配置：

1. **显示通知**：「正在连接 Mac，尚未确认准备完成」。这只是本地进度提示。
2. **通过 SSH 运行脚本**：使用上面的连接和密钥设置，脚本只填下一段的 `prepare`；等待该动作结束。
3. **显示结果**：选择上一步的「SSH 脚本结果」变量，完整显示 Mac 返回信息，保留 App 准备与控制器状态。
4. **可选：打开 App → Pinshift**。放在显示结果之后；不使用未经验证的 URL scheme，也不自动 Apply。

```text
prepare
```

📱 这是 SSH 动作的脚本文本；由 Mac 的强制命令转交固定准备入口，不需要在手机填写 Nix 或仓库路径。

Mac 的可见 Terminal 承载整个签名、安装和前台控制器流程。远程入口启动准备后最多等待约 30 秒检查 App 结果和控制器就绪；这不是 SSH 建连、Nix 环境加载也必定在 30 秒内完成的承诺。

等待结束仍未确认时，返回非零退出结果 `preparing/manual`。快捷指令保留系统错误提示，不继续打开 App，也不显示成功通知；**SSH 结束不会取消 Mac 终端中的工作，但未确认状态不能保证工作仍在运行。** 到 Mac 查看登录、解锁、授权提示，或稍后再次运行快捷指令。准备锁仍被当前请求持有时，重复请求只等待同一次准备结果；上一轮已结束后再次触发会按需重新检查签名并复用控制器。

快捷指令通常在 SSH 动作结束后才提供输出，不能把它当作逐行实时日志：手机最初显示的是「连接中」，返回的 `accepted` / `preparing` 信息描述 Mac 处理阶段。若 iOS 错误界面未显示完整诊断，到 Mac 查看可见终端及项目 `.build/pinshift-remote/preparation.log`；它保存 App 准备日志，不是手机 Controller Link 的验收记录。

选点可以随时进行；是否能应用，以 App 的真实 Controller Link 和本次 Apply 结果为准。即使快捷指令正常返回，跳过续签时也不能由缓存签名推断手机一定仍安装了 App，因此「打开 App」保持可选。

在快捷指令详情中选择「添加到主屏幕」，即可得到独立按钮；图标与名称可以自行修改，见 [Apple 主屏幕说明](https://support.apple.com/en-mt/guide/shortcuts/apd735880972/ios)。

分享快捷指令前去除自己的主机、用户名及密钥设置，让接收者填写自己的连接信息、生成密钥并在自己的 Mac 授权。

## 5. 日常使用与故障恢复

准备完成后，打开 Pinshift，确认 App 内真实 Controller Link 已连接，再选择地点并点「应用 3 分钟」。快捷指令不会自动 Apply。Mac 终端保留前台会话；快捷指令或 SSH 结束不应结束该会话。已有控制器会被复用，重复准备不应启动第二个会话或额外清理活动模拟。

结果应分别阅读：

- **`accepted` / `preparing`（请求已接收 / 准备中）**：Mac 已开始处理；不是可使用的完成信号。
- **`app`（App 准备结果）**：签名有效而跳过重建，或续签与原位安装确认成功；跳过重建不重新确认手机安装状态。
- **`controller-ready`（控制器可连接）**：本机确认前台控制器会话已就绪；仍需手机真实 Controller Link 验收。
- **`failed: preparation worker/controller stopped`**：准备锁已释放且控制器仍已停止；检查 Mac 终端与准备日志后重试，App 准备结果会单独显示。
- **`preparing/manual`（等待结束、尚未确认）**：约 30 秒的就绪等待已结束；Mac 可能仍在准备或等待人工步骤，不能宣称成功。稍后重试会检查当前请求。
- **`manual` / `failed`（需要人工处理 / 失败）**：查看具体阶段和设备指引；即使已有 `controller-ready`，`app` 失败仍会使请求以非零结果结束，不能掩盖 App 维护失败。

| 现象 | 处理 |
| --- | --- |
| SSH 无法连接、超时 | 检查 Mac 未睡眠、网络地址、远程登录、局域网和防火墙；请求未确认送达，不是准备成功 |
| SSH 认证失败 | 检查用户名、允许访问的用户、公钥及文件权限；不要改用共享密码绕过配置 |
| Apple 登录、证书或系统授权提示 | 到 Mac 按提示登录 Xcode、解锁钥匙串或完成本机授权，再重试 |
| 手机锁定、不信任或设备不可达 | 在 iPhone 解锁、信任 Mac，恢复数据线或已配置的 Xcode 无线连接 |
| 重复请求提示 preparing/manual | 等待或检查 Mac 的可见终端；准备锁存在时会观察同一次准备，不并发安装。若锁残留，先核实原 Terminal 中的准备进程及其签名/安装子进程均已结束，再手动移除 `.build/pinshift-remote/preparing` 空目录；不要因为手机超时就删锁 |
| 原会话正在退出 | 等待原 Mac 终端完成解除后再试；准备入口最多等待约 30 秒，不会强制中断清理 |
| Terminal 无法打开或自动化被拒绝 | 到 Mac 检查系统提示和权限；可手动运行 `pinshift` 恢复此次使用 |
| 控制器缺失或版本不符 | 在 Mac 的项目工具环境运行 `pinshift setup`；远程入口不会替你更新或安装控制器 |
| 续签或安装失败，但旧 App 仍可打开 | 保留现有能力，按 [签名排错](apple-signing.md#常见问题) 修复；不能把控制器运行当作 App 准备成功 |
| 快捷指令结束，App 仍无法连接 | 检查 Mac 可见终端及 App 本地网络权限、既有配对；SSH 成功不代表 Controller Link 成功 |

停止测试时，在 Mac 可见终端按 Ctrl-C，等真实 Clear 确认后退出。强制关闭、睡眠或断电期间没有后台清理保证；下次显式启动按现有流程恢复。

不再使用时，在 Mac 的 `~/.ssh/authorized_keys` 中只删除这把专用公钥所在行，并删除 iPhone 快捷指令；其他 SSH 用户仍有需要时不要关闭整个远程登录服务。迁移仓库或运行环境后应重新生成固定入口并更新授权路径，不要保留指向失效位置的命令。

## 首次运行后检查

1. 从 iPhone 运行快捷指令；若 Mac 弹出 Terminal、钥匙串或设备授权提示，按提示处理后重试。
2. 确认 Mac 出现前台终端，手机返回 `controller-ready`；随后打开 Pinshift，确认 Controller Link 已连接。
3. 选择一个测试地点并应用，确认 App 返回应用成功；需要提前结束时点击立即解除。
4. 再次运行快捷指令，确认仍能连接已有会话。若刚完成续签安装，重新打开 App 检查结果。
5. 配置成功后，按上面的步骤添加到主屏幕，作为日常入口。

如果 SSH 动作成功但 App 仍无法连接，按上方故障恢复表检查。Mac 必须保持已登录、未睡眠且网络可达；SSH 请求成功本身不能代替 App 的控制器连接和应用结果。
