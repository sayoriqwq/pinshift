# iPhone shortcut preparation — Issue #31

## Host preflight (2026-09-16)

- The Mac has an active console login.
- With the repository's explicit Xcode developer directory, `devicectl` reports one paired physical iPhone available. Device names and identifiers are omitted here.
- No Simulation Controller process was running at the start of this check.
- A connection probe to local TCP port 22 did not find an SSH listener. The administrative Remote Login query could not run without administrator access; this does not establish the system preference's exact value.
- `pinshift doctor` in the Nix project environment passed the device, Developer Mode, device support image, signing identity, and Controller Link identity checks. It retained the existing warning that Location and Local Network permissions must be confirmed in the iPhone app. No settings were changed.

## Baseline checks

- Before integrating implementation changes, the full Swift package test command completed with exit status 0 using the explicit Xcode developer directory.
- The existing `Tests/pinshift-command-check.py` check passed with the configured user Python interpreter.

## Integrated implementation checks

- The full Swift package suite passed after merging the first implementation and shortcut documentation (PR head `7cfc4b5`).
- The existing installer built and signed the updated controller, preserved its signing requirement and Controller Link identity, and completed successfully.
- `pinshift register-remote` generated the fixed local entry using the configured Nix environment and paired physical device.
- A local invocation of that same fixed entry with `SSH_ORIGINAL_COMMAND=prepare` returned exit status 0 and `controller-ready`. The signing workflow reported more than 24 hours remaining and skipped renewal; no new signing/installation acceptance is claimed.
- After the requesting command exited, the installed controller still reported `ready` and was attached to a real terminal TTY. A second invocation returned successfully and retained the same controller process; diagnostics contained no second startup event for that repeat.
- The local test controller received a single normal SIGINT and subsequently reported `stopped`, leaving a stopped-session starting point for iPhone testing.
- Computer Use could not inspect Terminal because that app is disallowed by the tool. Window visibility therefore still requires a human observation; process/TTY evidence alone is not visual acceptance.

These local checks used the first implementation before the review follow-up. Review identified a startup-failure feedback gap; the follow-up and its regression results must be recorded before final acceptance.

## End-to-end acceptance

Pending: configure the iPhone shortcut and its dedicated SSH public key, then perform the physical checks in the shortcut guide. Local command tests cannot establish that iPhone Shortcuts can reach this Mac, that the user's SSH context can launch Terminal, or that the actual phone establishes Controller Link.

Do not treat the host preflight as successful remote preparation, signing renewal, installation, or location simulation.
