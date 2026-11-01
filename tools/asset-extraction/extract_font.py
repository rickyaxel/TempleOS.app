#!/usr/bin/env python3
"""Extract the TempleOS 8x8 system font from Kernel/FontStd.HC (public domain).

Output: 2048-byte binary, 8 bytes per glyph (256 glyphs). Byte r of glyph c is
row r (top first); bit b of that byte is column b (LSB = leftmost pixel). This is
exactly the in-memory layout of TempleOS's U64 sys_font_std[256].

Usage: extract_font.py <path/to/Kernel/FontStd.HC> <out.bin>
"""
import re, struct, sys

def main(src, out):
    text = open(src, 'rb').read().decode('latin-1')
    body = text[text.index('sys_font_std[256]'):]
    body = body[body.index('{') + 1: body.index('};')]
    body = re.sub(r'//[^\n]*', '', body)
    vals = [int(v, 16) for v in re.findall(r'0x([0-9A-Fa-f]{16})', body)]
    if len(vals) != 256:
        sys.exit(f'expected 256 glyphs, got {len(vals)}')
    with open(out, 'wb') as f:
        for v in vals:
            f.write(struct.pack('<Q', v))
    print(f'wrote {out}: 256 glyphs')

if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
