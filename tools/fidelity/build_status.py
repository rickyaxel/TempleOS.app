#!/usr/bin/env python3
"""Builds docs/fidelity-audit/data/status.json, the per-program scoring table, from evidence only.

Inputs (docs/fidelity-audit/data/ unless noted):
  specs/<id>.json                  source analysis: inputs, sound, exits, suspected issues
  issue-status.json                status of every suspected issue (fixed / open / ...)
  scenario-results-{kotlin,swift}.json   ScenarioTest(s) runs of shared/fidelity/scenarios.json
  vm-observations.json             what was checked on the original TempleOS (reference VM)
  device-observations.json         what was exercised on simulators, emulators and phones
  vm-frame-comparison.json         the reference VM's screendumps against the app's frames
  shared/program-manifests/catalog.json

Every column is derived from those files; nothing is scored by hand and there are no
percentages. A program is "Verified" only where the original TempleOS (VM) and both apps were
checked; source-derived scenario results are reported as such.

Usage: python3 tools/fidelity/build_status.py [--check]
"""
import json
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
DATA = os.path.join(ROOT, 'docs', 'fidelity-audit', 'data')
OUT = os.path.join(DATA, 'status.json')
INPUT_STEPS = {'key', 'key_down', 'key_up', 'click', 'rclick', 'drag', 'menu', 'popup'}


def load(name, default):
    p = os.path.join(DATA, name)
    return json.load(open(p, encoding='utf-8')) if os.path.exists(p) else default


def tally(scen, res):
    """'n/m' of the scenarios that ran, or None when none ran."""
    ran = [s for s in scen if s['id'] in res]
    if not ran:
        return None
    ok = sum(1 for s in ran if res[s['id']]['status'] == 'PASS')
    return ok, len(ran)


def both(scen, kres, sres):
    """Joint result on both runtimes for a scenario group."""
    if not scen:
        return None
    k, s = tally(scen, kres), tally(scen, sres)
    if not k and not s:
        return 'not run'
    parts = []
    for name, t in (('Kotlin', k), ('Swift', s)):
        parts.append(f'{name} {t[0]}/{t[1]}' if t else f'{name} not run')
    if any(t and t[0] < t[1] for t in (k, s)):
        return 'fails (' + ', '.join(parts) + ')'
    if all(t and t[0] == t[1] for t in (k, s)):
        return 'passes (' + ', '.join(parts) + ')'
    return 'passes where run (' + ', '.join(parts) + ')'


