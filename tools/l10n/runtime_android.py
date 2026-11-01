#!/usr/bin/env python3
"""Localization smoke checks on the explicitly selected Android hardware bench app.

Uses the existing accessibility driver and bench-only app-local language/orientation
controls. Never clears app data, changes device settings, or installs the main app.
Screenshots are evidence, not an automatic linguistic or visual verdict.
"""
import argparse
import hashlib
import json
import re
import shlex
from pathlib import Path
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/program-discovery"))
from android_target import HardwareDevice, BENCH, ui


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("serial")
    parser.add_argument("output", type=Path)
    parser.add_argument("--locales", default="en-US,de-DE,ar,hi-IN,ja-JP")
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--expanded", action="store_true", help="Also exercise language, God Words, About, Files, editor and games")
    parser.add_argument("--switch-only", action="store_true", help="Cycle every locale through the same live Settings window")
    parser.add_argument("--engine", choices=["native", "terry"], default="terry")
    parser.add_argument("--selection-smoke", action="store_true", help="Select Japanese using the actual Language window, relaunch, then select Automatic")
    parser.add_argument("--terminal-error-smoke", action="store_true", help="Trigger a controlled HolyC compile error and verify terminal recovery")
    parser.add_argument("--reopen-file", help="With terminal-error-smoke, reopen the saved InputAudit.HC fixture through Ed")
    parser.add_argument("--overlay-accent-smoke", action="store_true", help="Switch languages with live overlays and save/reopen an accented filename using the CP437 picker")
    parser.add_argument("--language-list-smoke", action="store_true", help="Touch-scroll every language row down and up, preserving wrapped rows")
    args = parser.parse_args()
    manifest = json.loads((ROOT / "shared/runtime/l10n/locales.json").read_text())
    locales = {l["id"]: l for l in manifest["locales"]}
    selected = list(locales) if args.locales == "all" else args.locales.split(",")
    if any(l not in locales for l in selected):
        parser.error("Use canonical locale IDs from locales.json")
    ui.PKG = BENCH
    ui.ACT = BENCH + "/io.github.templeosmobile.android.MainActivity"
    d = HardwareDevice(args.serial)
    if d.shell("getprop ro.kernel.qemu").strip() == "1":
        parser.error("This runner requires physical Android hardware")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    report = {"serial": args.serial, "package": BENCH, "physical": True, "engine": args.engine,
              "model": d.shell("getprop ro.product.model").strip(),
              "api": d.shell("getprop ro.build.version.sdk").strip(), "locales": []}
    if args.apk:
        report["apk_sha256"] = hashlib.sha256(args.apk.read_bytes()).hexdigest()
        d.install(args.apk)
    english = json.loads((ROOT / "shared/runtime/l10n/en.json").read_text())

    def write():
        (out / "results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")

    def no_ime():
        state = d.shell("dumpsys input_method")
        assert "mInputShown=true" not in state and "isInputViewShown=true" not in state, "Native IME visible"

    try:
        # Wake and dismiss an unsecured lock screen through normal device controls.
        # This never changes the device's lock, screen timeout or stay-awake settings.
        d.key("KEYCODE_WAKEUP")
        d.shell("wm dismiss-keyguard", check=False)
        if args.language_list_smoke:
            names = {l["native_name"] + " - " + l["english_name"]: l["id"] for l in locales.values()}
            for loc in selected:
                result = {"locale": loc, "status": "RUNNING", "directions": []}
                report["locales"].append(result); write()
                try:
                    cat = json.loads((ROOT / ("shared/runtime/l10n/" + locales[loc]["catalog"] + ".json")).read_text())
                    d.launch(extras="--ez nosession true --es engine " + args.engine)
                    d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage " + loc)
                    d.tap("MENU")
                    for _ in range(25):
                        if d.find(cat["menu.start.language"], timeout=.1):
                            d.tap(cat["menu.start.language"]); break
                        d.tap(cat["a11y.scroll_menu_down"])
                    labels = {cat["settings.language.automatic"]: "", **names}
                    for direction in (-1, 1):
                        seen, pages = set(), []
                        for page in range(120):
                            visible = sorted((n for n in d.nodes() if n["label"] in labels), key=lambda n: n["bounds"][1])
                            assert visible, "No accessible language rows"
                            ids = [labels[n["label"]] for n in visible]
                            pages.append(ids); seen.update(ids)
                            if page == 0 and direction == -1:
                                d.shot(str(out / (loc + "-language-first.png")))
                            if len(seen) == len(labels): break
                            first, last = visible[0]["bounds"], visible[-1]["bounds"]
                            x = (first[0] + first[2]) // 2
                            top, bottom = (first[1] + first[3]) // 2, (last[1] + last[3]) // 2
                            assert bottom > top, "Language viewport cannot support a page drag"
                            start, end = (bottom, top) if direction == -1 else (top, bottom)
                            d.shell("input swipe %d %d %d %d 350" % (x, start, x, end))
                        missing = sorted(set(labels.values()) - seen)
                        result["directions"].append({"direction": direction, "pages": pages, "seen": len(seen), "missing": missing})
                        assert not missing, "Touch scroll skipped locales: " + str(missing)
                    no_ime(); d.shot(str(out / (loc + "-language-returned-top.png")))
                    result["status"] = "PASS"
                except Exception as error:
                    result.update(status="FAIL", error=str(error))
                    d.shot(str(out / (loc + "-language-failure.png")))
                write(); print(loc, result["status"], result.get("error", ""), flush=True)
            return int(any(r["status"] == "FAIL" for r in report["locales"]))
        if args.overlay_accent_smoke:
            def text_for(locale):
                cat = json.loads((ROOT / ("shared/runtime/l10n/" + locales[locale]["catalog"] + ".json")).read_text())
                def tr(key, **values):
                    values = {"app": manifest["app_name"], **values}
                    return re.sub(r"\{([a-z_]+)\}", lambda m: str(values.get(m[1], m[0])), cat.get(key, english.get(key, key)))
                return tr
            en, ar, ja = (text_for(locale) for locale in ("en-US", "ar", "ja-JP"))
            d.launch(extras="--ez nosession true --es engine terry")
            d.tap("MENU"); d.tap(en("menu.start.editor"))
            d.tap("Control"); d.tap("a")
            d.shell("input text " + shlex.quote('"AccentOK\\n";'))
            d.tap(en("a11y.window_menu", title="Untitled.HC"), exact=False)
            d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage ar")
            assert d.find(ar("editor.menu.save")), "Retained menu did not refresh"
            assert not d.find(en("editor.menu.save"), timeout=0), "Stale app-owned English menu item"
            d.shot(str(out / "live-menu-ar.png"))
            d.key("KEYCODE_BACK")
            d.tap(ar("editor.button.save"))
            d.shell("input keyevent " + " ".join(["67"] * 80))
            prefix = "C:/Home/AccentAudit-" + uuid.uuid4().hex[:8] + "-caf"
            d.shell("input text " + shlex.quote(prefix))
            d.tap("CP437"); d.tap("82  é")
            d.shell("input text '.HC'")
            displayed = prefix + "é.HC"
            d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage ja-JP")
            assert d.find(ja("editor.dialog.save_as")), "Retained dialog title did not refresh"
            assert d.find(ja("button.cancel")), "Retained dialog action did not refresh"
            assert d.find(ja("a11y.text_field", text=displayed)), "Dialog input was lost or CP437 was not decoded"
            no_ime(); d.shot(str(out / "live-save-dialog-ja.png"))
            d.key("KEYCODE_ENTER")
            title = displayed.rsplit("/", 1)[-1]
            assert d.find(ja("a11y.window_menu", title=title)), "Accented saved title is not readable"
            d.shot(str(out / "accented-saved.png"))
            d.tap(ja("a11y.close_window", title=title))
            # Closing the last window restores the product's invariant intro MENU chip.
            d.tap(ja("topbar.menu") if d.find(ja("topbar.menu"), timeout=0) else "MENU")
            d.tap(ja("menu.start.terminal"))
            d.shell("input text " + shlex.quote('Ed("' + prefix))
            d.tap("CP437"); d.tap("82  é")
            d.shell("input text " + shlex.quote('.HC");')); d.key("KEYCODE_ENTER")
            assert d.find(ja("a11y.window_menu", title=title), timeout=25), "Accented byte filename did not reopen"
            d.tap(ja("editor.button.run"))
            assert d.find("AccentOK", exact=False, timeout=25), "Saved accented file did not execute"
            no_ime(); d.shot(str(out / "accented-reopened-output.png"))
            report["overlay_accent_status"] = "PASS"
            report["saved_display_path"] = displayed
            report["checks"] = ["live Arabic menu refresh", "live Japanese dialog refresh", "input/callback preserved", "CP437 picker entered é", "save and Ed reopen preserve byte path", "saved program returned AccentOK", "no native IME"]
            write()
            return 0
        if args.terminal_error_smoke:
            d.launch(extras="--ez nosession true --es engine " + args.engine)
            d.tap("MENU", settle=.2); d.tap(english["menu.start.terminal"], settle=1)
            loc = selected[0]
            cat = json.loads((ROOT / ("shared/runtime/l10n/" + locales[loc]["catalog"] + ".json")).read_text())
            d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage " + loc)
            assert d.find(cat["topbar.menu"]), "Localized terminal UI did not update"
            d.shell("input text " + shlex.quote("LocalizationAuditMissingSymbol;")); d.key("KEYCODE_ENTER")
            assert d.find("undefined identifier", exact=False, timeout=25), "Controlled compile error missing"
            report["secondary_vm_diagnostic"] = bool(d.find("return with no active call", exact=False, timeout=0))
            assert not report["secondary_vm_diagnostic"], "Compile-error recovery scheduled a stale VM return"
            d.shot(str(out / "controlled-error.png"))
            d.shell("input text " + shlex.quote("9+9;")); d.key("KEYCODE_ENTER")
            assert d.find("ans=0x00000012=18", exact=False, timeout=25), "Terminal did not recover"
            no_ime()
            d.shot(str(out / "recovered.png"))
            report["terminal_error_locale"] = loc
            report["terminal_error_status"] = "PASS"
            report["checks"] = ["localized terminal UI", "controlled undefined identifier", "next command returned 18", "no native IME"]
            if args.reopen_file:
                command = "Ed(" + json.dumps(args.reopen_file) + ");"
                d.shell("input text " + shlex.quote(command)); d.key("KEYCODE_ENTER")
                title = args.reopen_file.rsplit("/", 1)[-1]
                menu_label = cat["a11y.window_menu"].replace("{title}", title)
                assert d.find(menu_label, timeout=25), "Saved source did not reopen in the editor"
                d.shot(str(out / "saved-source-reopened.png"))
                d.tap(cat["editor.button.run"], settle=1)
                assert d.find("OK", exact=False, timeout=25), "Reopened program did not produce its saved output"
                no_ime()
                report["checks"].extend(["saved source reopened through Ed", "reopened source ran and returned OK"])
                d.shot(str(out / "reopened-source-output.png"))
            write()
            return 0
        if args.selection_smoke:
            d.launch(extras="--ez nosession true --es engine " + args.engine)
            d.tap("MENU", settle=.2)
            for _ in range(20):
                if d.find(english["menu.start.language"], timeout=.1):
                    d.tap(english["menu.start.language"], settle=.2)
                    break
                d.tap(english["a11y.scroll_menu_down"], settle=.1)
            for character in "japa":
                d.tap(character, settle=.1)
            japanese = locales["ja-JP"]
            d.tap(japanese["native_name"] + " - " + japanese["english_name"], settle=.4)
            ja = json.loads((ROOT / "shared/runtime/l10n/ja.json").read_text())
            assert d.find(ja["topbar.menu"]), "Language-row selection did not change the UI"
            d.shot(str(out / "selected-japanese.png"))
            report["selection_checks"] = ["custom-keyboard filter", "actual Japanese row selection"]
            d.key("KEYCODE_HOME"); time.sleep(.5)
            d.shell("am force-stop " + BENCH)
            d.shell("am start -W -n " + ui.ACT)
            assert d.find(ja["topbar.menu"], timeout=12), "Selected language did not survive process restart"
            report["selection_checks"].append("Japanese persisted after process restart")
            d.tap(ja["topbar.menu"], settle=.2)
            for _ in range(20):
                if d.find(ja["menu.start.language"], timeout=.1):
                    d.tap(ja["menu.start.language"], settle=.2)
                    break
                d.tap(ja["a11y.scroll_menu_down"], settle=.1)
            d.tap(ja["key.escape"], settle=.2)
            d.tap(ja["settings.language.automatic"], settle=.4)
            assert d.find(english["topbar.menu"]), "Automatic did not follow this device's English system UI"
            no_ime()
            d.shot(str(out / "automatic.png"))
            report["selection_checks"].extend(["Automatic selected in the real picker", "no native IME"])
            report["selection_status"] = "PASS"
            write()
            return 0
        if args.switch_only:
            d.launch(extras="--ez nosession true --es engine " + args.engine)
            d.tap("MENU", settle=.2)
            for _ in range(20):
                if d.find(english["menu.start.settings"], timeout=.1):
                    d.tap(english["menu.start.settings"], settle=.2)
                    break
                d.tap(english["a11y.scroll_menu_down"], settle=.1)
            (out / "memory-before.txt").write_text(d.shell("dumpsys meminfo " + BENCH))
        for loc in selected:
            result = {"locale": loc, "checks": [], "status": "RUNNING"}
            report["locales"].append(result)
            write()
            cat = json.loads((ROOT / ("shared/runtime/l10n/" + locales[loc]["catalog"] + ".json")).read_text())

            def tr(key, **values):
                value = cat.get(key, english.get(key, key)).replace("{app}", manifest["app_name"])
                for k, v in values.items():
                    value = value.replace("{" + k + "}", str(v))
                return value

            def choose(label):
                for _ in range(30):
                    nodes = d.nodes()
                    n = next((n for n in nodes if n["label"] == label), None)
                    if n:
                        x0, y0, x1, y1 = n["bounds"]
                        d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
                        time.sleep(.3)
                        return
                    n = next((n for n in nodes if n["label"] == tr("a11y.scroll_menu_down")), None)
                    if not n:
                        break
                    x0, y0, x1, y1 = n["bounds"]
                    d.tap_xy((x0 + x1) // 2, (y0 + y1) // 2)
                raise AssertionError("No accessible menu item: " + label)

            def open_app(key):
                d.tap(tr("topbar.menu"), settle=.2)
                choose(tr(key))

            def snapshot(name):
                d.shot(str(out / (loc + "-" + name + ".png")))
                (out / (loc + "-" + name + ".json")).write_text(json.dumps(d.nodes(), indent=1, ensure_ascii=False) + "\n")

            try:
                d.key("KEYCODE_WAKEUP")
                d.shell("wm dismiss-keyguard", check=False)
                if args.switch_only:
                    started = time.monotonic()
                    d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage " + loc)
                    assert d.find(tr("app.settings.title"), exact=False, timeout=12), "Localized Settings missing"
                    assert d.find(tr("topbar.menu"), timeout=12), "Localized menu chip missing"
                    result["checks"].extend(["live locale loading", "retained Settings window", "localized menu and Settings accessibility"])
                    result["switch_and_accessibility_probe_seconds"] = round(time.monotonic() - started, 3)
                    snapshot("settings")
                    no_ime()
                    result["status"] = "PASS (smoke assertions; visual review separate)"
                    write()
                    print(loc, result["status"], flush=True)
                    continue
                # HardwareDevice's launch starts in English; the following onNewIntent switches
                # the live shell, preserving windows. No OS locale setting is changed.
                d.launch(extras="--ez nosession true --es engine " + args.engine)
                d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage " + loc)
                # The four-line branded intro deliberately keeps its MENU chip in English.
                assert d.find("MENU", timeout=12), "Intro main menu missing"
                result["checks"].append("intro navigation")
                d.tap("MENU", settle=.2)
                snapshot("menu")
                choose(tr("menu.start.settings"))
                assert d.find(tr("app.settings.title"), exact=False), "Settings missing"
                assert d.find(tr("topbar.menu"), timeout=12), "Localized main menu missing after intro"
                result["checks"].append("live language resolution")
                snapshot("settings-portrait")
                result["checks"].append("settings navigation")
                d.rotate(True)
                snapshot("settings-landscape")
                if args.expanded:
                    for _ in range(4):
                        if d.find(tr("settings.close_all"), timeout=.1):
                            break
                        ns = d.nodes()
                        first = next(n for n in ns if n["label"] == tr("settings.language", value=locales[loc]["native_name"]))
                        x0, y0, x1, y1 = first["bounds"]
                        last = max(n["bounds"][3] for n in ns if n["bounds"][1] >= y0)
                        x = (x0 + x1) // 2
                        d.shell("input swipe %d %d %d %d 350" % (x, last - 10, x, y0 + 10))
                    assert d.find(tr("settings.close_all"), timeout=3), "Last Settings action not reachable"
                    snapshot("settings-landscape-scrolled")
                    result["checks"].append("last Settings action reachable by touch scrolling")
                d.rotate(False)
                result["checks"].append("app-local rotation")
                if args.expanded:
                    open_app("menu.start.language")
                    snapshot("language")
                    no_ime()
                    result["checks"].append("language selector and custom keyboard")
                    open_app("menu.start.god_words")
                    d.tap(tr("god.button.ten_words"), settle=.4)
                    snapshot("ten-words")
                    result["checks"].append("10 Words generation")
                    open_app("menu.start.about")
                    snapshot("about")
                    open_app("menu.start.files")
                    snapshot("files")
                    open_app("menu.start.editor")
                    snapshot("editor")
                    no_ime()
                    open_app("menu.start.games")
                    snapshot("games")
                    result["checks"].append("About, Files, editor and game launcher")
                    choose(tr("games.catalog")); choose("WaterFowl")
                    time.sleep(2)
                    title = "WaterFowl" + (" · Pure Kotlin" if args.engine == "native" else "")
                    assert d.find(tr("a11y.window_menu", title=title), timeout=12), "Program did not launch with expected engine"
                    snapshot("waterfowl")
                    d.rotate(True)
                    d.tap(tr("a11y.window_menu", title=title), settle=.2)
                    choose(tr("program.menu.about"))
                    assert d.find(tr("button.ok")) and d.find(tr("button.cancel")), "Dialog actions missing"
                    snapshot("program-dialog-landscape")
                    d.tap(tr("button.cancel"), settle=.3)
                    d.tap(tr("a11y.close_window", title=title), settle=.5)
                    result["checks"].append("WaterFowl launch, program dialog, cancel and close (" + args.engine + ")")
                    d.rotate(False)
                    # Suspend/resume the same activity; the locale must remain selected.
                    d.key("KEYCODE_HOME")
                    d.shell("am start -W -f 0x20000000 -n " + ui.ACT)
                    assert d.find(tr("topbar.menu"), timeout=10)
                    result["checks"].append("background restoration")
                no_ime()
                result["status"] = "PASS (smoke assertions; visual review separate)"
            except Exception as error:
                result["status"] = "FAIL"
                result["error"] = str(error)
                snapshot("failure")
            write()
            print(loc, result["status"], result.get("error", ""), flush=True)
        if args.switch_only:
            (out / "memory-after.txt").write_text(d.shell("dumpsys meminfo " + BENCH))
            d.key("KEYCODE_HOME")
            time.sleep(.5)
            d.shell("am force-stop " + BENCH)
            d.shell("am start -W -n " + ui.ACT)
            expected = json.loads((ROOT / ("shared/runtime/l10n/" + locales[selected[-1]]["catalog"] + ".json")).read_text())["app.settings.title"]
            report["persistence_after_relaunch"] = bool(d.find(expected, exact=False, timeout=12))
            write()
    finally:
        d.shell("am start -W -f 0x20000000 -n " + ui.ACT + " --es inputLanguage en-US --es inputOrientation user", check=False)
        write()
    return int(any(r["status"] == "FAIL" for r in report["locales"]) or report.get("persistence_after_relaunch") is False)


if __name__ == "__main__":
    sys.exit(main())
