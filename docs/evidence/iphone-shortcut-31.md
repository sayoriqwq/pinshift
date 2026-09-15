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

These local startup/reuse checks used the first implementation before the review follow-up.

## Review follow-up and final automated checks

- The Standards review's readiness-string finding and the Spec review's startup-failure feedback finding were both addressed in `18c898b`; both reviewers confirmed their findings resolved.
- The follow-up passed 46 workflow/runtime tests. A final targeted run passed 8 shortcut/readiness tests, including an asynchronously launched worker whose controller exits before becoming ready.
- After merging the follow-up (`f05eecc`), the full Swift package test command again completed with exit status 0 using the explicit Xcode developer directory.
- The existing installer successfully rebuilt and signed the final controller while preserving its identity. The installed final controller reported `stopped`, ready for a fresh iPhone-triggered start.
- Fish syntax, AppleScript compilation, and diff whitespace checks passed during implementation. All implementer worktrees were removed after their commits were merged.

## End-to-end acceptance — owner report

The owner confirmed successful real-iPhone SSH authorization and preparation, followed by all three requested daily-flow checks: Controller Link remained connected after the shortcut ended, selecting/applying a location succeeded, and another shortcut invocation left the existing session working. The owner additionally confirmed renewal succeeded and authorized merging PR #40.

The dedicated public key was validated and installed with a fixed command and OpenSSH restrictions; a local probe confirmed port 22 listening. No public key, private key, host address or device identifier is retained in this record.

This accepts the core personal-device workflow on the owner's reported results. The agent did not independently observe the phone UI or capture a new provisioning-profile expiry. The report does not establish every failure scenario, recovery from an already-expired/unlaunchable App, precise three-minute timing during repeated preparation, or preservation of each preference after renewal; those remain separate regression scenarios.

A subsequent PR review identified reuse of a stopping controller. The merge follow-up waits up to 30 seconds for the session to finish, then starts a replacement only after shutdown; an unfinished shutdown produces a manual-action result. All 9 shortcut workflow tests passed, including shutdown completion and a session that remains stopping. Fish syntax and diff whitespace checks also passed.
