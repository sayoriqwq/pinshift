# Durable controller trust and full-screen location picker

> 历史实现规格。v1.1.0 已退役旧常驻项与数据迁移兼容，doctor/clear 统一由 `pinshift` 分发；当前要求以 [使用指南](../../GUIDE.md) 与 [ADR-0012](../adr/0012-establish-v1-1-baseline.md) 为准。


Status: Implemented and accepted as a pre-1.0 milestone

Date: 2026-07-28

This is a historical implementation requirement, not a Pinshift product-version declaration.

The independent picker, map-center submission and Done requirements below are superseded by
[issue #24](https://github.com/sayoriqwq/pinshift/issues/24): selection now happens directly on the
main native map. The full-screen, trust-preservation and select-without-applying guarantees remain.
Current owner acceptance is tracked in [the #24 checklist](../evidence/spec-24-owner-acceptance.md);
this older milestone does not certify the new implementation.

## Motivation

The first-round journey worked on the supported personal Mac, Xcode Beta, and iPhone, including Cross-App Propagation observed in QQ. Two usability defects remained:

1. Starting the Mac controller can require repeated Keychain password approvals even though the iPhone and Mac were already paired.
2. The Pinshift app is rendered inside a vertically letterboxed compatibility area. The location picker places its map-selection action below the visible map, and dragging to reach it can accidentally dismiss the picker.

The supplied failure screenshot measured `1206 × 2622` pixels with continuous black center-column regions at rows `0–405` and `2215–2621`, approximately 15.5% of the display at each edge.

## Scope

### A. Durable trusted controller

The existing trust model remains in force:

- The iPhone explicitly pairs with one Trusted Controller using a short-lived six-digit code.
- The iPhone retains the controller identity in Keychain.
- The Mac retains the paired Pinshift app authorization in Keychain.
- The Controller Link is started explicitly for a testing session and reconnects automatically while it is running.

The daily controller commands must use a stable, fixed-identifier, code-signed controller executable instead of a changing `swift run` development product. Rebuilding the same controller with the same signing identity must preserve its macOS identity for Keychain access-control evaluation.

The repository-local workflow must provide an explicit installation or update command for the signed controller. Daily `pinshift-start`, `pinshift-doctor`, and `pinshift-reset` commands must not compile or re-sign the controller.

Migration must preserve the existing TLS controller identity and iPhone trust whenever Apple-supported Keychain access-control APIs permit it. The implementation must never silently delete or replace the identity. If preservation is impossible, it must stop and require an explicit decision before any new pairing.

The implementation must not:

- grant arbitrary applications access to the controller private key;
- use `security create-keypair -A` or an equivalent allow-all ACL;
- store a Keychain password, signing private key, device identifier, or pairing secret in the repository;
- change global `xcode-select` state;
- install an always-running daemon or LaunchAgent as part of this change.

### B. Full-screen Pinshift app and safe map selection

The Pinshift app must declare a supported iOS launch screen and render across the full physical iPhone display without the observed top and bottom compatibility bars.

The location picker must:

- use the full available app presentation area;
- remain open during downward map or scroll gestures and close only through an explicit action;
- keep `Done` visible without scrolling;
- expose the map-center selection action in the initial map viewport;
- make the central blue `+` a real, accessible, minimum-size interactive control that selects the current map center;
- preserve place search and its existing Selected Location semantics;
- continue to select without applying automatically.

The main form may keep its current information architecture. A broad visual redesign, history, favorites, routes, and background behavior are outside this change.

## Required feedback loops

### Controller trust

Automated checks must prove that:

- the installed controller has a stable identifier and a non-ad-hoc signing requirement;
- two builds signed with the same configured identity produce equivalent designated requirements;
- all three daily helper commands resolve the installed controller and do not invoke `swift run`;
- missing, unsigned, stale, or differently signed controller installations fail with actionable recovery rather than silently falling back.

The final Mac checkpoint is two consecutive `pinshift-start` sessions after the one-time migration. Neither session may request a Keychain password, and the already-paired Pinshift app must reconnect without entering a new six-digit code.

### Full-screen UI

Automated checks must prove that:

- the built app contains an accepted launch-screen declaration;
- the location picker opens in the intended full-screen presentation;
- the map-center `+`, `Done`, and map are hittable without scrolling;
- tapping `+` produces the existing map-selection confirmation;
- a downward gesture does not dismiss the picker;
- the existing map/search selection and Selected → Applied → Observed → Verified behavior remains intact.

The final iPhone checkpoint is a fresh build and install followed by a screenshot and interaction pass: no compatibility bars, no hidden map action, no accidental dismissal, and successful application of a map-selected coordinate.

## Delivery order

1. Commit this requirement baseline before implementation.
2. Add red-capable automated checks for the controller and UI defects.
3. Implement stable controller installation and conservative Keychain ACL migration.
4. Implement launch-screen and location-picker corrections.
5. Run all Swift, CLI, project-generation, signing, UI, and privacy checks.
6. Install the updated Pinshift app and signed controller, then perform the two final personal-environment checkpoints.

## Acceptance

This milestone was accepted only after both sections passed. A working UI did not waive repeated Keychain prompts, and a durable controller identity did not waive the full-screen and map-interaction requirements.
