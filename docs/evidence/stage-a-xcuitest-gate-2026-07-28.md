# Stage A public XCUITest gate evidence — 2026-07-28

This record contains only redacted evidence from the full physical-device run of GitHub Issue #3. The raw `.xcresult` remains local because it can contain destination metadata.

## Environment

- Date and timezone: 2026-07-28, Asia/Shanghai (UTC+08:00)
- macOS version/build: macOS 27.0, build 26A5388g
- Xcode version/build: Xcode 27.0 beta 4, build 27A5228h
- iOS version: 26.5.2
- Connection: wired
- Developer Mode confirmed: yes
- DDI compatible and usable: yes
- App and UI test runner signing result: signed, installed, launched, and completed the physical UI test

## Public API audit

- Setter: `XCUIDevice.shared.location = XCUILocation(location: CLLocation(...))`
- Clear: `XCUIDevice.shared.location = nil`
- SDK declaration inspected: yes; the public XCTest/XCUIAutomation location proxy is an optional get/set property
- Private header/selector or reverse-engineered service references found: no

## Physical gate

- Test: `PinshiftUITests.testPublicLocationBackendRemainsStableForTenMinutes`
- Result-bundle run timestamp: 2026-07-28 11:51:52 +08:00
- Final recorded gate activity: 2026-07-28 12:03:02 +08:00
- Stable duration: 618.1 seconds
- XCTest case duration including setup/teardown: 635.7638479471207 seconds
- Completed A/B/clear rounds: 10
- Coordinate A observations matched within 15 seconds / 25 meters: yes; 10 fresh Pinshift app activity records
- Coordinate B observations matched within 15 seconds / 25 meters: yes; 10 fresh Pinshift app activity records
- Recorded observation elapsed range: 0.47–0.50 seconds
- Recorded observation distance: 0.00 meters for all 20 A/B observations
- Every replacement required a fresh Pinshift app match: yes
- Every clear read `XCUIDevice.shared.location` back as nil: yes; each of the 10 round-completion activities occurs only after the nil-getter assertion
- Pinshift app identified any retained coordinate as the last observation rather than an active simulation: yes
- Fresh physical observation after clear (best-effort diagnostic only): not evaluated by the revised gate
- Test result: PASS
- Failure stage and redacted diagnostic, if any: none

## Redaction check

- [x] No UDID, serial, ECID, tunnel address, hostname, certificate hash, private key, pairing secret, team/account identifier, or physical coordinate is present.
- [x] Evidence distinguishes setter acknowledgement from Pinshift app observation.
- [x] Evidence distinguishes public proxy clear from physical Core Location recovery.
- [x] Evidence makes no Cross-App Propagation claim.
