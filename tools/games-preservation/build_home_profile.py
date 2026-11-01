#!/usr/bin/env python3
"""Recover omitted per-user directories from original application installers.

Only directory-only installers absent from Run.HC are eligible. Programs which
include their own installer retain responsibility for it (Budget copies data).
"""
import hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def build():
    source=ROOT/'reference/templeos-iso';rows=[];proof=[]
    for installer in sorted((source/'Apps').glob('*/Install.HC')):
        run=installer.parent/'Run.HC'
        if not run.exists() or re.search(r'#include\s+"Install',run.read_text('latin1')):continue
        text=installer.read_text('latin1')
        dirs=re.findall(r'DirMk\("(~/[^"\n]+)"\)',text)
        if not dirs or re.search(r'\b(?:Copy|FileWrite|RegWrite)\s*\(',text):continue
        root='C:/'+str(installer.parent.relative_to(source))+'/'
        for directory in dirs:rows.append(root+'\tC:/Home/'+directory[2:])
        proof.append(dict(source=str(installer.relative_to(source)),sha256=hashlib.sha256(installer.read_bytes()).hexdigest(),directories=dirs,reason='directory-only installer not included by Run.HC'))
    (ROOT/'shared/runtime/home-profile.tsv').write_text('\n'.join(rows)+'\n')
    (ROOT/'docs/games-preservation/home-profile.json').write_text(json.dumps(proof,indent=1)+'\n')
    print('\n'.join(rows))
if __name__=='__main__':build()
