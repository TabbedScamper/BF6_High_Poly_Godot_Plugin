"""Render MP_Contaminated's colour map from the paired chunks' BC1 tiles.

Established by probe_contaminated_bc1.py: each paired chunk ends with
4 x 8712 bytes = four 132x132 BC1 tiles (33x33 blocks), one per child of the
directory node, and the BC1 signature (c0>c1 on 99.2%% of blocks) sits on the
LAST 34848 bytes.  Child order is tested both ways ([3,2,1,0] per
MAP-TUNGSTEN.md's paired law, and [0,1,2,3]) -- pass --order 0123 to flip.

Blits coarse-first (depth ascending) so finer nodes overwrite.

Usage: probe_contaminated_colorrender.py [level] [--size N] [--order 3210|0123]
       [--out path]
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402
from probe_tung_colorrender import bounds_of, write_png   # noqa: E402

PS = 2592
TILE = 8712
GROUP = 4 * TILE
SIDE = 132
BLOCKS = 33


def bc1_decode(tile):
    """8712-byte BC1 tile -> 132x132x3 bytearray."""
    img = bytearray(SIDE * SIDE * 3)
    for by in range(BLOCKS):
        for bx in range(BLOCKS):
            i = (by * BLOCKS + bx) * 8
            c0 = tile[i] | (tile[i + 1] << 8)
            c1 = tile[i + 2] | (tile[i + 3] << 8)
            idx = tile[i + 4] | (tile[i + 5] << 8) | (tile[i + 6] << 16) | (tile[i + 7] << 24)
            r0, g0, b0 = (c0 >> 11) << 3, ((c0 >> 5) & 0x3F) << 2, (c0 & 0x1F) << 3
            r1, g1, b1 = (c1 >> 11) << 3, ((c1 >> 5) & 0x3F) << 2, (c1 & 0x1F) << 3
            if c0 > c1:
                pal = ((r0, g0, b0), (r1, g1, b1),
                       ((2 * r0 + r1) // 3, (2 * g0 + g1) // 3, (2 * b0 + b1) // 3),
                       ((r0 + 2 * r1) // 3, (g0 + 2 * g1) // 3, (b0 + 2 * b1) // 3))
            else:
                pal = ((r0, g0, b0), (r1, g1, b1),
                       ((r0 + r1) // 2, (g0 + g1) // 2, (b0 + b1) // 2),
                       (0, 0, 0))
            for py in range(4):
                yy = by * 4 + py
                for px in range(4):
                    c = pal[(idx >> ((py * 4 + px) * 2)) & 3]
                    o = (yy * SIDE + bx * 4 + px) * 3
                    img[o:o + 3] = bytes(c)
    return img


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_contaminated"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    order = sys.argv[sys.argv.index("--order") + 1] if "--order" in sys.argv else "3210"
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "%s_bc1color_%s.png" % (level, order))
    child_of_tile = [int(ch) for ch in order]

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _ = CM.chunk_dir(d, after)
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            root = (ns[0][2], ns[0][3])
            break
    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        if n["g1"] is None:
            continue
        p = CM.chunk_path(n["g1"])
        if not os.path.isfile(p):
            continue
        csize = os.path.getsize(p)
        rest = csize - GROUP
        if rest < 0 or not any((rest - pre) >= 0 and (rest - pre) % PS == 0
                               for pre in (0, 189216, 378432)):
            continue
        buf = C.read(p)
        group = buf[-GROUP:]
        for tix in range(4):
            child = child_of_tile[tix]
            ckey = (n["key"] << 4) | child
            b0, b1, b2, b3 = bounds_of(ckey, lo, hi)
            x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
            z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
            w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
            hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
            dec = bc1_decode(group[tix * TILE:(tix + 1) * TILE])
            for dz in range(hgt):
                sz_ = int(dz / hgt * SIDE)
                row = sz_ * SIDE
                for dx in range(w):
                    sx = int(dx / w * SIDE)
                    si = (row + sx) * 3
                    di = ((z0 + dz) * size + (x0 + dx)) * 3
                    if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                        img[di:di + 3] = dec[si:si + 3]
        used += 1
    write_png(out, size, size, img)
    print("wrote %s from %d paired chunks (tile->child order %s)" % (out, used, order))


if __name__ == "__main__":
    main()
