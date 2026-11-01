#!/usr/bin/env python3
"""Extract the official TempleOS V5.03 distribution (TempleOS.ISO) byte-exactly.

Development-only tool. Independent implementation of the RedSea filesystem
reader and the TempleOS LZW expander, written from the public-domain TempleOS
sources (Kernel/BlkDev/FileSysRedSea.HC, Kernel/Compress.HC, Kernel/KernelA.HH).

Why: the GitHub mirror of the TempleOS source has CRLF-normalized binary
sections, which corrupts the sprites embedded in DolDoc files. The ISO is the
authoritative, byte-exact original.

Usage:
  extract_templeos_iso.py TempleOS.ISO OUT_DIR [--manifest manifest.json]

Expected ISO sha256: 5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26
"""
import hashlib, json, os, struct, sys

ISO_SHA256 = '5d0fc944e5d89c155c0fc17c148646715bc1db6fa5750c0b913772cfec19ba26'
BLK = 512
CDIR_SIZE = 64
RS_ATTR_DIR = 0x10
RS_ATTR_COMPRESSED = 0x0400
ARC_BITS_MAX = 12
CT_NONE, CT_7_BIT, CT_8_BIT = 1, 2, 3


def bfield_ext_u32(buf, bit_pos, bits):
    byte = bit_pos >> 3
    chunk = buf[byte:byte + 5] + b'\0' * 5
    v = int.from_bytes(chunk[:5], 'little') >> (bit_pos & 7)
    return v & ((1 << bits) - 1)


class ArcCtrl:
    """Port of CArcCtrl + ArcEntryGet + ArcExpandBuf (Kernel/Compress.HC)."""

    def __init__(self, ctype):
        n = 1 << ARC_BITS_MAX
        self.next = [-1] * n          # CArcEntry.next (entry index, -1 = NULL)
        self.basecode = [0] * n
        self.ch = [0] * n
        self.hash = [-1] * n          # hash[code] = first entry index (pseudo-node .next)
        self.min_bits = 7 if ctype == CT_7_BIT else 8
        self.min_table_entry = 1 << self.min_bits
        self.free_idx = self.min_table_entry
        self.next_bits_in_use = self.min_bits + 1
        self.free_limit = 1 << self.next_bits_in_use
        self.saved_basecode = 0xFFFFFFFF
        self.cur_entry = -1
        self.next_entry = -1
        self.cur_bits_in_use = 0
        self.entry_used = True
        self.entry_get()
        self.entry_used = True
        self.last_ch = 0
        self.stk = []

    def entry_get(self):
        if not self.entry_used:
            return
        i = self.free_idx
        self.entry_used = False
        self.cur_entry = self.next_entry
        self.cur_bits_in_use = self.next_bits_in_use
        if self.next_bits_in_use < ARC_BITS_MAX:
            self.next_entry = i
            i += 1
            if i == self.free_limit:
                self.next_bits_in_use += 1
                self.free_limit = 1 << self.next_bits_in_use
        else:
            while True:
                i += 1
                if i == self.free_limit:
                    i = self.min_table_entry
                if self.hash[i] == -1:
                    break
            tmp = i
            self.next_entry = tmp
            # unlink tmp from the list headed at hash[basecode[tmp]]
            head = self.basecode[tmp]
            if self.hash[head] == tmp:
                self.hash[head] = self.next[tmp]
            else:
                p = self.hash[head]
                while p != -1:
                    if self.next[p] == tmp:
                        self.next[p] = self.next[tmp]
                        break
                    p = self.next[p]
        self.free_idx = i

    def expand(self, src, src_pos, src_size_bits, dst_size):
        out = bytearray()
        if self.saved_basecode == 0xFFFFFFFF:
            lastcode = bfield_ext_u32(src, src_pos, self.next_bits_in_use)
            src_pos += self.next_bits_in_use
            out.append(lastcode & 0xFF)
            self.entry_get()
            self.last_ch = lastcode
        else:
            lastcode = self.saved_basecode
        while len(out) < dst_size and src_pos + self.next_bits_in_use <= src_size_bits:
            basecode = bfield_ext_u32(src, src_pos, self.next_bits_in_use)
            src_pos += self.next_bits_in_use
            if self.cur_entry == basecode:
                self.stk.append(self.last_ch)
                code = lastcode
            else:
                code = basecode
            while code >= self.min_table_entry:
                self.stk.append(self.ch[code])
                code = self.basecode[code]
            self.stk.append(code)
            self.last_ch = code
            self.entry_used = True
            tmp = self.cur_entry
            self.basecode[tmp] = lastcode
            self.ch[tmp] = self.last_ch
            self.next[tmp] = self.hash[lastcode]
            self.hash[lastcode] = tmp
            self.entry_get()
            while len(out) < dst_size and self.stk:
                out.append(self.stk.pop() & 0xFF)
            lastcode = basecode
        return bytes(out[:dst_size])


