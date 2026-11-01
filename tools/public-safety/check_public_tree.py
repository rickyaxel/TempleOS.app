#!/usr/bin/env python3
"""Keep private material out of this public repository (AGENTS.md).

Fails when tracked files, or the files staged for the next commit, contain signing keys, store
credentials, release artifacts, validation evidence, or text that identifies a machine, a device
or a person: home-directory paths, device UDIDs, signing identity names, personal e-mail
addresses. It reports the file and line only, never the matched text.

  python3 tools/public-safety/check_public_tree.py            every tracked file
  python3 tools/public-safety/check_public_tree.py --staged   the next commit (tools/git-hooks/pre-commit)

Files under shared/bundled-fs/ are checked by name only: they are the original public-domain
TempleOS V5.03 files (byte-identical to the ISO, see shared/bundled-fs.index), which include
their author's own published contact details.
"""
from pathlib import Path
import argparse
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
NAME_ONLY = re.compile(r'^shared/bundled-fs/')

# (pattern for the repository-relative path, reason), case-insensitive
PATHS = [(re.compile(p, re.I), why) for p, why in [
    (r'\.(jks|keystore|p12|pfx|p8|pem|key|cer|crt|der|pepk|mobileprovision|provisionprofile|certsigningrequest)$', 'signing key or certificate'),
    (r'(^|/)(keystore|signing|local)\.properties$', 'local signing or machine configuration'),
    (r'(^|/)\.env(\.(?!example$)[^/]*)?$', 'environment file'),
    (r'service[-_]?account[^/]*\.json$', 'service-account credentials'),
    (r'\.(xcarchive|ipa|aab|apks?|dsym)(/|$)|\.dsym\.zip$', 'release artifact'),
    (r'\.xcresult(/|$)|\.ips$|^docs/(.+/)?evidence/|^docs/localization-evidence/', 'device or validation evidence'),
    (r'(^|/)(xcuserdata|\.idea)/|\.xcuserstate$', 'personal IDE state'),
]]

# (pattern for text content, reason, only in paths matching)
CONTENT = [(re.compile(p), why, re.compile(only) if only else None) for p, why, only in [
    (rb'-----BEGIN (?:[A-Z]+ )*PRIVATE KEY-----', 'private key', None),
    (rb'"type"\s*:\s*"service_account"', 'service-account credentials', None),
    (rb'\b(?:gh[opsur]_[A-Za-z0-9]{30,}|github_pat_\w{30,}|(?:AKIA|ASIA)[0-9A-Z]{16}|AIza[\w-]{35}|xox[abprs]-[\w-]{10,}|sk-(?:ant-)?[\w-]{32,})',
     'access token', None),
    (rb'(?m)^[ \t]*(?:storePassword|keyPassword)[ \t]*[=:][ \t]*\S', 'signing password', r'\.properties(\.\w+)?$'),
    (rb'/(?:Users|home)/(?!Shared/)[A-Za-z0-9][\w.-]*/', 'home-directory path', None),
    (rb'\b0000[0-9A-F]{4}-[0-9A-F]{16}\b', 'device identifier (UDID)', None),
    (rb'Apple (?:Development|Distribution)[^\n:]{0,20}: [^\n()]{1,80}\([A-Z0-9]{10}\)', 'signing identity name', None),
]]
EMAIL = re.compile(rb'(?<![\w.%+-])[\w.%+-]{1,64}@([\w-]{1,63}(?:\.[\w-]{1,63}){0,8}\.([A-Za-z]{2,24}))\b')
EMAIL_OK = re.compile(rb'(?:^|\.)(?:users\.noreply\.github\.com|example\.(?:com|org|net)|invalid)$', re.I)
FILE_SUFFIXES = {b'png', b'jpg', b'jpeg', b'gif', b'svg', b'pdf', b'json', b'kt', b'kts', b'swift', b'md', b'txt',
                 b'html', b'xml', b'plist', b'py', b'sh', b'js', b'css', b'webp'}


def git(*args):
    return subprocess.run(['git', *args], cwd=ROOT, capture_output=True, check=True).stdout


def inspect(path, read):
    problems = [f'{path}: {why}' for pattern, why in PATHS if pattern.search(path)]
    if NAME_ONLY.search(path):
        return problems
    data = read()
    if data is None or b'\0' in data[:8192]:
        return problems
    line = lambda m: data.count(b'\n', 0, m.start()) + 1
    for pattern, why, only in CONTENT:
        if only and not only.search(path):
            continue
        problems += [f'{path}:{line(m)}: {why}' for m in pattern.finditer(data)]
    for m in EMAIL.finditer(data):
        if m.group(2).lower() not in FILE_SUFFIXES and not EMAIL_OK.search(m.group(1)):
            problems.append(f'{path}:{line(m)}: personal e-mail address')
    return problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--staged', action='store_true', help='check the files staged for the next commit')
    args = parser.parse_args()
    if args.staged:
        paths = git('diff', '--cached', '--name-only', '--diff-filter=ACMR', '-z').decode().split('\0')
        read = lambda p: lambda: git('show', f':{p}')
    else:
        paths = git('ls-files', '-z').decode().split('\0')
        read = lambda p: lambda: (ROOT / p).read_bytes() if (ROOT / p).is_file() else None
    problems = [problem for p in paths if p for problem in inspect(p, read(p))]
    if problems:
        print('Private material must not enter this public repository (AGENTS.md):\n  ' + '\n  '.join(problems)
              + '\nKeep it outside the repository (signing material: docs/releasing.md); fix the cause, don\'t bypass this check.')
        return 1
    print(f'public-tree check passed ({"staged files" if args.staged else "all tracked files"})')
    return 0


if __name__ == '__main__':
    sys.exit(main())
