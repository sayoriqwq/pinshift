# Coordinate semantics repair (#29)

## Contract and supported map environment

`SelectedLocation`, new saved values, Apply requests and Core Location observation comparisons use WGS84. `MapLocationCoordinate` is a separate type for raw map values and cannot be passed directly to an Apply request.

The owner's original landmark A/B experiment found a geographic mismatch despite numerically identical App, Mac and fresh software-location values. An independent WGS84 reference appeared at the landmark in QQ but in the river on Pinshift's map. A MapKit search value produced the opposite mismatch. That evidence identifies the map ingress/egress boundary in this environment; it is not a universal statement about MapKit or other apps.

The default **Verified Shanghai map** mode applies an approximate GCJ-02 transformation in the verified working area (WGS84 latitude 30.7–31.6, longitude 120.9–122.0). It normalizes map input to WGS84 and projects WGS84 values for map display. Inverse lookup includes the slightly displaced image of that area, so map values crossing its numeric bounds still round-trip. Coordinates outside the area pass through. The narrow area is an explicit support limit, not a mainland-China boundary or a fixed offset fitted to one landmark. Other mainland areas and the transition outside this area remain unverified.

**More → Map coordinate alignment → WGS84 map** disables the conversion for an environment whose map already uses WGS84. Changing this setting recreates the map/search presentation but does not rewrite the selected coordinate, saved values or active simulation. The implementation does not infer a map provider from the user's language, SIM, IP address or injected location. If the provider/environment changes, select the appropriate mode and repeat landmark acceptance.

| Entry or output | Treatment |
| --- | --- |
| MapKit search result | Raw map value crosses the selected map boundary once, before selection |
| User camera movement | Raw map center crosses the same boundary once |
| Manual input | Explicitly labelled WGS84; no map-input conversion |
| New saved location / relaunch | WGS84; no input conversion |
| Selected camera center / Applied marker | WGS84 crosses the map-output boundary |
| Back to current location | Reuses the existing WGS84 request; no Apply |
| Controller Link / backend / observation | Existing protocol and comparison semantics; no map conversion |

Coordinates remain `Double` throughout the model and saved JSON. Display formatting is not fed back into selection or sending. The existing backend's eight-decimal command encoding remains unchanged. No timer, clear, reconnect or retry code was changed.

The transform adapts the BSD-licensed [eviltransform implementation](https://github.com/googollee/eviltransform), with its notice bundled in the app. It is approximate, not an official conversion or a surveyed accuracy guarantee. Relevant source boundaries are the [Apple WGS84 coordinate contract](https://developer.apple.com/documentation/corelocation/cllocationcoordinate2d), [MapKit provider-detection discussion](https://developer.apple.com/forums/thread/787990), and [AMap's coordinate-system documentation](https://developer.amap.com/api/javascript-api-v2/guide/transform/convertfrom).

## Existing data

Saved collection version 2 marks new values as WGS84. Version 1 values remain unchanged and decode as `legacyUnknown`; names, identities and order survive. Reading an ambiguous collection creates `saved-locations.json.before-coordinate-migration` before any rewrite. A failed read or backup cannot be bypassed by saving the view model's empty fallback.

Choosing an old bookmark asks for its original source:

- **Originally chosen on the Shanghai map** normalizes the original map value.
- **Already WGS84 / independent reference** retains the original value.
- Cancel leaves selection and storage unchanged. If the source is unknown, cancel and search/select the place again, then save it under a new name.

A repaired record retains both its original value and the chosen interpretation. Its globe button in More allows another confirmation. Every repair starts from the original value, so repeated confirmation cannot double-convert a bookmark; choosing WGS84 again restores its original numbers. Save failures leave the collection and selection unchanged. These actions never apply a simulation.

Older persisted drafts also lack coordinate provenance. Their original file is retained as `session.json.before-coordinate-migration`, and the WGS84 draft schema becomes version 3. The ambiguous draft is not restored as a new WGS84 selection. A new selection remains available, and no old control state is restored.

On the owner's iPhone, the signed app was installed in place and launched on 2026-09-13. Read-back confirmed all four original saved records unchanged and both backups present. No uninstall, automatic bookmark conversion or agent-issued Apply was used for installation verification.

## Verification

- Red check: the pass-through boundary failed both geographic landmark assertions; the map/reference mismatch was about 499 m. This catches the original geographic error even when numeric transport is perfect.
- Location domain: 44 existing tests and 7 new coordinate/migration checks passed. New checks cover map input, output, public landmark correspondence, WGS84/non-Shanghai controls, 100 map round-trips, supported-area edges, mixed legacy sources and recoverable draft migration.
- Other Swift packages: 136 existing tests passed in the broader run. That run initially exposed a legacy draft decoder failure; the final location-domain run passed after fixing it.
- App integration: three tests passed against the real MapKit-result adapter, BaselineViewModel and file stores. They cover search → selection → Apply request → save → relaunch, reversible legacy repair, and prevention of overwriting an unreadable collection.
- UI: three regressions passed: legacy confirmation/cancellation/selection across relaunch, map drag changing selection only, and return to current location without reapplying.
- Signed physical iPhone build, in-place install, launch and private migration read-back passed.

These are separate runs, not one uninterrupted full-suite execution. Public fixtures use a public landmark reference/search location, without device identifiers or session logs. Raw diagnostics, screenshots, build logs and result bundles stay local.

## Remaining owner acceptance

1. Choose saved **A** and confirm its original Shanghai-map source. Apply, then compare Pinshift's landmark with QQ automatic positioning during the same operation.
2. Choose saved **B** and confirm **WGS84 / independent reference**. Apply and compare again. Both apps should show the same landmark vicinity; the search POI and building reference need not be the exact same point.
3. Repeat with a nearby Shanghai landmark and a non-mainland control, correlating each operation with a fresh sample. Record residual discrepancy rather than claiming five-metre accuracy.

The post-fix cross-app checks remain pending. #21 and #23 stay open. Passing numeric/unit checks and successful installation do not close those physical evidence gaps.
