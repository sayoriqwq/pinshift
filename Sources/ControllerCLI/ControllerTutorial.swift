public enum ControllerTutorial {
  public static let output = """
    Pinshift setup and use

    1. Install the approved full Xcode, open Xcode once, and finish first-launch setup.
    2. Connect and unlock the iPhone. Confirm Trust on both the Mac and iPhone if prompted.
    3. Enable Developer Mode in iPhone Settings > Privacy & Security and complete the restart confirmation.
    4. Open the app project in Xcode and enable automatic signing for a development team. A Personal Team build may need to be rebuilt and reprovisioned every seven days.
    5. Build, install, and launch Pinshift on the iPhone from Xcode.
    6. Keep the private Active Test Device selector in PINSHIFT_DEVICE or pass it with --device. Keep the approved Xcode Contents/Developer path in PINSHIFT_DEVELOPER_DIR or pass --developer-directory.
    7. Run `pinshift-controller doctor` to check the read-only Xcode/devicectl workflow. Doctor never changes system or device settings.
    8. Run `pinshift-install` once to build and authorize the stable signed controller and persistent Cleanup Guardian, then use `pinshift-start` for daily sessions.
    9. In the app, allow Location and Local Network access, pair with the short-lived code, and choose a location.
    10. Choose 15, 30, or 60 minutes and tap Apply. Use the active card to see the authoritative deadline, extend by 15 minutes, or return to normal location behavior. Verify remains separate observation evidence, and a fresh physical callback after clear is not guaranteed immediately.

    The 15-minute default Simulation Lease is independent of Controller Link duration. The launchd Cleanup Guardian requests clear at lease expiry, orderly server shutdown, or after 30 seconds without the server-owner heartbeat when the Mac and Active Test Device are reachable. Apply is blocked unless that Guardian reports ready. `pinshift-install` preserves the existing Keychain identity and stops before mutation if the signing requirement changes. The production Injection Backend is Xcode's public devicectl location workflow. Device selectors, signing details, and pairing material stay private.
    """
}
