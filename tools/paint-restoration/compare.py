#!/usr/bin/env python3
"""Exact checkpoint comparison for indexed-frame replay traces; no screenshot tolerance.

Usage: compare.py LEFT_DIR RIGHT_DIR OUT.json
Each trace contains N.idx plus N.json with width/height and meaningful state.
Works for future historical engine traces too; scope is recorded, never inferred.
"""
import collections
import hashlib
import json
import sys
from pathlib import Path


def compare(left, right):
    left_files = sorted(left.glob('[0-9]*.json'), key=lambda p: int(p.stem))
    if not left_files:
        raise ValueError('empty trace')
    if {p.name for p in left_files} != {p.name for p in right.glob('[0-9]*.json')}:
        raise ValueError('checkpoint sets differ')
    results = []
    for file in left_files:
        a_state = json.loads(file.read_text())
        b_state = json.loads((right / file.name).read_text())
        a = file.with_suffix('.idx').read_bytes()
        b = (right / file.with_suffix('.idx').name).read_bytes()
        w, h = a_state['width'], a_state['height']
        if len(a) != w*h or len(b) != w*h:
            raise ValueError(f'invalid frame size at {file.stem}')
        diff = [i for i, (x,y) in enumerate(zip(a,b)) if x != y]
        box = [min(i%w for i in diff), min(i//w for i in diff),
               max(i%w for i in diff), max(i//w for i in diff)] if diff else None
        results.append(dict(checkpoint=int(file.stem), op=a_state['op'], scope=a_state['scope'],
            state_equal=a_state == b_state, mismatched_pixels=len(diff),
            mismatch_percent=100*len(diff)/len(a), bbox_inclusive=box,
            left_colors=dict(collections.Counter(a[i] for i in diff)),
            right_colors=dict(collections.Counter(b[i] for i in diff)),
            sha256=hashlib.sha256(a).hexdigest()))
    saved_equal = (left/'saved.GR').read_bytes() == (right/'saved.GR').read_bytes()
    first = next((r['checkpoint'] for r in results if not r['state_equal'] or r['mismatched_pixels']), None)
    return dict(status='PASS' if first is None and saved_equal else 'FAIL',
        checkpoint_count=len(results), first_divergent_operation=first,
        saved_gr_byte_equal=saved_equal, checkpoints=results)


if __name__ == '__main__':
    result = compare(Path(sys.argv[1]), Path(sys.argv[2]))
    Path(sys.argv[3]).write_text(json.dumps(result, indent=2)+'\n')
    print(result['status'], 'checkpoints=', result['checkpoint_count'],
          'first_divergence=', result['first_divergent_operation'], 'saved_equal=', result['saved_gr_byte_equal'])
    raise SystemExit(0 if result['status'] == 'PASS' else 1)
