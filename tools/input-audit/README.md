# TempleOS software input validation

The two clients render their own keyboard and editing models. Android is a non-editor View with no
InputConnection; iOS is a plain hardware responder with no text-input conformance. Full findings,
character policy, surface inventories and measured results:
Android, iOS.

From the repository root:

```sh
python3 tools/input-audit/check_input_architecture.py
python3 tools/input-audit/test_architecture_guard.py
python3 tools/input-audit/android_keyboard_ui.py SERIAL OUT/native native
python3 tools/input-audit/android_keyboard_ui.py SERIAL OUT/terry terry
python3 tools/input-audit/ios_keyboard_ui.py UDID DERIVED_DATA OUT --suite native
python3 tools/input-audit/ios_keyboard_ui.py UDID DERIVED_DATA OUT/terry --suite terry
python3 tools/input-audit/ios_keyboard_ui.py UDID DERIVED_DATA OUT/locales --suite locales
```

Build/install only the side-by-side `io.github.templeosmobile.bench` application before these commands.
Android uses `:app:assembleBench` (release plus R8). iOS requires build-for-testing with the same scheme,
Release configuration, TOS_BUNDLE_ID and development-signing team shown in the reports. For simulator
builds/runs use `--simulator --configuration Debug`. Every output/result path must be fresh.

The iOS helper passes complete string-only locale dictionaries to the runner, so the tests also run on
physical devices. `-collect-test-diagnostics never` avoids an observed Xcode simulator diagnostic-collection
stall; assertions, logs, screenshots and xcresult test summaries remain enabled. No global device language,
IME, rotation, clipboard or stay-awake settings are modified. Android's orientation/language/recreate hooks
exist only in BENCH builds. Tests control only that package and their test runner.

Android tests combine a monotonic app IME-violation counter, continuous `dumpsys input_method` samples,
custom-key accessibility activation, synthetic hardware key events and command/output assertions. iOS tests
combine native keyboard hierarchy queries and a monotonic local keyboard-notification violation counter.
Observers are diagnostics, never keyboard-dismissal code. Physical keyboard attachment, third-party IMEs
and assistive-service behavior still need testing on the actual supported configurations.
