# Stage A Lead ledger

Last updated: 2026-07-28, Asia/Shanghai

## Stage and ticket state

| Item | State | Lead decision |
| --- | --- | --- |
| Stage A | changes-required | Issues #2 and #3 are integrated and the physical public-XCUITest gate passed. Review findings require signing-data cleanup, one research correction, and exact GPX evidence before Lead verification. |
| Issue #2 | integrated | Diff, automated verification, signed physical build, GPX match, and post-stop recovery were checked. It remains open and is not accepted before Stage A review. |
| Issue #3 | integrated | ADR-0008 and Issue #3 define clear by public proxy state independently from physical recovery. The revised physical gate completed 10 A/B/clear rounds in 618.1 seconds and passed. It remains open until Stage A is accepted. |
| Issues #4–#10 | blocked | No downstream ticket is released before Stage A is accepted. |

## Blockers and frontier

- Integrated dependency: Issue #2.
- Current and only frontier: Stage A dual-axis review. No Stage B implementation ticket is released yet.
- Resolved environment blocker: the earlier Personal Team app-slot limit was cleared by the user. The Pinshift app and separate UI-test runner subsequently installed and launched; no retained app removal is currently requested.
- Physical finding disposition: `A-PHYS-001` is preserved as evidence that proxy clear does not guarantee a fresh physical callback. The user rejected the prior gate interpretation and approved ADR-0008; the finding no longer blocks Issue #3.
- Stop condition: any review finding or regression in physical A/B fresh observation, nil-getter clear, repeated rounds, 600-second stability, last-observation UI semantics, or the public-API audit prevents Stage A acceptance. No alternate backend or app-limit bypass is authorized.

## Routes

| Responsibility | Requested route | Accepted route | Runtime route |
| --- | --- | --- | --- |
| Lead | GPT-5.6 Sol medium root | Current task root | Exact runtime metadata not exposed by a tool result |
| Stage A partner | `stage_partner`, GPT-5.6 Terra medium, fresh context | Custom role call accepted; returned `STAGE_READY` | Exact runtime metadata not exposed by the call result |
| Stage A Standards review | `standards_reviewer`, GPT-5.6 Terra medium, fresh context | Exact custom role call accepted after Stage A became review-ready | Completed `CHANGES_REQUIRED`; runtime model metadata was not exposed by the call result |
| Stage A Spec review | `spec_reviewer`, GPT-5.6 Terra medium, fresh context | Exact custom role call accepted after Stage A became review-ready | Completed `CHANGES_REQUIRED`; runtime model metadata was not exposed by the call result |
| Stage A modifier | `stage_modifier`, GPT-5.6 Terra medium, fresh context | Interface exposes the exact role; used only for Lead-accepted findings | Not yet run |

No model route was silently substituted. Issue #3 remains Lead-owned because the protocol reserves this physical public-API gate for Lead or an accurately routed direct Terra worker.

## Base and ownership

- Base revision: `c66ead116f613e5671c9629b8d34b721d949de9c` on `main`, aligned with `origin/main` at Preflight.
- Worktree: shared repository root; no parallel write worker.
- Lead-owned integration-sensitive files: `Package.swift`, `project.yml`, generated Xcode project, shared location domain, public fixtures, signing settings, UI test target, and evidence records.
- User-owned files preserved and excluded from project integration: `.codex/`.

## Diff evidence

- Issue #2: Swift package/domain matcher, unit tests, foreground Pinshift app, GPX fixture, generated iOS project, evidence record, and Xcode 27 beta execution-baseline ADR.
- Issue #3: UI test target, public `XCUIDevice.shared.location` set/nil probe, A/B/clear and 600-second physical gate, accessibility observation seam, and redacted evidence template.
- Generated project was regenerated after signing inspection; no local development-team value is retained in repository files.

## Automated verification

### Issue #2 integrated evidence

- `swift test --disable-sandbox`: 16 tests passed, 0 failures.
- `swift-format lint --recursive Sources Tests App`: passed.
- Generic iOS build with code signing disabled under Xcode 27 beta: passed.
- Private API/backend scan: no prohibited implementation reference found.

### Issue #3 current evidence

