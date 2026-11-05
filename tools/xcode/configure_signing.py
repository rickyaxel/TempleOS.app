#!/usr/bin/env python3
"""Configure this clone's Apple signing team without changing the public Xcode project."""
import argparse
import getpass
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
LOCAL = ROOT / 'temple_os_swift/App/Config/Signing.local.xcconfig'
RELATIVE = LOCAL.relative_to(ROOT).as_posix()
TEAM = re.compile(r'[A-Z0-9]{10}')


def configure(team):
    if not TEAM.fullmatch(team):
        raise ValueError('Use the ten-character Team ID shown in your Apple developer account.')
    ignored = subprocess.run(['git', 'check-ignore', '-q', '--', RELATIVE], cwd=ROOT)
    if ignored.returncode:
        raise ValueError('Local signing configuration must be ignored by Git before setup.')
    if LOCAL.exists():
        raise ValueError(f'{RELATIVE} already exists; edit it locally to change teams.')
    LOCAL.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents replacing an existing local configuration.
    with os.fdopen(os.open(LOCAL, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'w') as f:
        f.write('// Local Apple account setting. Never commit this file.\n')
        f.write(f'DEVELOPMENT_TEAM = {team}\n')
    print(f'Configured {RELATIVE}; Xcode Archive uses this team automatically.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='check local setup without printing the team')
    args = parser.parse_args()
    try:
        if args.check:
            if not LOCAL.is_file() or not re.search(r'(?m)^DEVELOPMENT_TEAM\s*=\s*[A-Z0-9]{10}\s*$', LOCAL.read_text()):
                raise ValueError('Signing team is not configured; run python3 tools/xcode/configure_signing.py.')
            if subprocess.run(['git', 'check-ignore', '-q', '--', RELATIVE], cwd=ROOT).returncode:
                raise ValueError('Local signing configuration must be ignored by Git.')
            print('Local signing team is configured and ignored by Git.')
        else:
            configure(getpass.getpass('Apple Team ID (input hidden): ').strip())
    except (OSError, ValueError, EOFError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
