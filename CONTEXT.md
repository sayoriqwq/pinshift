# Location Simulation Learning

This context covers learning and experimenting with location-aware iOS behavior through Apple-supported development and testing workflows.

## Language

**Simulated Location（模拟位置）**:
A location supplied to an app under test through Apple's development environment. It is distinct from the device owner's real location and does not imply changing location system-wide for other apps.
_Avoid_: Virtual Location, Fake GPS, Location Spoofing

**Selected Location（待应用位置）**:
A single coordinate chosen inside the learning app and awaiting application through the Simulation Controller. Selection alone never represents a Simulated Location or an Observed Location.
_Avoid_: Scenario Location, Simulated Location

**Saved Location（已保存地点）**:
A user-named coordinate stored locally on the Learning App's current device for later selection. Choosing one replaces the Selected Location and never applies a simulation automatically.
_Avoid_: Recent Location, Location History, Applied Simulation

**Fine Adjustment（位置微调）**:
A map-based refinement that starts around the current Selected Location at a close viewing range and produces a replacement Selected Location. It imposes no movement boundary and never applies a simulation automatically.
_Avoid_: Route Movement, Automatic Apply, Manual Coordinate Editing

**Simulation Controller（模拟控制器）**:
The developer-side participant that applies a selected location to the Active Test Device through the current Xcode development environment.
_Avoid_: iPhone App, GPS Spoofer

**Cleanup Guardian（清理守护者）**:
A per-user macOS LaunchAgent that owns lease-expiry and retry execution independently of the foreground Simulation Controller and Controller Link. It survives server termination and Mac login-session restarts, but still requires the Mac and matching Active Test Device to become reachable before `devicectl clear` can succeed.
_Avoid_: Controller Link, iOS Stop Handler, Diagnostic Watcher

**Injection Backend（注入后端）**:
The replaceable part of the Simulation Controller that translates generic simulation requests into a location-testing mechanism provided by the active developer environment.
_Avoid_: Simulation Controller, Permanent XCUITest Dependency

**Controller Link（控制器连接）**:
The trusted local connection that carries simulation requests and execution status between the learning app and its Simulation Controller.
_Avoid_: Cloud Service, USB Tunnel

**Trusted Controller（可信控制器）**:
A Simulation Controller whose identity the learning app accepted through explicit one-time pairing and remembers for future Controller Links.
_Avoid_: Discovered Controller, User Account

**Active Test Device（活动测试设备）**:
The single physical iPhone currently selected for the developer workflow and eligible to receive simulation requests.
_Avoid_: Device Fleet, Concurrent Target

**Simulation Capability（模拟能力）**:
The consumer-agnostic ability to request, apply, stop, and report a Simulated Location through the active Xcode/devicectl developer workflow. It does not include validating how any particular app consumes that location.
_Avoid_: App Compatibility, Cross-App Guarantee

**Static Simulation（静态模拟）**:
A simulation that holds one coordinate until the developer replaces or stops it. Movement, speed, and route progression are outside this concept.
_Avoid_: Route Playback, Journey Simulation

**Simulation Generation（模拟代次）**:
The identity of one Static Simulation created by an Apply request. A replacement Apply creates a new generation so late results from an older simulation cannot change the current one.
_Avoid_: Request Attempt, Coordinate Version

**Simulation Lease（模拟租约）**:
The bounded maximum lifetime granted to one Applied Simulation before cleanup becomes mandatory. The Learning App offers exactly 15, 30, and 60 minutes, defaults to 15 minutes, and allows acknowledged 15-minute extensions capped at one hour from acknowledgement. The lease is independent of Controller Link duration. It is a safety deadline, not a promise that cleanup can run while the Mac host or Active Test Device is unreachable.
_Avoid_: Network Timeout, Server Duration

**Cleanup Obligation（清理义务）**:
The locally retained responsibility to obtain a successful Injection Backend clear for a Simulation Generation. It ends only with a durable clear acknowledgement and survives foreground controller termination and Mac restarts through the Cleanup Guardian.
_Avoid_: Diagnostic Event, Best-Effort Reset

**Cleanup Pending（等待清理）**:
A Simulation Generation whose cleanup is required but has not yet received a successful Injection Backend clear acknowledgement. It remains distinct from Stopped Simulation while recovery is temporarily unavailable.
_Avoid_: Stopped Simulation, Clear Failure

**Stop Intent（停止意图）**:
A tester's correlated request to end one Simulation Generation. The Learning App retains it until authoritative controller reconciliation proves the generation is stopped.
_Avoid_: Stop Tap, Transport Attempt

**Stopped Simulation（已停止模拟）**:
A Static Simulation that its Injection Backend reports is no longer active. It invalidates Applied Simulation and Verified Simulation, while the latest Observed Location may remain as an explicitly identified last observation.
_Avoid_: Restored Physical Location, Cleared Observation

**Simulation Diagnostic Record（模拟诊断记录）**:
A persistent local chronology used to correlate selection, apply, stop, backend-result, and observation evidence while investigating a simulation incident. It records evidence only and never changes or retries simulation state.
_Avoid_: Automatic Recovery, Simulation State, Telemetry

**Observed Location（观测位置）**:
The most recent Core Location value the learning app receives while in use. It can verify the app's own result but is not evidence of Cross-App Propagation.
_Avoid_: Applied Location, Device Truth

**Applied Simulation（已应用模拟）**:
A Static Simulation that the active Injection Backend reports it has set for the Active Test Device. This is an execution acknowledgement, not proof of the resulting location.
_Avoid_: Verified Simulation, Cross-App Success

**Verified Simulation（已验证模拟）**:
An Applied Simulation whose selected coordinate is subsequently matched by a fresh Observed Location in the learning app. This is the required first-round success outcome and is not evidence of Cross-App Propagation.
_Avoid_: Backend Success, Cross-App Propagation

**Cross-App Propagation（跨 App 传播）**:
An observed condition where an app other than the learning app reports a location consistent with the active Simulated Location. It is measured independently for each app rather than assumed to be device-wide.
_Avoid_: Cross-App Control, Guaranteed System Override
