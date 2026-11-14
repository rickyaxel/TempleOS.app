# Hierarchical language resolution

Verified against source: 2026-11-03; `hierarchical-locale-v1`.
[localization.md](localization.md) owns the catalog and pixel UI details. The website
repository's `docs/hierarchical-language-resolution.md` owns trusted geography and
HTTP policy; neither mobile app calls it at startup or depends on asmr.education.

The actual targets are Swift `temple_os_swift/TempleCore` with UIKit in
`temple_os_swift/App`, and Kotlin `temple_os_kotlin/core` with the framework Activity
in `temple_os_kotlin/app` and existing `purekotlin` execution target. Localization
continues to use the shared bundled JSON catalogs, not a new SwiftUI or AndroidX
architecture. No HolyC source, interpreter, pixel font or Unicode encoding changed.

Both resolvers choose a language before a variant: saved session choice, detectable
OS app choice, ordered preferences, optional trusted territory/country, default.
Within a language/script: supported exact explicit regional pin, compatible trusted
country, compatible regional preference, configured device region as a preference,
then family default/generic. The device region never supplies Stage 1 geography.
A singleton family returns its one resource directly. Inputs are bounded and exact,
prefix and country/family indexes are constructed once at catalog initialization.

The manifest has 89 identities over 73 actual catalogs. All English variants share
a catalog; all Spanish variants share `es`; `pt-PT` uses the existing `pt-BR` text;
French Canadian, regional Malay and Persian share their families' catalogs.
Chinese has distinct Simplified and Traditional resources; Hong Kong shares
Traditional. Those limitations are real, not new translations. The website has
additional regional catalogs and should not be used to infer native availability.

`shared/runtime/l10n/regional-policy.json` versions the policy, script constraints,
Catalan country/territory lists, ambiguous-country list and disabled whole-Valencia
switch. Catalonia ES-CT, Balearics ES-IB and Andorra AD can default to `ca` only when
higher preferences are unusable. ES-AR, ES-MC, FR-OCC and IT-88 never imply the
smaller Catalan-speaking areas. Valencian uses `ca` if explicitly configured; no
new catalog or unrelated-language label is introduced. There is no precise city or
postal source and no such rule is enabled.

Production native callers supply **no geographical hint**. These optional inputs
exist for shared deterministic semantics and future trusted integrations, not a
hidden geolocation mechanism. Automatic Catalan works offline when preferred by
the OS; Catalonia cannot be inferred merely from a device's configured region.
Startup, catalogs, session restoration and programs remain fully offline.

Swift reads ordered Locale.preferredLanguages and, when exposed in the app domain,
AppleLanguages through public UserDefaults APIs. It never writes that key. Session
`g=` remains the product's manual override; System clears it and respects the OS.
No universal Apple API distinguishes all app-override provenance; the effective
ordered OS list remains the fallback. Existing foreground/locale presentation
paths reapply localization without rewriting the shell session's manual choice.

Android API 33+ uses framework LocaleManager, appropriate to this Activity-based
app with no AndroidX dependency. In-app selections update application locales and
the existing session `g=`; external OS changes/reset reconcile during configuration
changes. A one-time `language_platform/synced` marker migrates a legacy session
choice only if the OS has none. API 24–32 retain the manual session and ordered
configuration locales. No global locale mutation or Activity recreation loop is
introduced. Active windows/input and program execution retain their existing owners.

To add a locale/resource, update the manifest/catalog, regenerate platform language
lists with `tools/l10n/gen_platform.py`, run validation and test real text rendering.
To add a territory, require trustworthy data at the correct granularity, update the
versioned policy and website counterpart, and add positive/negative shared vectors.
Do not enable a broad region as a substitute for missing precision. Keep policy and
catalog inventories independent; no network service is required to share semantics.

Validation: `swift test` (selected L10n, language-list, localization, shell and app
behavior suites); Gradle core localization tests and `:app:assembleBench`; the shared
`shared/test-vectors/l10n/hierarchical-v1.json`; iOS simulator selector/persistence
journeys; Android hardware bench selector/persistence and resource checks. Platform
and Xcode generators are checked; `tools/l10n/validate.py` validates the regional
artifact as metadata, not a catalog. Public-tree checks retain machine/device data
outside the repository. Exact commands and final results are in the accompanying
cross-repository report. No physical iPhone or mobile publishing was performed.

## Verification on 2026-11-04

The selected Swift core suites passed 52 tests; Kotlin core localization passed 35.
The final iOS simulator app build, both resource/project generators, catalog validation
and the public-tree check passed. Validator tests passed all four cases. The iOS
device-language/manual/Automatic journey passed. The full five-locale list-order UI
run encountered an Apple automation logging-stack crash; an English-only retry passed.
That broader automation run is not claimed as successful.

Physical Android API 34 passed the actual picker/persistence/Automatic journey and
expanded Catalan, Spain Spanish, Mexican Spanish, Portugal Portuguese and Hong Kong
Chinese journeys. These included rotation, Settings, language rows, God Words, About,
Files, editor, games, a running program/dialog and background/resume. Separate OS
application-locale changes to Catalan and Mexican Spanish refreshed an already open
menu; resetting the OS app locale restored English and survived process restart.
API 29 emulator checks also rendered Catalan menus and Settings. Device identifiers,
screenshots and raw logs remain outside this public repository. No native-speaker
translation review or exhaustive all-device verification is claimed.
