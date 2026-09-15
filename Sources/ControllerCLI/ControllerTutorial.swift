public enum ControllerTutorial {
  public static let output = """
    Pinshift setup and use

    1. Install the approved full Xcode, open Xcode once, and finish first-launch setup.
    2. Connect and unlock the iPhone. Confirm Trust on both the Mac and iPhone if prompted.
    3. Enable Developer Mode in iPhone Settings > Privacy & Security and complete the restart confirmation.
    4. Open the app project in Xcode and enable automatic signing for a development team. A Personal Team build may need to be rebuilt and reprovisioned every seven days.
    5. Build, install, and launch Pinshift on the iPhone from Xcode.
    6. Keep the private Active Test Device selector in PINSHIFT_DEVICE or pass it with --device. Keep the approved Xcode Contents/Developer path in PINSHIFT_DEVELOPER_DIR or pass --developer-directory.
    7. Run `pinshift doctor` to check the read-only Xcode/devicectl workflow. Doctor never changes system or device settings.
    8. Run `pinshift setup` once to build and authorize the controller. Run `pinshift` when testing: it checks App signing, renews when needed, and attempts startup residual cleanup before serving the app. Follow any requested Apple login or iPhone confirmation. Keep that terminal open. Ctrl-C waits for a real Clear before exit; if cleanup remains unconfirmed, keep the iPhone reachable or press Ctrl-C again to explicitly force exit.
    9. In the app, allow Location and Local Network access, pair with the short-lived code, and choose a location.
    10. Tap Apply. Every location is temporary for 3 minutes, and the active card shows its automatic-clear deadline. You can choose and Apply another location at any time; the latest Apply replaces the previous one. Clear Now stays visible even without an active record and always reaches the backend. Verify remains separate observation evidence, and a fresh physical callback after clear is not guaranteed immediately.

    One foreground test session owns Controller Link, in-memory simulation state, and automatic clear. A failed Clear is reported honestly and automatically retries with bounded backoff while this foreground session lives; Clear Now also remains available from the app. Cleanup is not persisted as background work. Normal exit waits until cleanup is acknowledged; forced exit warns that cleanup is unconfirmed, and the next explicit startup attempts real residual cleanup. Historical state never blocks a new Apply. `pinshift setup` preserves the existing Keychain identity and stops before mutation if the signing requirement changes. The production Injection Backend is Xcode's public devicectl location workflow. Device selectors, signing details, and pairing material stay private.
    """
}
