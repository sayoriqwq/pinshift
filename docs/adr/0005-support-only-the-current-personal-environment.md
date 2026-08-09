# Support only the current personal environment

The first round will support only the developer's current Mac, installed Xcode toolchain, and single personal iPhone, using either a Personal Team or an existing paid team for signing. The project deliberately trades portability and backward-compatibility work for a smaller focused implementation, and it will not claim support for other macOS, Xcode, iOS, device, account, or distribution environments.

## Recorded baseline

Verified on 2026-07-27:

| Component | Supported environment |
| --- | --- |
| Mac | `Mac16,12`, Apple silicon (`arm64`) |
| macOS | macOS 27.0, build `26A5378n` |
| Xcode | Xcode 26.6, build `17F113`, installed at `/Applications/Xcode.app` |
| Swift | Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`) |
| iPhone | iPhone 16 Pro, product type `iPhone17,1`, 256 GB |
| iOS | iOS 26.5.2, build `23F84` |
| Device state | Physical device; booted, manually paired, Developer Mode enabled, and Developer Disk Image services available |
| Connection | USB (`wired`) with the CoreDevice TCP tunnel connected |

Device serial number, UDID, ECID, tunnel address, and other unique identifiers are intentionally not stored in the repository.

The active command-line developer directory is currently `/Library/Developer/CommandLineTools`, not the full Xcode installation. Commands that require Xcode's device tooling must therefore select `/Applications/Xcode.app/Contents/Developer` explicitly, or report the mismatch in the project's diagnostics.

This baseline is the complete first-round compatibility target. The implementation does not need version branches, fallback behavior, compatibility shims, or test coverage for any other Mac, Xcode, Swift, iPhone, iOS, connection, signing, or distribution environment. A change to the developer's actual environment may require a new explicit decision; it does not silently expand the support promise.
