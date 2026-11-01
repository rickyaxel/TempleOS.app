# Release readiness

Assessment as of 2026-10-16. Severity: **P0** blocks any release, **P1** must
be resolved before a store submission, **P2** should be resolved, **P3** nice
to have.

> Historical assessment. How store releases are made now: [releasing.md](releasing.md).
> The verification-pass report cited below was not published with this repository.

## 1. Summary

> **Superseded by the independent verification pass of 2026-10-16:**
> `docs/verification-pass/RELEASE_READINESS.md`. Verdict: *conditionally ready*
> (CONDITIONAL PASS). Release is blocked by C1–C6 there: device testing,
> signing, license, branding, the `HSNotes.DD` content decision, and the
> store-review strategy.
>
> That pass found and fixed 4 P0 memory-safety bugs in the Swift VM, 7 P1
> defects (among them broken arrow-key controls in 17 games and an idle redraw
> loop), and 12 P2 issues.

Both apps build, run and pass their automated tests. The acceptance flow passes
end to end on the iOS simulator (XCUITest). The full 43-step smoke journey was
performed on the Android emulator in airplane mode. The apps are **not yet
ready for store submission**: physical-device testing, signing, the project
license and the content and branding decisions are outstanding.

## 2. Open items

| # | Severity | Item | Owner action / next step |
|---|---|---|---|
| 1 | P1 | **No physical-device testing.** The attached Android phone (OPPO CPH2669) was locked; no iPhone was attached. Performance, audio, keyboards and lifecycle are only verified on emulator/simulator. | Unlock/attach devices and repeat the acceptance flow and `performance.md` measurements. |
| 2 | P1 | **Project license: resolved.** The project's own code is released under the Unlicense (`LICENSE`); examples labelled "same license as the TempleOS Mobile project" refer to it. | None. |
| 3 | P1 | **Release signing.** Android release builds are signed with the debug key; the iOS project has no signing team. | Configure an upload key (Play App Signing) and an Apple team. |
| 4 | P1 | **Name and branding review.** "TempleOS Mobile Classic" is a working title. | Trademark/branding review before publishing. |
| 5 | P3 | **Offensive language in original files** — resolved (2026-10-18): a full content audit and the moderation manifest `tools/resource-packaging/moderation.json` censor or redact slurs and derogatory statements about groups of people in six files with visible markers when the drive is packaged; policy, findings and items left for editorial review in `docs/content-moderation/CONTENT_MODERATION.md`. | A broader human content review before store submission. |
| 6 | P2 | **Store review of code execution.** The app interprets user-typed and bundled HolyC; nothing is downloaded. | Prepare review notes (see `offline-release-specification.md` §5). |
| 7 | P2 | **Compatibility gaps**: 15 catalog programs unsupported (hidden from menus), 3 partial (Titanium, Talons, PredatorPrey). | Optional: DolDoc document API, sprites in documents would unlock most of them. |
| 8 | P2 | **Accessibility**: the desktop is one custom view; screen readers get a single element. | Expose menu items/buttons as accessibility elements. |
| 9 | P2 | **Program start time** 0.5–1.1 s (prelude compiled per program). | Compiled-prelude snapshot. |
| 10 | P3 | Float last-bit differences between platforms (3 of 91 frames). | Shared deterministic math (fdlibm port) if exact parity is required. |
| 11 | P3 | Pinch-zoom, joystick, configurable controls not implemented (`native-ui-design.md` §8). | — |
| 12 | P3 | Store assets (screenshots, descriptions, privacy labels/data-safety form) not prepared. | Data safety: no data collected. |

No P0 items are known.

## 3. What is verified

| Requirement | Evidence |
|---|---|
| Builds (Kotlin debug + release, Swift package, iOS app Debug + Release) | `testing.md` §4 commands; all succeed |
| Automated tests | Kotlin 31 (24 active + 7 diagnostics), Swift 14 + sweep, iOS XCUITest 2: all pass |
| Offline, no network, no import paths | offline audit: all checks pass; airplane-mode first launch on the emulator |
| HolyC conformance | 16 shared vectors pass on both runtimes |
| Original programs | catalog sweep: same status on both runtimes for all 96; 88/91 frames identical |
| Security model | `security-model.md`; StkOver/BadMem/DivZero vectors; filesystem traversal tests |
| Provenance | `licensing-and-provenance.md`; bundled files byte-identical to the ISO except 6 moderated files (`content-moderation/CONTENT_MODERATION.md`); questionable file (FontCyrillic.HC) excluded |

## 4. Next release steps

1. Device testing (item 1) and fixes found there.
2. License, signing, branding decisions (items 2–4).
3. Content review (item 5) and review notes (item 6).
4. Store listing assets (item 12).
