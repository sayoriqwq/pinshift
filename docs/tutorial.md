# Pinshift development tutorial

This tutorial covers the current personal environment only. The production Injection Backend is Xcode 27's public `devicectl device simulate location` workflow; there is no production test runner or second backend.

## Repository-local quick start

The repository contains a Nix Flake and direnv setup. It supplies Fish, jq, and XcodeGen while deliberately leaving Swift to the approved Xcode Beta toolchain. Approve the environment once after cloning or whenever `.envrc` changes:

```fish
cd /Users/sayori/Desktop/remote-location
direnv allow
```

🌱 允许仓库加载声明式 Nix 开发环境。

After that, the normal startup flow is:

```fish
cd /Users/sayori/Desktop/remote-location
rl-install # once, and again only after controller source changes
rl-doctor
rl-start
```

🚀 安装稳定控制器、检查环境并启动日常 Controller Link。

`rl-install` creates a stable, signed controller executable, installs its per-user launchd Cleanup Guardian, and conservatively authorizes that exact executable to use the existing controller private key. The first migration can show one macOS Keychain approval; approve the signed controller permanently. It does not delete or replace the existing TLS identity, and it stops before changing Keychain if the signing requirement differs from the previous installation.

Daily commands never rebuild or re-sign the controller. `rl-start` keeps the trusted Controller Link open for one hour by default, while every Pinshift app Apply starts its own visible Simulation Lease. The App offers exactly 15, 30, and 60 minutes and defaults to 15 minutes. Server duration never extends that lease. Immediate restore, lease expiry, orderly server shutdown, 30 seconds of continuous server-owner heartbeat loss, startup reconciliation, and `rl-reset` all converge on the same durable, idempotent cleanup workflow.

When exactly one paired physical iPhone is known to Xcode, these commands select it automatically without printing its private identifier. If discovery is ambiguous, copy `.env.example` to the Git-ignored `.env.local` and set `REMOTE_LOCATION_DEVICE` there.

## Prepare Xcode and the iPhone

1. Install the approved full Xcode and open it once to finish first-launch setup.
2. Connect and unlock the iPhone. Confirm **Trust** on both devices if prompted.
3. Enable **Developer Mode** in **Settings → Privacy & Security**, restart if prompted, and confirm it after restart.
4. Open the app project in Xcode and select automatic signing for an available development team. A Personal Team build can require rebuilding and reprovisioning every seven days.
5. Build, install, and launch **Pinshift** on the iPhone.

After that first signed build, renew the Personal Team app from the repository with:

```fish
rl-resign-app
```

🔏 Renews only when 24 hours or less remain, verifies the new profile, and updates the existing app.

Use `rl-resign-app --force` to request a newer profile immediately. The command temporarily moves
only profiles whose application identifier exactly matches the compatibility bundle identifier
declared in `project.yml`, then asks Xcode automatic signing for a replacement. Before installation it verifies the candidate
code signature, bundle identifier, signing team, application prefix, and a strictly later expiration
date. It never uninstalls the device app. A pre-install failure restores the old cached profile;
successful renewals retain the old profile in a private repository-local backup under `.build/`.
Once installation begins, a timeout or disconnect is an uncertain remote outcome rather than a safe
rollback point. In that case the command keeps the new profile, signed candidate, and private logs for
inspection and does not claim that the existing device app remained unchanged.

Xcode must remain signed in to the Apple Account. Authentication expiry, two-factor authentication,
or updated developer agreements still require interaction in Xcode. Wi-Fi installation requires the
paired iPhone to remain visible to Xcode. A locked phone can defer only launch verification; unlock it
and run `rl-resign-app --launch-only`, or open Pinshift manually.

Keep the Active Test Device selector private. Supply it with `--device` or the `REMOTE_LOCATION_DEVICE` environment variable. Supply the approved full-Xcode developer directory with `--developer-directory` or `REMOTE_LOCATION_DEVELOPER_DIR`; this project does not require changing the global `xcode-select` value.

## Diagnose without changing settings

Run:

```fish
remote-location-controller doctor
```

🩺 Runs the controller's read-only environment checks.

Doctor checks the configured full Xcode/version, first-launch status, developer-directory mismatch, Active Test Device availability, Developer Mode or developer disk image failures, signing identity, Controller Link identity, and the App permission checkpoint. It uses fixed read-only commands, never prints raw device or signing output, and never changes Xcode, device, permission, or system settings.

Follow only the recovery step for a failed check. Location and Local Network decisions belong to iOS, so their authoritative status appears inside the Pinshift app.

## Pair and use the controller

Install or update the repository-local signed controller:

```fish
rl-install
```

🛠️ Installs or updates the stable signed controller and Cleanup Guardian.

Start the trusted local Controller Link and keep it open:

```fish
rl-start
```

🔗 Starts the trusted local Controller Link for the current session.

An iPhone that already trusts the preserved controller identity reconnects without a new six-digit code. A new or reset iPhone still performs the explicit one-time pairing flow.

In the Pinshift app:

1. Allow **Location** and **Local Network** access, then enter the short-lived pairing code.
2. Choose one Selected Location with manual coordinates, the map, or place search. Selecting never applies automatically.
3. Choose **15**, **30**, or **60 minutes**, then tap **Apply Selected Location**. Apply remains unavailable until the independent Cleanup Guardian reports ready.
4. Use the active session card to see the authoritative end time, live remaining time, and automatic-cleanup protection. **Applied** means the `devicectl` backend acknowledged the request; a fresh Pinshift app observation remains separate evidence.
5. Do nothing and let cleanup become due automatically, tap **Extend 15 Minutes**, or tap **Return to Normal Location** for immediate restore. The App retains extension and Stop Intent requests across reconnection or relaunch and reports the Simulated Location cleared only after public `devicectl` clear succeeds.

If the foreground server exits normally, cleanup is requested immediately. If it crashes or is killed, the launchd Cleanup Guardian makes cleanup mandatory after 30 seconds without the matching server-owner heartbeat; an ordinary iOS disconnect or App backgrounding does not trigger this rule. The selected lease remains the hard upper bound. If the whole Mac or Active Test Device is unavailable, restore the same device connection and unlock the iPhone; the Guardian retains and resumes the Cleanup Obligation automatically. No second tap is required. iOS has no public API for this developer-service clear, so cleanup cannot execute while both the Mac-side Guardian and device connection are unavailable.

`remote-location-controller tutorial` prints the same compact workflow in the terminal.
