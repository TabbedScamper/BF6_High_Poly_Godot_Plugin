"""Render Granite's per-node trailing planes to a PNG so they can be LOOKED at.

Granite's dominant primary-chunk trailer is 26,136 B = 6 x 4,356 raw 66x66
planes (not BC7 -- the BC7 mode test fails on it). This blits a chosen triple
of those planes as RGB, coarse-first, over the block-0 root AABB, exactly like
probe_tung_colorrender.py does for tungsten's planes.

Usage:  probe_granite_colorrender.py [slug] [--size 1024] [--planes 0,1,2]
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
PLANE = 4356
SIDE = 66
HP = {0: 149297, 2: 39919}


def main():
    slug = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "base"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    planes = [int(x) for x in (sys.argv[sys.argv.index("--planes") + 1].split(",")
                               if "--planes" in sys.argv else "0,1,2".split(","))]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "granite_%s_p%s.png"
                          % (slug, "".join(map(str, planes))))

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
    print("%s: root XZ %s .. %s, %d nodes, planes %s -> %s"
          % (G.LEVEL_NAMES[slug], lo, hi, len(nodes), planes, out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        if not n["size0"]:
            continue
        spc = pages.get(n["key"], (0, 0))[1]
        t0 = ext.get(n["key"], 0) + spc * 2592
        r = n["size0"] - t0
        if r < (max(planes) + 1) * PLANE:
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
        chans = [buf[t0 + pi * PLANE:t0 + (pi + 1) * PLANE] for pi in planes]
        for dz in range(hgt):
            sz = 1 + int(dz / hgt * (SIDE - 2))
            for dx in range(w):
                sx = 1 + int(dx / w * (SIDE - 2))
                si = sz * SIDE + sx
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    for c in range(3):
                        img[di + c] = chans[c][si]
        used += 1
    write_png(out, size, size, img)
    print("wrote %s from %d nodes" % (out, used))


if __name__ == "__main__":
    main()
