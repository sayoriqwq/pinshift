# Support only the current personal environment

Pinshift supports one developer-owned Apple Silicon Mac, its configured full Xcode 27 toolchain, and one paired personal iPhone, signed with a Personal Team or existing paid team. This deliberately trades portability and backward compatibility for a smaller implementation; other system, device, signing and distribution combinations are not implied support targets.

Xcode commands select the configured developer directory explicitly without changing global xcode-select. Toolchain or map-environment changes require targeted re-verification. Local team, certificate and device identifiers stay outside committed project settings.

Persisted input must already use selection schema 3 or saved-location schema 2 with WGS84 coordinates. Unsupported formats are rejected without conversion or erasure, keeping ambiguous historical coordinates out of current Apply requests and avoiding a second maintained migration path.