- TDD red/green established the public Pinshift app UI seam.
- Simulator public set A and replace B in one UI test session: passed; each result required a fresh Pinshift app match and captured timestamp/elapsed/distance UI evidence.
- Simulator nil clear intentionally cannot satisfy the physical recovery assertion and is not counted as gate evidence.
- The 600-second test compiles on Simulator and skips there by design.
- Physical set/replace attempt after foreground location authorization: public location A and B each produced a fresh Pinshift app match, confirming installation, signing, authorization, runner launch, set, and replace on the current device.
- Physical clear finding `A-PHYS-001`: after assigning `nil`, the Pinshift app did not receive a new non-simulated observation away from both public test targets within the 60-second clear window. The consolidated test failed at the clear assertion after approximately 129 seconds and did not enter the 600-second stability loop. Setter success alone is not accepted as clear evidence.
- Read-only result replay confirmed that clear began immediately after the fresh B match. For the following approximately 63 seconds, the Pinshift app retained B's timestamp and simulated-source diagnostic; no newer successful observation appeared.
- Apple primary-source review is recorded in `docs/research/xcuilocation-clear-semantics.md`. Apple documents nullable public proxy state and fallback to physical Core Location, but no maximum interval for a fresh physical fix after clear.
- Under the superseded recovery-based gate, the next physical probe separated public clear state from observation recovery and treated getter success as diagnostic evidence only.
- Post-probe automated verification: 16 Swift tests passed; Xcode's recursive Swift formatter lint passed; unsigned generic iOS build passed; unsigned generic iOS `build-for-testing` compiled both the Pinshift app and UI-test runner.
- The diagnostic physical rerun lasted approximately 460 seconds. It completed four full A/B/clear rounds in the same session; all eight set/replace observations matched in approximately 0.47–0.51 seconds, and the first four clears produced qualifying non-target physical observations.
- In round five, A and B again matched, then the public `XCUIDevice.shared.location` getter read back `nil` after clear. No new successful observation and no visible Core Location error followed during the current clear window; the Pinshift app retained B's timestamp and simulated-source diagnostic. The run failed before 600 seconds.
- Lead diagnosis under the superseded gate: the evidence falsified a deterministic public-`nil` clear failure and isolated intermittent physical Core Location recovery from the proxy-clear contract. The later user-approved ADR-0008 disposition replaced that gate interpretation.
- Falsifiable observation-contract fix under verification: the Pinshift app's foreground `CLLocationManager` previously retained the iOS default `pausesLocationUpdatesAutomatically = true`. The public SDK documents that default, and the failure appeared only after four successful repeated rounds while the device remained stationary. The minimal change disables automatic pausing; the unchanged physical gate must now demonstrate that the intermittent fifth-clear failure is gone for at least 600 seconds.
- Verification rejected that hypothesis. With automatic pausing disabled, the restored Xcode 27 beta 4 run entered the physical test normally, matched A and B in 0.47 seconds each, then failed on the first clear after 60 seconds. The public getter read back `nil`; the Pinshift app retained B at timestamp 2026-07-28 10:44:55 with simulated-source `Yes`, and exposed no Core Location error. The `.xcresult` contains zero completed A/B/clear rounds and a test runtime of approximately 138 seconds. `A-PHYS-001` therefore remains open and is not explained by `pausesLocationUpdatesAutomatically`.
- Recovery after the accidental Xcode removal regenerated `RemoteLocation.xcodeproj` from authoritative `project.yml`. The original development-team value was recovered read-only from the trashed project and added to both target settings in `project.yml`; the restored Xcode Beta then signed, deployed, and entered `Testing…` on the same physical destination. The signing interruption is not gate evidence and does not change the frontier.
- Diagnosis boundary: the current clear gate conflates two different public contracts. `XCUIDevice.shared.location == nil` is the documented state of the XCTest proxy, while `CLLocationManager.location` and the Pinshift app UI may legally retain the last successful location until Core Location independently produces another fix. Apple documents neither a forced callback nor a maximum recovery interval after proxy clear. A fixed 60-second requirement for a fresh non-target physical observation is therefore not a deterministic public-API contract on this baseline. Further stop/start or timeout experiments would test heuristics, not establish the required guarantee.
- User decision and contract correction: continue with the public XCUITest backend. Issue #3, ADR-0008, `CONTEXT.md`, this execution protocol, and the evidence template now define clear as assigning nil and reading the public getter back as nil. A fresh physical callback is best-effort diagnostic evidence only.
- TDD evidence for retained-observation semantics: the physical UI seam test first failed because `observation-recency-note` was absent, then passed after the Pinshift app explicitly described displayed coordinates as the last successful observation that may remain after stop and does not indicate an active simulation.
- Revised probe verification: the 60-second physical-recovery loop and its coordinate helpers were removed. A/B still require fresh Pinshift app matches; every clear now requires nil public getter state plus the visible last-observation contract; repeated rounds still run in one session for at least 600 seconds.
- Post-revision automated verification: 16 Swift tests passed with Xcode 27 beta selected; recursive Swift format lint passed with no diagnostics; unsigned generic iOS `build-for-testing` compiled the Pinshift app and UI-test runner. The first SwiftPM attempt accidentally used standalone Command Line Tools and could not resolve XCTest; it was rerun successfully with the approved Xcode Beta developer directory and is not a product failure.
- Final physical gate: `testPublicLocationBackendRemainsStableForTenMinutes` passed on the approved physical environment. The same test session completed 10 A/B/clear rounds over 618.1 seconds. All 20 A/B Pinshift app observations matched in 0.47–0.50 seconds at 0.00-meter distance. Every completed clear followed a successful public getter-is-`nil` assertion and visible last-observation semantics.
- Redacted evidence record: `docs/evidence/stage-a-xcuitest-gate-2026-07-28.md`. The raw `.xcresult` remains local because it can contain destination metadata.

