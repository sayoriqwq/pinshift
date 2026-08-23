# Pinshift development tutorial

This tutorial covers the current personal environment. The sole production Injection Backend is Xcode 27's public `devicectl device simulate location` workflow.

## Repository environment

The Nix Flake and direnv environment provide Fish, jq, and XcodeGen while using the approved Xcode Beta Swift toolchain:

```fish
direnv allow
```

🌱 允许仓库加载声明式 Nix 开发环境。

Install once, then run the read-only checks:

```fish
pinshift-install
pinshift-doctor
```

🛠️ 构建并签名稳定控制器、移除旧常驻项，然后检查环境。

`pinshift-install` publishes the signed controller but does not register a LaunchAgent. It unloads and removes the former controller and Cleanup Guardian authorities. The installer preserves the existing Keychain TLS identity and refuses an unexpected designated-requirement change before modifying trust.

Controller state now exists only in the explicitly started test session. There is no lifecycle journal, restart reconciliation, or durable cleanup retry. During migration, the signed candidate performs one real backend reset before the obsolete lifecycle file is removed; a failed reset aborts publication. Saved Locations and Trusted Controller data survive an upgrade.

## Prepare Xcode and the iPhone

1. Install the approved full Xcode and open it once to finish first-launch setup.
2. Connect and unlock the iPhone. Confirm **Trust** on both devices if prompted.
3. Enable **Developer Mode** in **Settings → Privacy & Security** and finish the restart confirmation.
4. Open the app project in Xcode and enable automatic signing for a development team.
5. Build, install, and launch **Pinshift** on the iPhone.

Keep the Active Test Device selector private in `PINSHIFT_DEVICE` or pass `--device`. Set the approved Xcode `Contents/Developer` path through `PINSHIFT_DEVELOPER_DIR` or `--developer-directory`; the project never changes global `xcode-select` state.

## App signing renewal

A Personal Team app may require renewal every seven days. Renew only when 24 hours or less remain:

```fish
pinshift-resign-app
```

🔏 验证新 profile 并原位更新现有 App。

Use `pinshift-resign-app --force` to request a newer profile immediately. The workflow validates the candidate signature, bundle identifier, team, application prefix, and strictly later expiry before installation. It never uninstalls the App. A pre-install failure restores the old cached profile; a disconnect after installation starts is reported as an uncertain remote outcome.

If a locked phone only deferred launch verification, unlock it and run:

```fish
pinshift-resign-app --launch-only
```

📱 不重新签名，只补做启动验证。

## Diagnose without mutation

```fish
pinshift-controller doctor
```

🩺 运行固定的只读 Xcode、设备、签名、身份和权限检查。

Doctor never changes system or device settings and does not print raw private selectors. Location and Local Network permission decisions remain authoritative inside the iOS app.

## Pair and use

Whenever a testing session begins, run:

```fish
pinshift-start
```

🔗 启动前台 Controller Link 并打印六位码；保持终端打开，Ctrl-C 会先 Clear 再退出。

Already trusted iPhones reconnect automatically while this foreground process is running. In Pinshift:

1. Allow **Location** and **Local Network**, then pair if needed.
2. Choose a Selected Location. Selection never applies automatically and remains available in every simulation state.
3. Tap **Apply Selected Location**. There is no duration parameter: the Mac returns exactly three minutes from the first acceptance of this operation.
4. Choose and Apply another location at any time. The new operation replaces current state and receives a fresh deadline.
5. **Clear Now** remains visible even when no active record is shown. Every tap reaches the backend, including when the controller has no tracked operation. Failed or lost Clear never disables selection or Apply and can be retried.

The running Mac session snapshot is authoritative after reconnect. The app persists only user selection; it does not persist a resendable clear or extension command.

## Automatic clear behavior

- A genuinely new Apply receives a fixed deadline of acceptance time plus 180 seconds.
- Retrying the same request ID returns the original deadline without another backend Apply.
- At the deadline, the Mac authority requests public `devicectl ... location clear`.
- If the Mac or Active Test Device is unreachable, the failure is exposed and the user can retry Clear Now after restoring connectivity.
- Apply, Clear, and the timer serialize through the same foreground controller actor.
- Ctrl-C, termination, and a finite session duration perform one real Clear before normal exit; failure makes the process exit unsuccessfully.
- A successful backend clear does not guarantee an immediate fresh physical Core Location callback.

The compact terminal version is available with:

```fish
pinshift-controller tutorial
```

📖 打印与当前产品协议一致的设置和使用说明。
