# Use a foreground three-minute simulation session

Pinshift uses one explicitly started foreground Simulation Controller only while testing, with in-memory state and a fixed three-minute Automatic Clear. Manual Clear, deadline Clear, startup recovery, and normal session exit each perform a real Injection Backend clear; success requires its acknowledgement and does not prove physical location refresh in other apps (ADR-0008).

Failed cleanup remains pending and retries within the living foreground session with exponential delays from one second, capped at thirty seconds. Clear and Apply share the existing serial operation queue; scheduled cleanup carries a generation checked after entering that queue so an obsolete deadline or retry cannot clear a later Apply. Historical cleanup failures do not block a new valid Apply.

A process-held advisory lock in the user’s owner-only Application Support directory admits only one foreground session before startup cleanup. The lock file is never unlinked, and the operating system releases ownership on process exit, including force exit; no PID or durable cleanup state is stored.

Every explicit foreground startup attempts real residual cleanup even without a local simulation record. A failure stays visible and retryable while the server becomes available. Normal exit closes the controller’s Apply gate under the same operation queue, so already accepted connections cannot apply after shutdown cleanup. It then waits for acknowledged cleanup, retrying with the same bounded delays. A second termination signal explicitly forces exit with an unconfirmed-cleanup warning; the next explicit startup is the recovery entry point. No cleanup is promised after force exit, a crash, power loss, or while the Mac cannot execute.

Cleanup responsibility is not persisted or delegated to launchd. A foreground session keeps state and retries bounded to explicit testing, avoiding an always-running authority on the Mac. The installer handles only the current foreground controller and performs acknowledged real Clear before publishing its signed binary.
