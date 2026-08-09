# Stage A GPX baseline evidence

This record captures GitHub Issue #2 evidence without device or account identifiers.

## Environment

- Date and timezone: 2026-07-27 to 2026-07-28, Asia/Shanghai
- macOS version: 27.0 (beta)
- Xcode version/build: Xcode 27.0 beta 4, build 27A5228h
- iOS version: 26.5.2
- Connection: wired
- Developer Mode confirmed: yes
- DDI compatible and usable: yes
- Signing result: success

## Matching observation

- GPX fixture: `Fixtures/ShanghaiBaseline.gpx`
- Selected latitude: `31.2304`
- Selected longitude: `121.4737`
- Observation window start: initiated in the foreground immediately before selecting the GPX fixture; exact timestamp was not retained
- Observed timestamp: 2026-07-28 00:05:11 Asia/Shanghai
- Elapsed seconds: no more than 15 seconds; exact displayed value was not retained
- Distance meters: no more than 25 meters; exact displayed value was not retained
- Horizontal accuracy meters: 5.0
- `isSimulatedBySoftware`: true
- App result: matched

The simulated-source flag is diagnostic only. A passing result requires a fresh observation no more than 15 seconds after the request and no more than 25 meters from the selected coordinate.

## Stop and recovery

- Time GPX simulation stopped: after the matching run; exact timestamp was not retained
- Time a non-target location was next observed: after opening a location consumer and allowing Core Location to recover; exact timestamp was not retained
- Target coordinate no longer observed: yes
- Notes: Core Location briefly reported `locationUnknown` after GPX stopped. The Pinshift app retained the last successful observation, then received a non-simulated update and displayed the simulated-source diagnostic as `No`.

## Redaction check

- [x] No UDID, serial, ECID, tunnel address, hostname, certificate hash, private key, pairing secret, or account identifier is present.
- [x] The evidence only claims that the Pinshift app observed the result; it makes no Cross-App Propagation claim.

## Evidence limitations

The exact elapsed and distance values from the successful screen were not retained. The `matched` result is produced only when the observation timestamp is newer than the request, elapsed time is no more than 15 seconds, and distance is no more than 25 meters. This record therefore preserves the verified thresholds without inventing exact measurements.