def main():
    cat = json.load(open(os.path.join(ROOT, 'shared', 'program-manifests', 'catalog.json')))['programs']
    scen_all = json.load(open(os.path.join(ROOT, 'shared', 'fidelity', 'scenarios.json')))['scenarios']
    issues = load('issue-status.json', {}).get('issues', {})
    kres = {r['id']: r for r in load('scenario-results-kotlin.json', [])}
    sres = {r['id']: r for r in load('scenario-results-swift.json', [])}
    vm = load('vm-observations.json', {}).get('observations', [])
    dev = load('device-observations.json', {}).get('observations', [])
    cmp_ = load('vm-frame-comparison.json', {}).get('programs', {})
    out = {}
    for p in cat:
        pid = p['id']
        if p['category'] == 'example':
            continue
        sp_path = os.path.join(DATA, 'specs', pid + '.json')
        spec = json.load(open(sp_path, encoding='utf-8')) if os.path.exists(sp_path) else {}
        scen = [s for s in scen_all if s['id'].split('#')[0] == pid]
        inp = [s for s in scen if any(st[0] in INPUT_STEPS for st in s['steps']) and 'global' in s['expect']]
        logic = [s for s in scen if not any(st[0] in INPUT_STEPS for st in s['steps']) and 'global' in s['expect']]
        ex = [s for s in scen if 'exited' in s['expect']]
        vms = [o for o in vm if pid in o.get('programs', [])]
        devs = [o for o in dev if pid in o.get('programs', [])]
        st = issues.get(pid, {})
        sev = {str(i): (iss.get('severity') or '?')[:2] for i, iss in enumerate(spec.get('suspected_issues') or [])}
        open_ = sorted((sev.get(i, '?'), v) for i, v in st.items() if v.startswith('open'))
        unsupported = p.get('status') == 'unsupported'

        def run_col(res):
            t = tally(scen, res)
            if not t:
                return 'not run'
            fails = [s['id'] for s in scen if s['id'] in res and res[s['id']]['status'] != 'PASS']
            return f'{t[0]}/{t[1]} scenarios pass' + (f'; fails: {", ".join(f.split("#")[1] for f in fails)}' if fails else '')

        c = cmp_.get(pid)
        vm_match = bool(c and c['reviewed'] and c['note'].startswith(('layout', 'near pixel', 'pixel-identical', 'grid identical', 'same')))
        ref = ['VM-verified: ' + '; '.join(o['what'] for o in vms)] if vms else []
        if c:
            ref.append(f"captured on the reference VM ({c['shots']} screendumps)")
        row = {
            'source': 'Source-verified (spec: ' + ', '.join(spec.get('original_files') or [p['path']]) + ')' if spec else 'Unverified (no spec)',
            'reference': '; '.join(ref) if ref else 'Source-derived (not run on the reference VM)',
            'kotlin': run_col(kres),
            'swift': run_col(sres),
            'input': both(inp, kres, sres) or 'no input scenario',
            'logic': both(logic, kres, sres) or 'no state scenario',
            'visual': (f"compared with the VM ({c['shots']} shots): {c['note']}" if c and c['reviewed'] else
                       'VM frames captured, not reviewed' if c else 'Unverified (no frame comparison with the VM)'),
            'audio': ('n/a (no sound)' if not spec.get('sound') else
                      'Snd pitch and Play timing follow the source (FA-03, FA-33; pitch VM-measured); not compared by ear'),
            'exit': both(ex, kres, sres) or 'no exit scenario',
            'tests': f'{len(scen)} shared scenarios' if scen else 'none',
        }
        if devs:
            row['devices'] = '; '.join(f"{o['device']}: {o['result']}" for o in devs)
        if unsupported:
            overall = 'Not supported: ' + (p.get('note') or '')
        elif open_ and open_[0][0] in ('P0', 'P1'):
            overall = f'Open {open_[0][0]}: ' + open_[0][1][len('open: '):]
        else:
            k, s = tally(scen, kres), tally(scen, sres)
            allpass = bool(k and s and k[0] == k[1] and s[0] == s[1])
            if allpass and (vms or vm_match):
                overall = 'Verified: source scenarios pass on both apps and the picture matches the reference VM'
            elif allpass:
                overall = 'Source-scenario verified on both apps (not compared with the VM)'
            elif (k and k[0] < k[1]) or (s and s[0] < s[1]):
                overall = 'Partial: some scenarios fail'
            elif k or s:
                overall = 'Partial: scenarios ran on one platform only'
            else:
                overall = 'Unverified (no scenario run)'
            if open_:
                overall += f'; {len(open_)} open P2/P3'
        row['overall'] = overall
        notes = []
        for i, v in sorted(st.items(), key=lambda x: int(x[0])):
            if v.startswith('open') or v.startswith('unverified'):
                notes.append(f'#{i} [{sev.get(i, "?")}] {v}')
        if notes:
            row['notes'] = notes
        row['issues'] = st
        out[pid] = row
    data = {'$comment': 'Generated by tools/fidelity/build_status.py from the evidence files; do not edit by hand.',
            'programs': out}
    text = json.dumps(data, indent=1, ensure_ascii=False) + '\n'
    if '--check' in sys.argv:
        ok = os.path.exists(OUT) and open(OUT, encoding='utf-8').read() == text
        print('up to date' if ok else 'out of date')
        return 0 if ok else 1
    open(OUT, 'w', encoding='utf-8').write(text)
    from collections import Counter
    print(len(out), 'programs;', Counter(r['overall'].split(':')[0].split(';')[0].split(' (')[0] for r in out.values()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
