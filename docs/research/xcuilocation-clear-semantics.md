# Public `XCUIDevice.location` clear semantics

Research date: 2026-07-28

## Question

After a physical-device UI test assigns `XCUIDevice.shared.location = nil`, what does Apple promise about clearing the proxy and resuming physical Core Location observations?

## Primary-source findings

- Apple documents [`XCUIDevice.location`](https://developer.apple.com/documentation/xcuiautomation/xcuidevice/location) as a nullable, readable and writable proxy location. When no proxy is provided, the test uses the physical location that Core Location provides. The Xcode 27 beta 4 public SDK header describes the property as “The location currently being simulated by the device, if any” and declares it nullable.
- Apple’s [Simulating location in tests](https://developer.apple.com/documentation/xcode/simulating-location-in-tests) directs UI automation to set `XCUIDevice.shared.location` to an `XCUILocation`. It does not specify a deadline for a target app to receive a physical location after the proxy becomes `nil`.
- Apple documents [`CLError.Code.locationUnknown`](https://developer.apple.com/documentation/corelocation/clerror-swift.struct/code/locationunknown) as meaning that the location manager cannot obtain a location value right now. This is a temporary availability signal, not proof that an XCTest proxy remains active.
- Apple documents [`CLLocationManager.location`](https://developer.apple.com/documentation/corelocation/cllocationmanager/location) as the most recently retrieved location and explicitly warns that it may be old. A retained last location therefore does not by itself show that a proxy is still active.
- The Xcode 27 beta 4 public Core Location SDK header documents `pausesLocationUpdatesAutomatically` as enabled by default for iOS applications. Whether that default explained the retained observation was tested as a hypothesis for `A-PHYS-001`; Apple’s documentation of the default does not establish it as the cause.

## Implications for `A-PHYS-001`

- Reading `XCUIDevice.shared.location` immediately after assigning `nil` is the public-API acceptance signal for whether XCTest still reports an active proxy. A `nil` readback satisfies backend clear but does not claim that Core Location has already delivered a newer physical observation.
- The former 60-second clear window was not an Apple-documented guarantee and is removed from the gate. A physical callback after clear remains useful diagnostic evidence only.
- If the getter reads back `nil` while the Pinshift app retains the last simulated observation, the remaining ambiguity is between delayed/no physical Core Location delivery and temporary physical-location unavailability. Capturing the latest observation timestamp and any `locationUnknown` diagnostic is the smallest public probe that distinguishes those states.
- If the getter remains non-`nil`, that is direct evidence of a public XCTest clear failure on the approved baseline and should keep Issue #3 open pending the protocol’s backend decision path.
- Disabling automatic pausing was tested as a hypothesis but did not explain `A-PHYS-001`. Under the current observer configuration, the revised 10-round/618.1-second gate passed; this is empirical evidence for that configuration, not an Apple-documented continuous-location requirement.
- The combined evidence now identifies a contract mismatch rather than a remaining app-side timing defect: proxy state can be cleared deterministically, but a fresh physical observation is owned by Core Location and is not promised as a consequence of that clear. Repeating the run, extending the timeout, or restarting observation may change empirical delivery, but none turns the fresh-callback requirement into an Apple-documented guarantee.

## Project decision

The user approved continuing with the public XCUITest backend under ADR-0008. Issue #3 now treats public proxy removal, Pinshift app observation retention, and later physical recovery as separate observable facts; only the first is the deterministic clear gate.
