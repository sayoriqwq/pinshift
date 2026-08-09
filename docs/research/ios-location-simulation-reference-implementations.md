# iOS 位置模拟参考实现与可行性研究

研究日期：2026-07-27

状态：第一轮需求文档之前的技术调研

资料范围：Apple 官方文档、当前 Xcode SDK/CLI，以及开源项目的源码、许可证和项目自述

## 研究边界

本研究服务于个人设备上的开发测试：一台 Mac、一台自己的物理 iPhone、Developer Mode、Xcode 管理的测试会话，以及一个静态坐标。它不研究越狱、私有 iOS App API、规避第三方 App 的模拟位置检测、绕过服务规则或面向他人发布。

本文沿用项目领域语言：第一轮目标是实现 **Simulation Capability（模拟能力）**，并在 Pinshift 中得到 **Verified Simulation（已验证模拟）**。**Cross-App Propagation（跨 App 传播）** 是后续按 App 实测的结果，不是第一轮验收条件，也不能从“设备接受了模拟命令”直接推导出来。

## 结论

第一候选仍应是公开的 XCUITest API：在一个由 Xcode 启动、可持续接收命令的 UI Test Runner 中设置 `XCUIDevice.shared.location`，停止时赋值 `nil`。这不是只有文档示例的设想：Patrol 已经用公开 API 实现了远程 `set`/`clear`；另一个很新的 simpilot 项目甚至实现了“Mac CLI → HTTP → 物理设备上的 XCUITest Agent”这一近似拓扑。它们证明构件能组合起来，但没有替我们验证当前 iPhone、会话寿命和 Cross-App Propagation。

建议的技术路线是：

1. 先以 Apple 的 Xcode GPX 调试器作为基线，确认 Pinshift 能收到可识别的模拟位置。
2. 再做最小物理设备 XCUITest probe，验证静态坐标能反复 `set → replace → clear`，并维持足够长的测试会话。
3. probe 通过后，才把它接到 Mac Simulation Controller 和 iPhone Controller Link。
4. 保留 `InjectionBackend` 边界，但第一轮不实现第二个后端。
5. 只有公开 XCUITest 路径失败时，才把 DVT/Instruments 社区工具作为独立的可行性实验；不应先复制其逆向协议，也不应把它描述成 Apple 支持的公共 API。

当前没有证据足以承诺微信、高德地图或任意其他 App 会采用该坐标。Apple 只承诺 UI 自动化测试可以给设备设置 proxy location；社区的 DVT 测试能看到 `locationd` 的 Simulation 日志，但两者都不是某个第三方 App 的结果验证。

## Apple 官方能力与限制

### 公开 XCUITest API 是最小风险入口