## Physical verification

### Issue #2

- Signed Pinshift app launched on the recorded physical environment.
- GPX target matched under the 15-second/25-meter rule with 5.0-meter horizontal accuracy and simulated-source diagnostic `Yes`.
- After GPX stop, Core Location briefly reported `locationUnknown`, then produced a non-simulated observation with diagnostic `No`.
- Exact successful elapsed/distance display values were not retained; the evidence record states this limitation rather than inventing measurements.

### Issue #3

- The previous consolidated Xcode checkpoint established signing, launch, GPX behavior, and the free-profile three-app installation blocker.
- The user freed the required device slots; the Pinshift app and separate UI-test runner now install and launch successfully.
- The first authorized physical run passed fresh A and B observations but failed `A-PHYS-001` at clear. No immediate identical rerun is requested because it would not add evidence.
- Research and Lead disposition: `docs/research/personal-team-xcuitest-runner-app-limit.md`.
- Under the revised ADR-0008 contract, the final physical test passed 10 same-session A/B/clear rounds in 618.1 seconds. Fresh physical recovery after clear was not evaluated by this revised gate and remains non-gating diagnostic behavior.

## Review findings and modifiers

- `A-STD-001` (high, Standards): **accepted**. `project.yml` and the generated project retain a local development-team identifier, contradicting ADR-0007 and the ledger. It shares one remediation with `A-SPEC-001`: keep signing data only in ignored local configuration, regenerate the project, scan the repository, and rerun the unsigned generic build.
- `A-STD-002` (medium, Standards): **accepted with narrowed remediation**. The actionable defect is the research document's unsupported normative statement that continuous evidence “must” disable automatic pausing. The proposed runtime change is rejected because that hypothesis was already tested without resolving `A-PHYS-001`, and the final unchanged observer passed 10 rounds over 618.1 seconds. Remediation is to make the research accurately describe the tested-and-rejected hypothesis; no behavior change or physical #3 rerun is warranted.
- `A-SPEC-001` (high, Spec): **accepted**, duplicate root cause of `A-STD-001`; one signing-data cleanup and verification closes both IDs.
- `A-SPEC-002` (medium, Spec): **accepted**. Issue #2's physical record did not retain exact displayed elapsed and distance values. Lead must repeat the signed GPX baseline and record redacted request/observation timestamps, elapsed seconds, distance meters, selected fixture coordinate, and post-stop fresh non-simulated observation.
- Modifier mapping: `A-STD-001` + `A-SPEC-001` → signing configuration cleanup/project regeneration/repository scan; `A-STD-002` → research correction. `A-SPEC-002` remains Lead-owned physical evidence and cannot be satisfied by a writer inventing values.

## Current Lead decision

Issues #2 and #3 remain `integrated`. The revised 600-second physical gate passed, and `A-PHYS-001` is not a blocker under the user-approved ADR-0008 contract. Stage A is `changes-required` for the four adjudicated review IDs above; Issues #4–#10 remain blocked until their remediations and Lead verification accept Stage A. Setter success still does not verify A/B, and no exploit or alternate backend is introduced.

## Post-review Lead disposition

- `A-STD-001` and `A-SPEC-001` were remediated by moving the real signing value to ignored `Config/Signing.local.xcconfig`, committing only the include shim, regenerating the Xcode project, and verifying that no team identifier or private signing material is tracked.
- `A-STD-002` was remediated by narrowing the research wording to the tested-and-rejected automatic-pausing hypothesis rather than presenting it as a runtime requirement.
- `A-SPEC-002` retains one evidence limitation: the exact values displayed during the original GPX baseline were not reconstructed. The signed physical GPX match and post-stop recovery were directly observed, and the later public-device gate supplied stronger fresh-observation evidence with 20 matches at 0.00 meters over 618.1 seconds. On the user's instruction to stop treating non-product evidence repetition as a downstream blocker, the Lead accepts this limitation without inventing the missing original readout.
- Final Lead status: Stage A `accepted`; Issues #2 and #3 may close. The public XCUITest gate and the explicit last-observation semantics remain required regressions for #10.