def expand_buf(arc):
    compressed_size, expanded_size = struct.unpack('<qq', arc[:16])
    ctype = arc[16]
    if ctype == CT_NONE:
        return arc[17:17 + expanded_size]
    if ctype not in (CT_7_BIT, CT_8_BIT):
        raise ValueError('bad compression type %d' % ctype)
    c = ArcCtrl(ctype)
    return c.expand(arc, 17 * 8, compressed_size * 8, expanded_size)


def find_boot(img):
    for blk in range(len(img) // BLK):
        b = img[blk * BLK:(blk + 1) * BLK]
        if b[3] == 0x88 and b[510:512] == b'\x55\xaa':
            drv_offset, sects, root_clus, bitmap_sects, _uid = struct.unpack('<qqqqq', b[8:48])
            return root_clus
    raise ValueError('RedSea boot block not found')


def read_dir(img, clus, size):
    data = img[clus * BLK:clus * BLK + size]
    entries = []
    for i in range(0, len(data) - CDIR_SIZE + 1, CDIR_SIZE):
        e = data[i:i + CDIR_SIZE]
        attr = struct.unpack('<H', e[0:2])[0]
        name = e[2:40].split(b'\0')[0]
        if not name:
            break
        eclus, esize, dt = struct.unpack('<qqq', e[40:64])
        entries.append((name.decode('latin-1'), attr, eclus, esize, dt))
    return entries


def walk(img, clus, size, path, out_dir, manifest, dirs):
    for idx, (name, attr, eclus, esize, dt) in enumerate(read_dir(img, clus, size)):
        # entry 0 is the directory itself (RedSea stores its name there), entry 1 is ".."
        if idx == 0 or name in ('.', '..'):
            continue
        logical = path + '/' + name
        if attr & RS_ATTR_DIR:
            os.makedirs(os.path.join(out_dir, logical.lstrip('/')), exist_ok=True)
            dirs[logical.lstrip('/')] = {'cdate': dt}
            walk(img, eclus, esize, logical, out_dir, manifest, dirs)
            continue
        raw = img[eclus * BLK:eclus * BLK + esize]
        target = logical
        if name.endswith('.Z'):
            raw = expand_buf(raw)
            target = logical[:-2]
        dst = os.path.join(out_dir, target.lstrip('/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with open(dst, 'wb') as f:
            f.write(raw)
        manifest[target.lstrip('/')] = {
            'size': len(raw), 'sha256': hashlib.sha256(raw).hexdigest(),
            'compressed_on_iso': name.endswith('.Z'),
            # RedSea CDate: day since AD 0 in the high 32 bits, fraction of the day * 2^32 low
            'cdate': dt}


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    iso, out_dir = sys.argv[1], sys.argv[2]
    img = open(iso, 'rb').read()
    digest = hashlib.sha256(img).hexdigest()
    if digest != ISO_SHA256:
        print('warning: ISO sha256 %s does not match the expected TempleOS V5.03 image' % digest)
    root = find_boot(img)
    first = read_dir(img, root, BLK)
    root_size = first[0][3] if first and first[0][0] == '.' else BLK * 8
    manifest, dirs = {}, {}
    walk(img, root, root_size, '', out_dir, manifest, dirs)
    mpath = sys.argv[sys.argv.index('--manifest') + 1] if '--manifest' in sys.argv else os.path.join(out_dir, 'MANIFEST.json')
    with open(mpath, 'w') as f:
        json.dump({'iso_sha256': digest, 'files': manifest, 'dirs': dirs}, f, indent=1, sort_keys=True)
    print('extracted %d files to %s' % (len(manifest), out_dir))


if __name__ == '__main__':
    main()
