# Xcode 27 devicectl backend probe — 2026-07-28

This record contains only redacted physical-device evidence supporting ADR-0009. Raw command and console logs remain local because they can contain destination and signing metadata.

## Environment

- Date and timezone: 2026-07-28, Asia/Shanghai (UTC+08:00)
- Xcode: 27.0 beta 4
- Connection: wired
- Developer Mode and developer services: available
- Pinshift app: signed, installed, and launched on the Active Test Device

## Public command audit

- Readiness: `xcrun devicectl device simulate location list`
- Apply/replace: `xcrun devicectl device simulate location coordinate`
- Stop: `xcrun devicectl device simulate location clear`
- The Xcode help describes coordinate simulation as continuing until cleared.
- Commands are invoked with discrete process arguments; no shell interpolation, private API, or undocumented service is used.

## Physical result

- Apply coordinate A: command exit 0; the Pinshift app produced a fresh observation matching A.
- Replace with coordinate B: command exit 0; the Pinshift app produced a fresh observation matching B.
- Clear: command exit 0.
- The evidence distinguishes backend acknowledgement from Pinshift app verification and makes no Cross-App Propagation claim.

## Rejected production route

The authenticated long-running XCUITest runner was attempted again after Xcode restoration. Xcode launched the runner process, but its DTX peer rejected the XCTest manager interface before the selected test method began; no product apply or stop assertion executed. Because the public `devicectl` route completed the required physical operations without that runner lifecycle, the failed route is not retained as a second production backend.

## Redaction check

- [x] No device identifier, serial, ECID, DNS name, hostname, signing account/team, certificate data, pairing code, or credential is present.
- [x] No raw `devicectl`, Xcode, or app-console log is committed.
- [x] No Cross-App Propagation or immediate physical-location recovery is claimed.
