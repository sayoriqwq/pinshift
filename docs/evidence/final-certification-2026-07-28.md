# First-round final certification — 2026-07-28

Status: PASS

## Scope and baseline

This record covers the personal validation workflow under ADR-0007 and ADR-0009. The approved baseline is macOS 27.0, Xcode 27.0 beta 4 (27A5228h), Swift 6.4, one wired physical iPhone with Developer Mode and developer services available, and the public `devicectl device simulate location` production backend.

Device identifiers, signing identities, hostnames, pairing material, raw `devicectl` output, and exact selected coordinates are intentionally omitted. Raw local logs remained in an owner-only temporary directory.

## Acceptance matrix

| Area | Result | Evidence |
| --- | --- | --- |
| Environment and readiness | PASS | Read-only doctor, tutorial, and status checks succeeded; the physical app reported Local Network Allowed, Trusted Controller connected, Active Test Device Ready, and `devicectl` ready. |
| Trusted Controller | PASS | The existing Keychain-backed trust was reused without another pairing operation; TLS and incorrect-identity behavior remain covered by Controller Link tests. |
| Manual selection | PASS | Existing domain, UI, and physical backend evidence covers the manual Selected → Applied → Observed → Verified seam. |
| Map selection | PASS | On the physical iPhone, the user selected the map center with the blue `+`, closed the picker, explicitly applied it, and observed both Applied and Verified states. |
| Place search | PASS | The deterministic search fixture selected the result, explicitly applied it through a DEBUG-only correlated Controller Link fixture, observed Applied, and reached Verified through a fresh public location observation. |
| Replace and verify | PASS | Public backend evidence covers A → B replacement with fresh matching Pinshift app observations; the full simulator regression also passed public A → B observation. |
| Stop and reset | PASS | Two consecutive public `devicectl ... location clear` operations exited 0, proving final cleanup and idempotency. Normal Controller-exit cleanup has a controlled fake-backend regression. |
| Failure and recovery states | PASS | Automated coverage includes permission denied/restricted, search empty/failure preservation, request correlation, unavailable backend/session, disconnect, stop failure, and clear failure. |
| Public API and privacy | PASS | No private injection API, cloud service, account, telemetry, location history, or persistent device-identifier log was found. |
| Dependencies and license | PASS | The only external package is Swift Argument Parser under Apache-2.0; no GPL or unlicensed source was found. |

## Automated verification

- `swift test` with the Xcode beta developer directory: 72 tests passed after the final review fixes.
- Final post-review iOS 27 simulator suite: 9 tests executed in 332.0 seconds, 6 passed, 3 physical-only/ten-minute tests skipped by design, 0 failures.
- Focused post-review map/search simulator checks: 2 passed, 0 failed. Both paths tapped Apply, asserted Applied, supplied a fresh public `XCUILocation`, and asserted Verified.
- `swift format lint --recursive Sources Tests App`: passed after the final review fixes.
- `git diff --check`: passed after the final review fixes.
- Production-source audits found zero prohibited private-API, cloud/telemetry, or persistent-history matches.

## Physical journey

1. The Active Test Device and Xcode beta developer directory passed the read-only preflight.
2. The controller started with owner-only pairing-code material, and the already trusted Pinshift app connected without another pairing operation.
3. The user confirmed all four readiness states in the physical app.
4. The user selected the map center with the blue `+`, explicitly applied the selection, and confirmed Applied and Verified.
5. As supplementary, non-gating evidence, the user reported that QQ displayed the simulated address. This is one app-specific observation on this recorded environment, not a system-wide or Cross-App guarantee.
6. The Lead cleared the public location proxy twice; both commands exited 0. The controller then stopped.
7. The final post-review app was signed, built, installed over the existing physical app, and launched successfully.

## Final review ledger

- `E-STD-001` — accepted. Selecting B while A remained active could replace the primary lifecycle display with a pending-selection status. The remediation preserves truthful active Apply/Verify state independently from the new Selected Location and adds regressions.
- `E-SPEC-001` — accepted. The physical requirement is satisfied by the recorded map-center journey. Deterministic map and search checks were extended through the shared fresh-observation verification seam.
- `E-SPEC-002` — accepted. Normal `link serve` completion now has a controlled lifecycle regression proving exactly one clear/reset and one reported result.

## Explicitly unverified boundaries

- No other Mac, Xcode, iOS, device, connection, account, or distribution environment is certified.
- At the time of this certification, crash-safe clear after process kill, power loss, cable loss, or OS failure was not guaranteed and explicit reset was the recovery path. ADR-0010 and the later eventual-cleanup implementation supersede this boundary with a durable obligation that resumes at the first recovery opportunity; its separate physical verification record states the remaining certification boundary.
- A fresh physical Core Location callback immediately after clear is not guaranteed; the last successful observation may remain visible.
- Search was not manually repeated on the physical iPhone in this final pass; the required physical map entry was completed and search remains automated.
- QQ is the only additional app observed in this pass. No behavior is promised for QQ versions, other apps, or system components.
- Personal Team provisioning expiry and renewal remain manual development-environment constraints.

## Lead disposition

The final Standards re-review confirmed `E-STD-001`. The final Spec re-review confirmed `E-SPEC-001` and `E-SPEC-002`. All accepted findings are closed, the post-review full regressions passed, and Issues #7, #9, and #10 meet their closure conditions. Parent Issue #1 remains a user decision and is not closed by this certification.
