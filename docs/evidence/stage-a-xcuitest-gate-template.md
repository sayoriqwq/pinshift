# Stage A public XCUITest gate evidence

This record is completed only from a full physical-device run of GitHub Issue #3. It must not contain device, account, signing, pairing, hostname, or physical-location identifiers.

## Environment

- Date and timezone:
- macOS version:
- Xcode version/build: Xcode 27.0 beta 4, build 27A5228h
- iOS version: 26.5.2
- Connection: wired
- Developer Mode confirmed: yes
- DDI compatible and usable: yes
- App and UI test runner signing result:

## Public API audit

- Setter: `XCUIDevice.shared.location = XCUILocation(location: CLLocation(...))`
- Clear: `XCUIDevice.shared.location = nil`
- SDK declaration inspected:
- Private header/selector or reverse-engineered service references found: yes / no

## Physical gate

- Test: `PinshiftUITests.testPublicLocationBackendRemainsStableForTenMinutes`
- Session start:
- Session end:
- Stable duration seconds:
- Completed A/B/clear rounds:
- Coordinate A observations matched within 15 seconds / 25 meters: yes / no
- Coordinate B observations matched within 15 seconds / 25 meters: yes / no
- Every replacement required a fresh Pinshift app match: yes / no
- Every clear read `XCUIDevice.shared.location` back as nil: yes / no
- Pinshift app identified any retained coordinate as the last observation rather than an active simulation: yes / no
- Fresh physical observation after clear (best-effort diagnostic only): observed / not observed / mixed / not evaluated
- Test result: PASS / BLOCKED
- Failure stage and redacted diagnostic, if any:

## Redaction check

- [ ] No UDID, serial, ECID, tunnel address, hostname, certificate hash, private key, pairing secret, team/account identifier, or physical coordinate is present.
- [ ] Evidence distinguishes setter acknowledgement from Pinshift app observation.
- [ ] Evidence distinguishes public proxy clear from physical Core Location recovery.
- [ ] Evidence makes no Cross-App Propagation claim.
