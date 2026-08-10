"""Decode Granite's 26,136-byte primary trailers as 3 x BC4 132x132 tiles and
render chosen tiles as RGB. 26,136 = 3 x 8,712 and 8,712 B = 33x33 BC4 blocks
= one 132x132 single-channel tile -- the raw-plane and BC7 readings both fail
on this trailer, BC4 is the remaining 132-square codec at that byte count.

Usage:  probe_granite_bc4render.py [slug] [--size 1024] [--tiles 0,1,2]
                                   [--out path]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G         # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_granite_layout as L         # noqa: E402
from probe_tung_colorrender import bounds_of, write_png   # noqa: E402

C = G.C
TILE = 8712          # 33x33 BC4 blocks = 132x132
TSIDE = 132
HP = {0: 149297, 2: 39919}


def bc4_decode(tile):
    """8712 B BC4 -> bytearray 132*132."""
    out = bytearray(TSIDE * TSIDE)
    bi = 0
    for by in range(33):
        for bx in range(33):
            o = bi * 8
            bi += 1
            r0 = tile[o]
            r1 = tile[o + 1]
            bits = int.from_bytes(tile[o + 2:o + 8], "little")
            if r0 > r1:
                pal = [r0, r1] + [((7 - i) * r0 + i * r1) // 7 for i in range(1, 7)]
            else:
                pal = [r0, r1] + [((5 - i) * r0 + i * r1) // 5 for i in range(1, 5)] + [0, 255]
            for py in range(4):
                for px in range(4):
                    idx = (bits >> (3 * (py * 4 + px))) & 7
                    out[(by * 4 + py) * TSIDE + bx * 4 + px] = pal[idx]
    return out


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "base"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    tiles = [int(x) for x in (sys.argv[sys.argv.index("--tiles") + 1].split(",")
                              if "--tiles" in sys.argv else "0,1,2".split(","))]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "granite_%s_bc4_t%s.png"
                          % (slug, "".join(map(str, tiles))))

    td = G.terr_dir(slug)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    ext = collections.defaultdict(int)
    root = None
    for t, off, size_b in blocks:
        if t in (0, 2):
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            if t == 0:
                root = (ns[0][2], ns[0][3])
            for key, dep, mn, mx, kind in ns:
                if kind == "External":
                    ext[key] += HP[t]
    pages = {}
    for t, off, size_b in blocks:
        if t == 1:
            pages = L.splat_pages_by_key(d, off, size_b)

    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])
    print("%s: %d nodes, BC4 tiles %s -> %s"
          % (G.LEVEL_NAMES[slug], len(nodes), tiles, out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        if not n["size0"]:
            continue
        spc = pages.get(n["key"], (0, 0))[1]
        t0 = ext.get(n["key"], 0) + spc * 2592
        r = n["size0"] - t0
        if r < (max(tiles) + 1) * TILE:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        chans = [bc4_decode(buf[t0 + ti * TILE:t0 + (ti + 1) * TILE])
                 for ti in tiles]
        for dz in range(hgt):
            sz = 2 + int(dz / hgt * (TSIDE - 4))
            for dx in range(w):
                sx = 2 + int(dx / w * (TSIDE - 4))
                si = sz * TSIDE + sx
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    for c in range(3):
                        img[di + c] = chans[c % len(chans)][si]
        used += 1
    write_png(out, size, size, img)
    print("wrote %s from %d nodes" % (out, used))


if __name__ == "__main__":
    main()
