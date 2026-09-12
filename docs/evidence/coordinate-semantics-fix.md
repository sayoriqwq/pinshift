# Coordinate semantics repair (#29)

## Contract and supported map environment

`SelectedLocation`, new saved values, Apply requests and Core Location observation comparisons use WGS84. `MapLocationCoordinate` is a separate type for raw map values and cannot be passed directly to an Apply request.

The owner's original landmark A/B experiment found a geographic mismatch despite numerically identical App, Mac and fresh software-location values. An independent WGS84 reference appeared at the landmark in QQ but in the river on Pinshift's map. A MapKit search value produced the opposite mismatch. That evidence identifies the map ingress/egress boundary in this environment; it is not a universal statement about MapKit or other apps.

The internal verified Shanghai map adapter applies an approximate GCJ-02 transformation in the verified working area (WGS84 latitude 30.7–31.6, longitude 120.9–122.0). It normalizes map input to WGS84 and projects WGS84 values for map display. Inverse lookup includes the slightly displaced image of that area, so map values crossing its numeric bounds still round-trip. Coordinates outside the area pass through. The narrow area is an explicit support limit, not a mainland-China boundary or a fixed offset fitted to one landmark. Other mainland areas and the transition outside this area remain unverified.

The app chooses its map adapter internally for the supported personal environment. There is no coordinate-system picker or bookmark-source choice. It does not infer a provider from language, SIM, IP address or the injected location; a provider/environment change requires a new engineering validation rather than a user-facing technical setting.

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

Previously confirmed WGS84 bookmarks (including the owner's A/B acceptance records) remain usable without any prompt. An ambiguous older bookmark instead asks the user to choose the place again on the map or through search, then explicitly **Update bookmark**. This preserves its name, identity, order and original value. Cancellation or a failed save leaves the bookmark unchanged; no simulation is applied. The source-selection UI and its globe button have been removed. Existing interpretation metadata is still decoded for compatibility with the acceptance build, but is not presented as a product choice.

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

## Post-fix physical B result

On 2026-09-13 at approximately 00:54 CST, the owner selected B, confirmed its original WGS84 source, and applied it. Private App/Mac records correlate the same operation: the saved original value, selection, received request, backend arguments and fresh software-simulated sample agree numerically; the new sample arrived 0.738 seconds after the request. The saved collection is now version 2 and records B's WGS84 interpretation while retaining the original value.

The owner's 00:54 Pinshift and 00:55 QQ screenshots both show the Oriental Pearl landmark vicinity. Pinshift no longer draws B in the river. This passes B's landmark-level display/cross-app check in the current environment. Different zoom/markers and QQ's “within 100 m” label do not measure residual error; no metre-level accuracy is claimed. Screenshots and operation identifiers remain private.

## Post-fix physical A result

On 2026-09-13 at approximately 01:00 CST, the owner's A screenshots also show both apps at the Oriental Pearl vicinity. Private saved data confirms the legacy map value was normalized with `verifiedShanghai` and the original retained. Same-operation records agree across selection, received request, backend arguments and a fresh software-simulated sample arriving 0.485 seconds after the request; the maximum numeric difference was below 0.001 m (backend encoding), not a measurement of geographic accuracy. A therefore passes the landmark-level legacy-map-input check, complementing B's WGS84-input/display check.

## Acceptance scope accepted by the owner

The owner declined further detailed physical testing after A/B passed. Nearby-landmark and non-mainland physical controls were not run, and remain evidence limits rather than requested next steps. No five-metre or universal regional guarantee is claimed. #21 and #23 are not closed by this change.

After that decision, the coordinate-mode and bookmark-source selectors were removed. The existing coordinate regressions passed again; the replacement bookmark-update flow is checked by focused App/UI tests before delivery.