Apple 将 [`XCUIDevice.location`](https://developer.apple.com/documentation/xcuiautomation/xcuidevice/location) 定义为测试使用的 proxy location，并给出 `XCUIDevice.shared.location = XCUILocation(...)` 的示例；没有 proxy 时测试使用 Core Location 提供的物理位置。当前 Xcode 26.6 的 iPhoneOS SDK 也在公开 `XCUIAutomation.framework` 头文件中声明该属性，标注 iOS 16.4+ 可用。对应的 [`XCUILocation`](https://developer.apple.com/documentation/xcuiautomation/xcuilocation) 包装 `CLLocation`。

Apple 的[测试位置模拟说明](https://developer.apple.com/documentation/xcode/simulating-location-in-tests)还区分了两件容易混淆的能力：

- Test Plan 的 Simulated Location 只改变测试 bundle 内运行的代码，不能自动改变另一个进程中的 UI 自动化目标 App。
- UI automation 应通过 `XCUIDevice.shared.location` 设置位置，Apple 的示例在设置后再启动 App。

因此，Test Plan 配置不是我们的 Injection Backend；UI Test Runner 才是正确候选。公开文档没有承诺这个 proxy 对所有其他 App 都可见，所以 Cross-App Propagation 仍必须后测。

### Xcode GPX 是基线和诊断工具，不是远程控制后端

Apple 明确说明 Xcode debugger 加载 GPX 可以产生软件模拟位置；Core Location 的 [`isSimulatedBySoftware`](https://developer.apple.com/documentation/corelocation/cllocationsourceinformation/issimulatedbysoftware) 会在这种系统软件模拟下为 `true`。[`CLLocation.sourceInformation`](https://developer.apple.com/documentation/corelocation/cllocation/sourceinformation) 也明确允许 App 对模拟位置区别对待或拒绝它。

这带来两个结论：

- GPX 是建立“当前设备和 Pinshift 的 Apple 路径确实工作”的最好基线。
- `isSimulatedBySoftware` 只是诊断信号，不能替代坐标、时间戳和精度验证，也不能保证第三方 App 会接受输入。

### Developer Mode 和个人签名足够个人开发，但有维护成本

Apple 的 [Developer Mode 文档](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)说明它用于允许通过 Xcode 构建、运行和调试开发签名软件；它不是赋予普通 iOS App 修改系统位置的 entitlement。Apple 也允许使用个人 Apple Account 在自己的设备上测试；[Personal Team 的 App ID、设备注册和 provisioning profile 会在 7 天后过期](https://developer.apple.com/support/compare-memberships/)，因此要接受周期性重新构建和安装。

### 官方 CLI 没有物理设备静态位置命令

本机 Xcode 26.6 的 `simctl location` 支持 `set`、`clear`、scenario 和路线，但 `simctl` 的目标是 Simulator。相同 Xcode 版本的 `devicectl` 顶层和 `device` 子命令没有 location/simulation 命令；当前物理设备报告的 CoreDevice capability 列表中也没有任意坐标模拟能力。因此不能把 `xcrun devicectl location ...` 当作一个尚未发现的第一方捷径。

### Controller Link 可完全使用 Apple 网络栈

Apple 的 [Network framework peer-to-peer 示例](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol)直接组合 Bonjour 与 TLS，适合作为 Controller Link 的协议参考。[TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)要求 iOS App 提供 `NSLocalNetworkUsageDescription`，浏览或注册 Bonjour 服务时声明 `NSBonjourServices`，并正确处理授权尚未决定、被拒绝和等待连接等状态。

这条链路与 Xcode 到设备的测试连接是两件事：iPhone Pinshift 通过 Bonjour/TLS 请求 Mac Simulation Controller；Mac 再驱动当前 Injection Backend。

## 社区参考实现源码审计

### 1. Patrol：公开 XCUITest 路径的最佳成熟参考

[Patrol](https://github.com/leancodepl/patrol) 是活跃的 [Apache-2.0 项目](https://github.com/leancodepl/patrol/blob/bd16eff2249cd307c99df47cb7b6e0474793705a/LICENSE)。其 iOS automator 在 iOS 16.4+ 直接使用公开 API [设置 `XCUIDevice.shared.location`，并通过赋值 `nil` 停止](https://github.com/leancodepl/patrol/blob/bd16eff2249cd307c99df47cb7b6e0474793705a/packages/patrol/darwin/patrol/Sources/PatrolImpl/AutomatorServer/Automator/IOSAutomator.swift#L923-L935)；上层 server 为两者注册了[独立的请求处理入口](https://github.com/leancodepl/patrol/blob/bd16eff2249cd307c99df47cb7b6e0474793705a/packages/patrol/darwin/patrol/Sources/PatrolImpl/AutomatorServer/MobileAutomatorServer.swift#L181-L189)。项目也有[物理 iOS 设备签名与测试说明](https://github.com/leancodepl/patrol/blob/bd16eff2249cd307c99df47cb7b6e0474793705a/docs/documentation/physical-ios-devices-setup.mdx#L1-L48)。

它对我们的帮助：

- 证明“长运行 Test Runner + 命令入口 + 公开 location set/clear”不是理论结构。
- `nil` 是公开 API 的明确清理动作，不需要私有 selector。
- 其物理设备文档提醒：失败后的诊断收集可能令 `xcodebuild` 卡住，doctor 和运行器应有超时、日志和明确的中断路径。

它没有证明：当前个人签名环境一定能稳定运行、Pinshift 会收到每次更新，或任何第三方 App 会采用该坐标。

### 2. simpilot：与目标拓扑最接近，但只能研究、不能复制

[simpilot](https://github.com/yoshi2ys/simpilot/tree/5bce1d8ca85bdb89e5105b8d013fc14d713d6665) 是 2026-07-27 检查时非常新的项目，项目自述支持[通过 XCUITest 控制 Simulator 和物理设备](https://github.com/yoshi2ys/simpilot/blob/5bce1d8ca85bdb89e5105b8d013fc14d713d6665/README.md#L1-L48)。它的 location handler 接受 JSON 坐标，然后[创建 `XCUILocation` 并写入 `XCUIDevice.shared.location`](https://github.com/yoshi2ys/simpilot/blob/5bce1d8ca85bdb89e5105b8d013fc14d713d6665/agent/AgentUITests/Handlers/LocationHandler.swift#L5-L23)。其物理设备 agent 使用 Network.framework listener，并要求非 loopback 监听必须配置 token；[这个约束在配置类型中集中维护](https://github.com/yoshi2ys/simpilot/blob/5bce1d8ca85bdb89e5105b8d013fc14d713d6665/agent/AgentUITests/Server/AgentConfig.swift#L3-L24)。

它对我们的帮助：

- 给出 Mac CLI 启动 Test Runner、将 session 参数传入 runner、定位物理设备 hostname 和向 runner 发命令的完整结构样本。
- 表明在 runner 内嵌一个小型 Network.framework server 是可探索方案。
- 它也暴露了我们需要避免的额外攻击面：如果 runner 在物理设备上监听所有接口，至少必须有每会话认证，最好让它只经受控通道通信。

限制很重要：检查时项目无声明许可证、几乎没有外部采用证据，而且 location handler 只有 set、没有 clear。默认应把未声明许可证视为不可复制；这里只借鉴问题分解，不搬运代码，也不把项目自述当成我们的真机验证结果。

### 3. WebDriverAgent：远程接口和生命周期参考，但 location 实现用了私有 XCTest daemon API

[Appium WebDriverAgent](https://github.com/appium/WebDriverAgent) 是 [BSD 许可](https://github.com/appium/WebDriverAgent/blob/6e54cb7fdd4d0ee7c40882b7947bf9ac4cd260bb/LICENSE)的成熟远程 XCUITest agent。它暴露 set/get/clear 三类[模拟位置 HTTP 路由](https://github.com/appium/WebDriverAgent/blob/6e54cb7fdd4d0ee7c40882b7947bf9ac4cd260bb/WebDriverAgentLib/Commands/FBCustomCommands.m#L529-L571)，很适合参考错误模型、幂等清理和 session 外命令。

但其当前实现并非只使用公开 `XCUIDevice.location`；它通过私有 `XCTRunnerDaemonSession` 调用 `setSimulatedLocation`、`getSimulatedLocation` 和 `clearSimulatedLocation`，[并检查 runtime 与 daemon 支持](https://github.com/appium/WebDriverAgent/blob/6e54cb7fdd4d0ee7c40882b7947bf9ac4cd260bb/WebDriverAgentLib/Utilities/FBXCTestDaemonsProxy.m#L187-L258)。因此：

- 可参考接口形状、错误处理、持续 runner 和清理流程。
- 第一版不应依赖它，也不应复制私有头或私有 selector。
- 它不能替代公开 API probe。

### 4. pymobiledevice3：现代 iOS DVT 路径最完整，但属于逆向开发服务

[pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 是活跃的 [GPL-3.0 项目](https://github.com/doronz88/pymobiledevice3/blob/b798aab4e66368c97d8f784d5d3204abbec60e4d/LICENSE)。它清楚地区分版本：

- iOS 17+ 通过 `com.apple.instruments.server.services.LocationSimulation` DTX channel，调用 [`simulateLocationWithLatitude:longitude:` 与 `stopLocationSimulation`](https://github.com/doronz88/pymobiledevice3/blob/b798aab4e66368c97d8f784d5d3204abbec60e4d/pymobiledevice3/services/dvt/instruments/location_simulation.py#L7-L47)。CLI 也明确将这条路径标为 [iOS 17+](https://github.com/doronz88/pymobiledevice3/blob/b798aab4e66368c97d8f784d5d3204abbec60e4d/pymobiledevice3/cli/developer/dvt/simulate_location.py#L11-L38)。
- iOS 17 以下使用 `com.apple.dt.simulatelocation`，其 [set/clear 二进制协议](https://github.com/doronz88/pymobiledevice3/blob/b798aab4e66368c97d8f784d5d3204abbec60e4d/pymobiledevice3/services/simulate_location.py#L8-L40)非常简单，但不适用于我们的当前 iOS。
- 项目记录了 iOS 17+ developer service 的 RSD/CoreDevice tunnel 要求及版本差异；它还发现 `com.apple.coredevice.locationservice`，但当前公开实现[只查询设备内置 location scenarios](https://github.com/doronz88/pymobiledevice3/blob/b798aab4e66368c97d8f784d5d3204abbec60e4d/pymobiledevice3/remote/core_device/location_service.py#L7-L23)，没有任意坐标 set/clear。

这说明 DVT 是公开 XCUITest 失败后的现实研究方向，但不是公共、稳定、文档化的 Apple API。GPL 源码也不应被复制进本项目；若未来只做可行性实验，优先把原工具当作独立进程运行，并单独记录版本、权限和许可证边界。

### 5. go-ios：MIT 许可的 DVT 对照实现和独立验证信号

[go-ios](https://github.com/danielpaulus/go-ios) 是活跃的 [MIT 项目](https://github.com/danielpaulus/go-ios/blob/274bc438a05e938ee55130dabf7f535408473387/LICENSE)。其 CLI 对支持 RSD 的设备选择 Instruments location service，否则使用旧服务，[版本分支在命令入口可见](https://github.com/danielpaulus/go-ios/blob/274bc438a05e938ee55130dabf7f535408473387/cmd_device_location.go#L11-L24)；DVT 实现使用与 pymobiledevice3 相同的 [channel 与 set/stop selector](https://github.com/danielpaulus/go-ios/blob/274bc438a05e938ee55130dabf7f535408473387/ios/instruments/location_simulation.go#L8-L49)。

最有价值的是它的真机 e2e 思路：由于没有 get-location 命令，测试通过观察设备自身 `com.apple.locationd.Core` / `Simulation` 日志来确认模拟活动，并在 SIGINT 时停止和恢复，[源码明确记录了这个验证边界](https://github.com/danielpaulus/go-ios/blob/274bc438a05e938ee55130dabf7f535408473387/test/e2e/tunnel/setlocation_test.go#L12-L35)。这可以作为 backend 诊断信号，但仍不能替代 Pinshift 的 Observed Location，更不能替代 Cross-App 测试。

### 6. idb：后端抽象值得借鉴，物理设备实现已偏旧

[Meta idb](https://github.com/facebook/idb) 是 [MIT 项目](https://github.com/facebook/idb/blob/2fd5e60b4eb0c8234a3e0f45a6075689a69d6601/LICENSE)。它为 Simulator 与物理设备提供同一个 [`LocationCommands` protocol](https://github.com/facebook/idb/blob/2fd5e60b4eb0c8234a3e0f45a6075689a69d6601/FBControlCore/Commands/LocationCommands.swift#L8-L13)，很符合我们的 `InjectionBackend` seam。Simulator 实现调用 CoreSimulator；物理设备实现挂载 Developer Disk Image 后连接 [`com.apple.dt.simulatelocation`](https://github.com/facebook/idb/blob/2fd5e60b4eb0c8234a3e0f45a6075689a69d6601/FBDeviceControl/Commands/FBDeviceLocationCommands.swift#L29-L48)。

物理实现只有 set、没有对称 clear，而且仍走旧服务；对当前 iOS 26.5.2 不应作为首选实现。可借鉴的是接口隔离，不是 backend 代码。

### 7. LocationSimulator 与 idevicelocation：UI 和历史协议参考，不是现代后端

[LocationSimulator](https://github.com/Schlaubischlump/LocationSimulator) 是流行的 [GPL-3.0 macOS GUI](https://github.com/Schlaubischlump/LocationSimulator/blob/09a1671704232e6a1840e12a5eb871be3b806f50/LICENSE)。它有地图长按选点、地点搜索、最近位置和显式 Reset，适合作为未来 UI 交互参考；但 README 在最前面明确写着 [iOS 17+ 当前不支持](https://github.com/Schlaubischlump/LocationSimulator/blob/09a1671704232e6a1840e12a5eb871be3b806f50/README.md#L1-L17)。不能因为项目知名就选择它的 backend。

[idevicelocation](https://github.com/JonGabilondoAngulo/idevicelocation) 是旧的 C 工具，使用 `com.apple.dt.simulatelocation` 并支持 stop；最后的源码提交非常旧且仓库无声明许可证。它只适合帮助理解旧协议历史，不进入候选清单。

## 候选方案比较

| 候选 | API/协议状态 | 物理 iPhone | 静态 set/replace/clear | 对其他 App 的证据 | 第一轮结论 |
|---|---|---:|---:|---|---|
| `XCUIDevice.shared.location` | Apple 公开 XCUITest API | 文档与 iPhoneOS SDK 支持，仍需本机 probe | API 支持 set 与 `nil` clear | 未承诺 | **首选 probe** |
| Xcode debugger + GPX | Apple 官方开发流程 | 支持 | 手工 set/stop | 未承诺 | **基线/诊断** |
| Test Plan Simulated Location | Apple 官方，但 test-bundle scoped | 支持测试 bundle | 可配置 | 明确不足以驱动独立 UI App 进程 | 排除为 backend |
| `simctl location` | Apple CLI | 仅 Simulator | 支持 | 不适用 | 只用于快速开发 |
| `devicectl` | Apple CLI | 支持设备管理 | 当前无 location 命令 | 无 | 排除为捷径 |
| DVT LocationSimulation | Apple 内部 developer service，社区逆向 | 社区项目支持 iOS 17+ | 社区实现支持 set/stop | 只有 `locationd` 活动信号 | 公开路径失败后的实验 |
| `com.apple.dt.simulatelocation` | 旧的未文档化服务 | 社区实现用于 iOS <17 | 支持 | 无当前系统证据 | 当前环境排除 |
| CoreDevice location service | 未文档化，社区初步实现 | 当前系统存在相关 service | 目前只看到 built-in scenarios 查询 | 无 | 观察，不依赖 |

## 推荐的第一轮 feasibility spikes

### Spike 0：doctor 与设备前置条件

只读检查应输出清楚的人类可操作状态：

- 完整 Xcode 路径、版本和 `xcode-select` 是否指向它。
- Xcode first-launch 是否完成。
- 物理设备是否 paired、available、Developer Mode enabled。
- Developer Disk Image 是否 compatible/usable。
- App 与 UI Test Runner 的 Personal Team 签名是否可用。
- 本地网络权限说明、Bonjour service type 和 Controller Link 状态。

失败时只给修复步骤，不自动执行 `sudo xcode-select`、重置设备或改变系统设置。

### Spike 1：Xcode GPX 基线

在 Pinshift 中请求 When In Use location，手工用 Xcode 设置一个静态 GPX 点。通过条件：15 秒内收到与 Selected Location 相距不超过 25 米的新 `CLLocation`；同时记录 timestamp、horizontalAccuracy 和 `sourceInformation?.isSimulatedBySoftware`，但模拟标志不参与唯一通过判定。停止模拟后确认真实位置更新能够恢复。

### Spike 2：公开 XCUITest 最小 runner

只实现一个 UI test target 和极小命令循环，不先接地图、Bonjour 或配对。验证顺序：

1. 设置坐标 A，Pinshift 得到 Verified Simulation。
2. 不重启会话，替换为坐标 B，再次得到 Verified Simulation。
3. 设置 `XCUIDevice.shared.location = nil`，确认模拟停止。
4. 重复以上循环，保持会话至少 10 分钟，记录 runner/xcodebuild 的退出和超时行为。
5. 全程只导入公开 XCTest/XCUIAutomation/CoreLocation API；构建产物不得包含 WebDriverAgent 的 private headers 或 DVT selector。

这个 spike 的通过只能证明 Pinshift 和当前设备组合可行。

### Spike 3：最小 Controller 串接

probe 通过后再加入：

- iPhone Pinshift 使用 MapKit 选择一个静态坐标。
- App 通过 Bonjour/TLS 向 Mac Simulation Controller 发送 request。
- Mac Controller 通过每会话认证的内部通道把 request 交给 Test Runner。
- Controller 返回 Applied Simulation；Pinshift 的 Core Location 观察再将它提升为 Verified Simulation。
- 正常退出和显式 `reset` 都调用 clear；断线自动恢复不作为第一轮能力。

不要直接照搬 simpilot 的明文全接口 listener。内部 runner 通道可以从其 session-token 思路借鉴，但是否采用 device listener、runner 主动连接 Mac，或 Xcode 现有 transport，需要在 spike 中以最小暴露面决定。

### Spike 4：仅在公开 API 失败时进行 DVT 对照

先用未改动的 `go-ios` 或 `pymobiledevice3` 可执行工具在自己的设备上做一次 set/stop 对照，记录：当前 iOS/Xcode 版本、tunnel/DDI 前置条件、是否出现 `locationd` Simulation 日志、Pinshift 是否达到相同 Verified Simulation，以及退出后是否可靠恢复。这个实验不复制协议源码，也不自动升级为项目依赖。

## 生态组件建议

遵循“系统框架优先、官方/Swift 生态补位、社区依赖经审计后再引入”的顺序：

- iPhone UI：SwiftUI、MapKit、`MKLocalSearch`、Core Location。
- Controller Link：Network.framework 的 Bonjour/TLS、Security/Keychain、CryptoKit。
- Injection Backend：XCTest/XCUIAutomation；Simulator 开发时可用 `simctl`，但不改变物理设备验收。
- CLI：采用 Apple 的 [Swift Argument Parser](https://github.com/apple/swift-argument-parser/blob/2f77f2fccb6e84fecff338c37b199e33e7dfd119/README.md#L98-L136)，它是 [Apache-2.0](https://github.com/apple/swift-argument-parser/blob/2f77f2fccb6e84fecff338c37b199e33e7dfd119/LICENSE.txt)、source-stable，并直接支持命令树、参数验证、帮助和 async command。不要自己重写参数解析器。
- 日志与测试：OSLog、Swift Testing/XCTest，第一轮无需再引入 logging/test wrapper。
- 证书工具：[`swift-certificates`](https://github.com/apple/swift-certificates/blob/449dbbecd0f31e82b510ada227ca152caa8b5e98/README.md#L1-L47) 是 [Apache-2.0](https://github.com/apple/swift-certificates/blob/449dbbecd0f31e82b510ada227ca152caa8b5e98/LICENSE.txt) 的 X.509 创建/序列化/验证库，可作为自签身份原型的候选；但它与 Network.framework `sec_identity_t`、Keychain 持久化的接线需要先做小 spike。若 Security.framework 已能以更少代码完成当前单用户身份，不为“使用生态”而强行增加依赖。

## 当前个人环境审计

2026-07-27 的诊断检查结果：

- macOS 27.0（build 26A5378n）。
- Xcode 26.6（build 17F113），Xcode first-launch 状态正常。
- Apple Swift 6.3.3。
- `xcode-select -p` 当前仍是 `/Library/Developer/CommandLineTools`，所以项目命令必须显式设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`，或由用户自行选择完整 Xcode；doctor 应把这个 mismatch 报出来。
- 一台 iPhone 16 Pro（iOS 26.5.2）当前 paired、wired、available，Developer Mode 已启用。
- Developer Disk Image 与该设备 compatible/usable；查询该信息时 `devicectl` 按其正常流程启用了 DDI services，但没有启动位置模拟。
- `devicectl` 没有物理位置模拟命令；`simctl location` 仅作为 Simulator 工具。

本文刻意不记录设备 serial、UDID、ECID 或本地主机名。

## 仍待实测的问题

1. 公开 `XCUIDevice.location` 在当前 Personal Team + 物理 iPhone 上能否稳定 set/replace/clear。
2. Test Runner 是否能在 Pinshift 前台交互期间持续至少 10 分钟，并被 Mac 安全地投递新坐标。
3. `nil` clear、runner 正常退出、runner 异常退出三种路径的真实恢复行为是否一致。
4. App 收到的位置 timestamp/accuracy 更新是否稳定满足 15 秒与 25 米阈值。
5. runner 内部通道的最简安全形式，以及是否需要 `swift-certificates`。
6. Cross-App Propagation。它明确留到第一轮能力完成后逐 App 验证，当前结论保持保留。

## 对后续需求文档的输入

后续文档可以锁定这些内容：Mac-hosted Simulation Controller、Bonjour/TLS Controller Link、公开 XCUITest 作为第一个 probe、backend-neutral request/response、静态坐标、显式 clear/reset、Pinshift 完成 Verified Simulation，以及 Cross-App Propagation 不进入第一轮验收。

后续文档不应锁定这些未经验证的内容：XCUITest 已经通过真机验证、任意第三方 App 都会收到坐标、测试会话永不掉线、`devicectl` 可直接设置物理位置，或 DVT 逆向协议是 Apple 公共支持面。
