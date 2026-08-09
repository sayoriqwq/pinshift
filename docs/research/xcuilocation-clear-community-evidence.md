# Community evidence for `XCUIDevice.location = nil` on physical iPhone

Research date: 2026-07-28

## Question

When a physical-device UI test sets `XCUIDevice.shared.location = nil`, is a target app guaranteed to receive a fresh physical `CLLocation` promptly, and does retaining the last simulated coordinate indicate a local device fault?

## Method

The configured background research route was unavailable, so the Lead performed the research directly rather than silently substituting another model. The review covered Apple documentation and release notes, Apple Developer Forums, Patrol and Appium source/issues, and older physical-device reports. It separates two observable facts:

1. the XCTest proxy is absent; and
2. Core Location has delivered a newer physical observation to an app.

## Primary-source findings

- Apple defines [`XCUIDevice.location`](https://developer.apple.com/documentation/xcuiautomation/xcuidevice/location) as a nullable proxy. With no proxy, the test uses the physical location Core Location provides; Apple does not promise that assigning nil invalidates the last location, forces a delegate callback, or imposes a callback deadline.
- Apple defines [`CLLocationManager.location`](https://developer.apple.com/documentation/corelocation/cllocationmanager/location) as the most recently retrieved location and warns that it may be old. An app can therefore retain B after the proxy becomes nil until a newer fix exists.
- Apple's [Simulating location in tests](https://developer.apple.com/documentation/xcode/simulating-location-in-tests) documents controlled simulated input, not reset-to-physical timing.
- An accepted Apple engineer response on [Testing Significant Location Change](https://developer.apple.com/forums/thread/814449) explains that simulated and physically travelled location behavior are not equivalent. It is supporting boundary evidence, not a statement about `XCUIDevice.location` specifically.
- The [Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes) contain no listed matching regression.

## Community implementation evidence

- [Patrol's public iOS implementation](https://github.com/leancodepl/patrol/blob/bd16eff2249cd307c99df47cb7b6e0474793705a/packages/patrol/darwin/patrol/Sources/PatrolImpl/AutomatorServer/Automator/IOSAutomator.swift#L3734-L3761) sets an `XCUILocation` and stops by assigning nil. It does not wait for or require a fresh physical callback as part of clear.
- [Appium's simulated-location methods](https://github.com/appium/appium-xcuitest-driver/blob/master/docs/reference/execute-methods.md) define reset and getter behavior in terms of simulated state, not an arbitrary app's next physical callback.
- A real-device Appium report on iOS 17.6 says [Maps retained a mocked location across new sessions, full reset, and WDA uninstall](https://github.com/appium/appium/issues/20589). It does not prove explicit nil readback, but it shows stale-looking behavior is not unique to this phone.
- An older physical-device report says [Xcode-simulated location remained after disconnect and Location Services toggling](https://stackoverflow.com/questions/44343841/simulate-location-only-in-simulator). It is historical supporting evidence, not an exact reproduction.

## Comparison with local evidence

The current device produced both outcomes under the same implementation: several clears yielded a non-simulated observation, while other clears retained B. In every instrumented failure the public getter read back nil, the Pinshift app retained B's exact prior timestamp and simulated-source diagnostic, and no Core Location error appeared. Disabling automatic pause did not change the failure.

This is consistent with an absent proxy plus nondeterministic physical update delivery. It does not show that the proxy remained active.

## Verdict

- This is not established as an Apple API correctness bug or an Xcode 27 beta regression.
- No evidence supports classifying it as a fault unique to this phone.
- The former Issue #3 gate was defective because it treated proxy removal and a later physical observation as one atomic operation.
- ADR-0008 therefore defines public clear by nil getter state. A fresh physical observation remains best-effort diagnostic evidence and cannot become a fixed-deadline gate without a separate supported contract.
