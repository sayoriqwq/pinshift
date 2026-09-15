# iPhone shortcut preparation — Issue #31

## Host preflight (2026-09-16)

- The Mac has an active console login.
- With the repository's explicit Xcode developer directory, `devicectl` reports one paired physical iPhone available. Device names and identifiers are omitted here.
- No Simulation Controller process was running at the start of this check.
- A connection probe to local TCP port 22 did not find an SSH listener. The administrative Remote Login query could not run without administrator access; this does not establish the system preference's exact value.
- `pinshift doctor` in the Nix project environment passed the device, Developer Mode, device support image, signing identity, and Controller Link identity checks. It retained the existing warning that Location and Local Network permissions must be confirmed in the iPhone app. No settings were changed.

## Baseline checks

- Before integrating implementation changes, the full Swift package test command completed with exit status 0 using the explicit Xcode developer directory.
- The existing `Tests/pinshift-command-check.py` check passed with the configured user Python interpreter.

## End-to-end acceptance

Pending: configure the iPhone shortcut and its dedicated SSH public key, then perform the physical checks in the shortcut guide. Local command tests cannot establish that iPhone Shortcuts can reach this Mac, that the user's SSH context can launch Terminal, or that the actual phone establishes Controller Link.

Do not treat the host preflight as successful remote preparation, signing renewal, installation, or location simulation.
