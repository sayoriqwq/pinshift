# Personal Team app-limit options for the physical XCUITest gate

Date: 2026-07-28

## Question

Can the Issue #3 physical gate run without removing SideStore or LiveContainer when the current iPhone already has three free-profile apps installed?

## Conclusion

Not with the currently approved topology and a free Personal Team. The gate needs both the foreground Pinshift app and a UI-test process. Combining the three test methods into one method or one UI-test bundle does not combine those two processes or remove the UI-test runner installation.

Apple documents that UI-test code runs in a process separate from the app under test. Apple also distinguishes UI automation from ordinary unit tests: a unit test can pass constructed locations into code under test, while a UI-automation test sets the device proxy location with `XCUIDevice.shared.location`. Moving the assertions into a hosted unit test would therefore stop testing the public device-level XCUITest backend required by Issue #3.

The current free-profile device already uses its three active app slots for SideStore, LiveContainer, and Pinshift. Installing the UI-test runner requires a fourth slot. The project must not ask the user to remove either retained app.

## Supported options

1. **Use an existing paid Apple Developer team, or enroll in the Apple Developer Program.** This preserves the current iPhone and both retained apps and is the clean route within ADR 0005, which already permits either a Personal Team or an existing paid team. SideStore's documentation states that the paid program removes the free account's three-app restriction and changes provisioning expiry to one year.
2. **Amend the environment ADR to use another physical iPhone with at least two available development-app slots.** This avoids changing the current phone but is outside the approved single-iPhone baseline and therefore needs an explicit product decision before execution.
3. **Keep Issue #3 open and stop at Stage A.** This preserves the environment but does not unlock Issues #4–#10.

## Rejected or non-equivalent approaches

- **Merge the three test cases:** they already share one UI-test target and one runner; method count does not affect installed-app count.
- **Run a hosted unit test in the Pinshift app:** it can validate injected values or app logic, but it is not the public `XCUIDevice.shared.location` physical backend and does not satisfy Issue #3.
- **Run only the UI-test runner:** it removes the independently observed foreground Pinshift app and therefore cannot produce the required fresh Pinshift app observation evidence.
- **Use GPX or Simulator evidence:** useful for Issue #2 and development feedback, but neither substitutes for the physical Issue #3 gate.
- **Use another free Apple Account:** Apple describes the free allowance as up to three apps per device, so a second free account is not an evidenced way around the device limit.
- **Offload an app:** Apple documents that offloading preserves documents and data, but does not document that it releases a free-profile active-app slot or that a sideloaded app will be restored safely. It is not an evidence-backed solution for this gate.
- **Run the Pinshift app or runner inside LiveContainer:** LiveContainer avoids installing ordinary contained apps separately, but Xcode UI automation requires its own test process and Xcode-managed runner. No supported path was found for making a LiveContainer guest serve as that runner or as the independently launched app under test.
- **Use a SideStore three-app-limit bypass:** SideStore documents version-specific exploit paths, including Lara for some iOS releases. This changes the security and environment boundary, is not an Apple-supported development workflow, and is not authorized by the current ADRs or execution protocol. It may only be reconsidered after an explicit new technical decision; the Lead must not execute or recommend it as the default gate setup.

## Primary sources

- Apple, [User Interface Testing](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/testing_with_xcode/chapters/09-ui_testing.html): UI-test code runs as a separate process from the app under test.
- Apple, [Simulating location in tests](https://developer.apple.com/documentation/xcode/simulating-location-in-tests): UI automation uses `XCUIDevice.shared.location`; ordinary unit tests construct and inject location values into code under test.
- Apple, [About your developer account](https://developer.apple.com/help/account/basics/about-your-developer-account): a free Personal Team can install up to three apps per device, with seven-day App ID and provisioning limits.
- Apple, [Choosing a membership](https://developer.apple.com/support/compare-memberships/): contrasts the Personal Team workflow and Apple Developer Program membership.
- SideStore, [Frequently Asked Questions](https://docs.sidestore.io/docs/faq): describes the free-account three-app restriction, the paid-program route, and LiveContainer as a way to contain ordinary apps.
- SideStore, [Alternative/Outdated Instructions](https://docs.sidestore.io/docs/advanced/alternative): documents version-specific exploit-based three-app-limit bypasses and their prerequisites.
- Apple Support, [Check the storage on your iPhone and iPad](https://support.apple.com/en-mide/108429): describes offloading as removing the app while retaining documents and data, without claiming it releases a free-profile app slot.

## Lead disposition

No implementation changes follow from this research. Issue #3 remains the only frontier and is blocked on an environment choice that can install both the Pinshift app and its UI-test runner. Issues #4–#10 remain blocked.
