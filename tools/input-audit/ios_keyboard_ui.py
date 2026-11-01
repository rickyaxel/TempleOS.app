#!/usr/bin/env python3
"""Run the actual bench bundle's keyboard UI tests without changing global device settings.

Build-for-testing first with TOS_BUNDLE_ID=io.github.templeosmobile.bench. Only that side-by-side
bundle is launched. Locale dictionaries are supplied to the runner so physical devices need no host paths.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LOCALES = ['en-US', 'es-ES', 'fr-FR', 'de-DE', 'ja-JP', 'zh-CN', 'zh-TW', 'ar']


def locale_strings():
    folder = ROOT / 'shared/runtime/l10n'
    manifest = json.loads((folder / 'locales.json').read_text())
    catalogs = {item['id']: item['catalog'] for item in manifest['locales']}
    english = json.loads((folder / 'en.json').read_text())
    result = {}
    for language in LOCALES:
        translated = json.loads((folder / (catalogs[language]+'.json')).read_text())
        result[language] = {key: str(translated.get(key) or value).replace('{app}', manifest['app_name'])
                            for key, value in english.items() if isinstance(value, str)}
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('udid')
    parser.add_argument('derived_data', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--simulator', action='store_true')
    parser.add_argument('--configuration', choices=['Debug', 'Release'], default='Release')
    parser.add_argument('--suite', choices=['native', 'terry', 'locales'], default='native')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env['TEST_RUNNER_TEMPLEOS_UI_STRINGS'] = json.dumps(locale_strings(), ensure_ascii=False)
    env['TEST_RUNNER_TEMPLEOS_ENGINE'] = 'terry' if args.suite == 'terry' else 'native'
    tests = ['testNativeProgramsOnDevice']
    if args.suite == 'native':
        tests += ['testTempleOSKeyboardTypesIntoTerminal', 'testKeyboardVisibilityFollowsOnlyAttributedActions',
                  'testTextOwnersSaveReopenAndNoNativeKeyboard']
    elif args.suite == 'locales':
        tests = ['testKeyboardLocaleMatrixWithoutSystemKeyboard', 'testSystemChromeFollowsTheScreen']
    command = ['xcodebuild', 'test-without-building', '-project', str(ROOT / 'temple_os_swift/App/TempleOSMobile.xcodeproj'),
               '-scheme', 'TempleOSMobile', '-configuration', args.configuration,
               '-destination', ('platform=iOS Simulator,' if args.simulator else '')+'id='+args.udid,
               '-derivedDataPath', str(args.derived_data.resolve()), '-parallel-testing-enabled', 'NO',
               '-collect-test-diagnostics', 'never', '-resultBundlePath', str((args.output/'tests.xcresult').resolve()),
               'TOS_BUNDLE_ID=io.github.templeosmobile.bench']
    if args.simulator: command += ['CODE_SIGNING_ALLOWED=NO']
    command += ['-only-testing:TempleOSMobileUITests/TempleOSMobileUITests/'+test for test in tests]
    (args.output/'command.json').write_text(json.dumps(command, indent=2)+'\n')
    with (args.output/'xcodebuild.log').open('w') as log:
        status = subprocess.call(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    (args.output/'exit-status.json').write_text(json.dumps({'exit_status': status})+'\n')
    raise SystemExit(status)


if __name__ == '__main__':
    main()
