# Pinshift Location Simulation

This context covers temporary iOS test locations controlled from one paired Mac for one developer-owned iPhone.

## Language

**Pinshift app**:
The iOS product surface used to choose locations, request temporary simulations, display the Mac's current status, and record local observations.
_Avoid_: Simulation Controller, Injection Backend

**Simulated Location（模拟位置）**:
A location supplied through Apple's development environment. It is distinct from the device owner's physical location and does not promise identical behavior in every app.
_Avoid_: Virtual Location, Fake GPS, Device Truth

**Selected Location（待应用位置）**:
The coordinate currently chosen in Pinshift. Choosing or replacing it is always available and never applies a simulation by itself.
_Avoid_: Applied Simulation, Pending Request

**Saved Location（已保存地点）**:
A user-named coordinate stored locally on the iPhone for later selection. Choosing it only replaces the Selected Location.
_Avoid_: Location History, Applied Simulation

**Fine Adjustment（位置微调）**:
A map-based refinement around the current Selected Location that produces a replacement Selected Location.
_Avoid_: Route Movement, Automatic Apply

**Simulation Controller（模拟控制器）**:
The single persistent Mac authority for Controller Link, the current temporary simulation, and automatic clear. It applies and clears locations through the Injection Backend and is the source of truth after reconnect or relaunch.
_Avoid_: Pinshift app, Background Guardian, Foreground Server

**Injection Backend（注入后端）**:
The part of the Simulation Controller that translates Apply and Clear into the location-testing mechanism provided by Xcode.
_Avoid_: Simulation Controller, App Observation

**Controller Link（控制器连接）**:
The trusted local connection carrying Status, Apply, and Clear between the Pinshift app and its Simulation Controller.
_Avoid_: Cloud Service, Cleanup Channel

**Trusted Controller（可信控制器）**:
A Simulation Controller explicitly paired once and remembered by the Pinshift app for future Controller Links.
_Avoid_: Discovered Controller, User Account

**Active Test Device（活动测试设备）**:
The single physical iPhone selected for the developer workflow and eligible to receive simulation commands.
_Avoid_: Device Fleet, Concurrent Target

**Temporary Simulation（临时位置模拟）**:
One applied coordinate with a fixed 15-minute lifetime. A new Apply replaces it immediately and starts a fresh lifetime; retrying the same Apply does not extend it.
_Avoid_: Indefinite Simulation, Configurable Duration, Route Playback

**Apply Operation（应用操作）**:
One user request to apply the current Selected Location. Each genuinely new Apply has a unique identity, and the latest accepted user operation owns current state.
_Avoid_: Session Generation, Coordinate Draft

**Automatic Clear（自动解除）**:
The Simulation Controller's responsibility to clear a Temporary Simulation at its fixed deadline. If the Mac or Active Test Device is unreachable, the responsibility remains on the Mac and retries at the first reachable opportunity without blocking a new Apply.
_Avoid_: User Confirmation, iOS Timer, Readiness Gate

**Clear Now（立即解除）**:
An optional request to clear the simulation visible when the user tapped it. A delayed Clear cannot erase a newer Apply, and a failed or lost response never blocks selection or replacement Apply.
_Avoid_: Persistent Stop Intent, Required Final Step, Physical Location Refresh

**Controller Status（控制器状态）**:
The Simulation Controller's current snapshot: idle, active, uncertain, or automatic-clear retrying, plus present backend readiness. On reconnect or app relaunch it replaces local display state but never disables a new Apply because of historical state.
_Avoid_: iOS-Owned Lifecycle, Apply Precondition

**Simulation Capability（模拟能力）**:
The consumer-agnostic ability to report status, apply, replace, and clear a Simulated Location through the active Xcode developer workflow.
_Avoid_: App Compatibility, Cross-App Guarantee

**Simulation Diagnostic Record（模拟诊断记录）**:
A bounded local chronology used to correlate selection, Apply, Clear, backend results, and observations. It records evidence only and never changes simulation state.
_Avoid_: Automatic Recovery, Simulation Authority, Telemetry

**Observed Location（观测位置）**:
The most recent Core Location value Pinshift receives while in use. It can verify Pinshift's own result but is not authoritative simulation state.
_Avoid_: Applied Location, Device Truth

**Applied Simulation（已应用模拟）**:
A Temporary Simulation that the Injection Backend reports it set for the Active Test Device. This is an execution acknowledgement, not proof of propagation to another app.
_Avoid_: Verified Simulation, Cross-App Success

**Verified Simulation（已验证模拟）**:
An Applied Simulation whose coordinate is subsequently matched by a fresh Observed Location in Pinshift.
_Avoid_: Backend Success, Cross-App Propagation

**Cross-App Propagation（跨 App 传播）**:
An observed condition where another app reports a location consistent with the active Simulated Location. It is measured per app rather than assumed device-wide.
_Avoid_: Cross-App Control, Guaranteed System Override
