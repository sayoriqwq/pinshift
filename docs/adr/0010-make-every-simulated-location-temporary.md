---
status: superseded by ADR-0011
---

# Make every simulated location temporary without blocking replacement

Every successful Apply creates a Temporary Simulation with one fixed 15-minute automatic-clear deadline. Duration is not user-configurable. Retrying the same Apply returns its original deadline; a genuinely new Apply replaces any active, uncertain, or clear-retrying state and receives a fresh deadline.

One persistent Mac Simulation Controller owns Controller Link, durable current state, backend serialization, and automatic clear. Apply, Clear Now, automatic clear, restart reconciliation, and legacy migration pass through the same serialized authority. Operations carry identity and Clear Now targets the operation visible when it was requested, so a late clear or old timer cannot erase a newer Apply.

Historical state is never an Apply precondition. The iOS app persists only Selected Location and Trusted Controller data, treats Clear Now as a transient convenience, ignores stale responses, and replaces its display with the Mac snapshot after reconnect or relaunch. A failed or lost clear response may be shown, but selection and replacement Apply remain interactive.

The physical boundary remains: public `devicectl` clear requires the Mac and Active Test Device to be reachable. When either is unavailable at the deadline, the Mac retains the automatic-clear responsibility and retries at the first reachable opportunity. Legacy app control state is discarded while Saved Locations and trust survive; legacy Mac lifecycle state becomes an immediate non-blocking clear attempt.

This decision replaces the earlier configurable Simulation Lease, Cleanup Guardian, server heartbeat, durable iOS Stop Intent, and Apply-readiness gate formerly recorded in ADR-0010.
