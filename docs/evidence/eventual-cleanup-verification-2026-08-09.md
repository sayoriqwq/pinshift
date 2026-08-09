# Eventual-cleanup verification — 2026-08-09

Status: the foreground-server-independent eventual-clear invariant passed on the physical iPhone. UI feedback behavior during every reconnect permutation remains a separate, partially certified concern.

## Automated evidence

- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test`: passed every Swift package suite, including deterministic Simulation Lifecycle integration coverage for leases, extensions, owner-heartbeat loss, Guardian readiness, relaunch reconciliation, and idempotency.
- The high-level lifecycle harness now includes the exact ownership regression: Apply, release the foreground server owner, prove no early clear, advance the lease, and require an independent Cleanup Guardian to clear the durable generation. It also asserts that Guardian reconciliation schedules no secondary maintenance tasks.
- Existing coverage still includes controller restart, pre-apply acknowledgement loss, lost Stop response, offline Stop plus Learning App relaunch, bounded retry, failed shutdown recovery, replacement generations, Stop during an in-flight Apply, persisted device mismatch, legacy pre-journal recovery, and the one-hour hard maximum.
- `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer xcodebuild -project RemoteLocation.xcodeproj -scheme RemoteLocationLearning -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build`: `BUILD SUCCEEDED`; both localization files compiled.
- `swift format lint --recursive Sources Tests App`: completed successfully. Existing repository warnings remain advisory.

## Physical iPhone evidence

- `bin/rl-install`: built, signed, verified, and transactionally installed the changed controller plus `dev.sayori.remotelocation.cleanup-guardian` while preserving the existing Controller Link identity. `launchctl print` reported the Guardian `state = running` in a process group independent of `rl-start`.
- `bin/rl-doctor`: passed the full Xcode toolchain, paired physical iPhone, Developer Mode, device support image, signing identity, and Keychain Controller Link identity checks.
- The Learning App selected and applied `31.2304, 121.4737`; the public Xcode 27 `devicectl` backend acknowledged Apply and the App received a fresh matching simulated observation.
- Normal Learning App Stop returned a production clear acknowledgement; the journal recorded the matching generation as `stopped` and `active: null`.
- `bin/rl-reset`: returned a successful clear acknowledgement. The durable journal reported `activeCleared: true` afterward.
- Production restart recovery: a standalone Apply of `52.5200, 13.4050` succeeded and its process exited. A fresh controller `status` process then reconciled the persisted lifecycle state before answering and returned `No Applied Simulation is active.`
- Server-independent destructive test: production Apply request `1C71D399-3D6F-40FD-B05E-1A57CCF94A2D` established a 30-second lease ending `2026-08-09T08:26:54Z`. The complete `rl-start` process group was then killed with `SIGKILL`; no Controller Link server remained, while Cleanup Guardian PID `23612` remained alive under launchd.
- Without restarting the server, tapping Stop, or running reset, the Guardian recorded `controller.lifecycle.lease-expired` at `08:26:54Z` and exactly one `controller.lifecycle.clear-acknowledged` at `08:26:56Z`. The journal recorded generation `1C71D399-3D6F-40FD-B05E-1A57CCF94A2D` as `stopped` and `active: null`.
- Reconciliation occurred approximately once per second; the earlier duplicate-maintenance-task defect was fixed and locked down before this passing run.

## Issue #15 lease-session acceptance run

- A production-backed physical-device smoke applied `31.2304, 121.4737` with the new 15-minute default. Extending by 15 minutes retained the same durable generation and moved its authoritative expiry from approximately `13:01:54Z` to `13:16:54Z`; diagnostics recorded one coordinate Apply and a separate `lease-extension-acknowledged` event.
- At `12:48:11Z`, the complete foreground `rl-start` process group was killed with `SIGKILL`, while the launchd Cleanup Guardian remained running in its independent process group.
- With no server restart, iOS Stop, or manual reset, the Guardian recorded `controller.lifecycle.server-heartbeat-lost` at `12:48:40.031Z` and received `controller.lifecycle.clear-acknowledged` at `12:48:40.992Z`. The durable lifecycle reported `active: null` at `12:48:41Z`, 30 seconds after the foreground server was killed.
- A final `bin/rl-reset` also returned a successful production clear acknowledgement, leaving no active obligation or foreground Controller Link server.

## Remaining boundary and non-core UI coverage

The physical run also observed stale/error-prone Learning App feedback after an offline Stop until controller rediscovery or App relaunch. This no longer owns the safety outcome: the independent Guardian clears at the lease deadline even if the iOS Stop request is never delivered. The UI reconciliation path should not be described as fully certified by this record.

Apple exposes the production clear through the Mac developer service, not a public iOS API. Therefore no implementation can execute clear while the whole Mac-side guardian is powered off/unavailable or the matching iPhone is unreachable. The durable obligation remains and the launchd Guardian retries after reachability returns; this is the remaining physical boundary.

After the Issue #15 acceptance run, the final safety reset succeeded. `launchctl` reported the Cleanup Guardian still running, no real `link serve` process remained, and the lifecycle journal reported no active simulation obligation.
