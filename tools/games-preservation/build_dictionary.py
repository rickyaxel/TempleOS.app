#!/usr/bin/env python3
"""Package the exact V5.03 dictionary in bounded, independently compressed blocks."""
import hashlib,json,struct,zlib
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
def build():
    src=ROOT/'reference/templeos-iso/Adam/AutoComplete';out=ROOT/'shared/runtime/dictionary';out.mkdir(exist_ok=True)
    words=(src/'ACWords.DATA').read_bytes();defs=(src/'ACDefs.DATA').read_bytes()
    chunks=[zlib.compress(defs[i:i+16384],9) for i in range(0,len(defs),16384)]
    offsets=[0]
    for chunk in chunks:offsets.append(offsets[-1]+len(chunk))
    data=b'TODI'+struct.pack('<III',len(defs),16384,len(chunks))+struct.pack('<'+'I'*len(offsets),*offsets)+b''.join(chunks)
    (out/'words.bin').write_bytes(words);(out/'definitions.bin').write_bytes(data)
    manifest=dict(sourceVersion='TempleOS V5.03',wordSource='Adam/AutoComplete/ACWords.DATA',definitionSource='Adam/AutoComplete/ACDefs.DATA',wordSHA256=hashlib.sha256(words).hexdigest(),definitionSHA256=hashlib.sha256(defs).hexdigest(),wordBytes=len(words),definitionBytes=len(defs),packedDefinitionBytes=len(data),blocks=len(chunks),blockSize=16384,encoding='TODI, LE U32 raw-size/block-size/count, count+1 LE U32 offsets, independently zlib-compressed original blocks')
    (out/'manifest.json').write_text(json.dumps(manifest,indent=1)+'\n')
    # Independently reconstruct every original byte, including block boundaries.
    assert b''.join(zlib.decompress(c) for c in chunks)==defs
    print(json.dumps(manifest))
if __name__=='__main__':build()
