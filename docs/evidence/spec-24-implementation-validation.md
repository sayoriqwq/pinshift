# #24 implementation validation

Validation date: 2026-09-12. This record separates automated implementation checks
from the physical acceptance still required in #21 and #23.

## Automated checks

- All 180 Swift tests passed: 9 diagnostics, 19 simulation controller, 44 domain,
  25 controller link, and 83 CLI tests. Coverage includes signing/install recovery,
  request replay identity, cleanup retry ordering, process exclusion, and normal
  versus forced shutdown. The signal test waits for child-process readiness and
  cleanup-start handshakes, with a bounded watchdog.
- All 21 regular simulator UI cases passed across targeted batches: 14 in the
  remaining-suite run, 3 diagnostic/language cases, 1 native-share-sheet rerun,
  2 saved-location cases, and the final saved-location selection/deletion rerun.
  Coverage includes map/search selection, Applied A versus Selected B,
  replacement, clear failures, localization, large text, permission recovery,
  diagnostics, and saved-location persistence and failure handling.
- Standards and specification reviews completed. Their signing recovery,
  superseded Apply replay, and unused Home-property findings were corrected.
  The subsequent UI harness review retained all behavior assertions. Initial
  failing batches and their targeted successful reruns are retained as evidence;
  this is not a claim that one uninterrupted full UI run passed.

The UI harness resets launch environment and arguments between test instances,
starts its controller fixture when saved-location tests need acknowledgement,
and scopes More-panel saved-row queries to that panel. Small scrolling steps
avoid skipping lazy list rows. Diagnostic export checks the native share sheet.
These corrections do not weaken the selected/applied, persistence, or failure
recovery assertions.

## Device evidence and limits

After the owner authorized physical testing, the final controller Release build
was signed and installed, and the App was renewed and installed in place on the
iPhone. Existing trust was retained. The owner confirmed the connected state;
authorized App–Mac status round trips and a real normal-exit Clear acknowledgement
were recorded. See the [connection record](spec-24-connection-preflight.md).

The full 180-second physical journey, sleep/lock/disconnection recovery, fresh
location observation, accuracy, and propagation to other apps are not certified.
The opt-in ten-minute UI journey and automated physical-device test cases were
not part of this simulator run. #21 and #23 remain open.

Private raw logs and device diagnostics are retained locally outside the Git
repository. This public record omits device identifiers and precise locations.
Follow the [owner checklist](spec-24-owner-acceptance.md) for the remaining work.
