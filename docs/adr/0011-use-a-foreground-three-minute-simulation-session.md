---
status: accepted
---

# Use a foreground three-minute simulation session

Pinshift uses one explicitly started foreground Simulation Controller only while testing, with in-memory state and a fixed three-minute Automatic Clear. Manual Clear, deadline Clear, and normal session exit each perform a real Injection Backend clear and report failure instead of claiming a successful no-op; failed cleanup is retried manually, not persisted or delegated to launchd. The installer removes the former persistent authorities because their always-running process and durable retry state polluted the Mac while still allowing false cleanup success. This decision supersedes ADR-0010.
