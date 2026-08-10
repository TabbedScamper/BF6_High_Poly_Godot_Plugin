"""Exact per-node chunk decomposition for the Granite levels.

Joins, per quadtree key:
    block 0 walk  -> does this node carry an External height payload (149,297 B)
    block 2 walk  -> does it carry an External density payload (39,919 B)
    block 1 walk  -> the node's declared storedPageCount (spec 5.1, +2)
    chunk dir     -> primary chunk size

residual = size0 - heights - density - storedPages * pageSize
tried for pageSize in {2592, 4356, 5184}. The correct page size is the one whose
residuals form a small non-negative set (the colour trailer). Then BC7-tests the
trailer at its computed offset.

Usage:  probe_granite_layout.py [slug ...]     default: all eight
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

C = G.C
HP = {0: 149297, 2: 39919}


def splat_pages_by_key(d, base, size):
    """block-1 walk -> {key: (recordCount, storedPageCount)}"""
    end = base + size
    out = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        spc = struct.unpack_from("<H", d, o + 2)[0]
        out[key] = (rc, spc)
        o += 6
        o += 33 * rc
        if rc == 0:
            return o + 1
        o += 1
        has_children = d[o]
        o += 1
        if o < end:
            o += 1
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return out


def bc7_frac47(buf):
    hi = tot = 0
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        tot += 1
        if b and (b & 0x0F) == 0:
            hi += 1
    return 100.0 * hi / tot if tot else 0.0


def study(slug, sample_bc7=40):
    td = G.terr_dir(slug)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _ = M.chunk_dir(d, after)

    ext = collections.defaultdict(int)          # key -> height prefix bytes
    for t, off, size in blocks:
        if t in (0, 2):
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size, h)
            for key, dep, mn, mx, kind in ns:
                if kind == "External":
                    ext[key] += HP[t]
    pages = {}
    for t, off, size in blocks:
        if t == 1:
            pages = splat_pages_by_key(d, off, size)

    print("=" * 78)
    print("%s  %d dir nodes" % (G.LEVEL_NAMES[slug], len(nodes)))
    for ps in (2592, 4356, 5184):
        resid = collections.Counter()
        neg = 0
        for n in nodes:
            if n["size0"] == 0:
                continue
            spc = pages.get(n["key"], (0, 0))[1]
            r = n["size0"] - ext.get(n["key"], 0) - spc * ps
            if r < 0:
                neg += 1
            else:
                resid[r] += 1
        print("   ps %4d  negative=%3d  residuals=%3d distinct  top: %s"
              % (ps, neg, len(resid),
                 sorted(resid.items(), key=lambda kv: -kv[1])[:8]))

    # decisive ps = fewest distinct residuals with zero negatives
    best = min((2592, 4356, 5184), key=lambda ps: (
        sum(1 for n in nodes if n["size0"] and
            n["size0"] - ext.get(n["key"], 0) -
            pages.get(n["key"], (0, 0))[1] * ps < 0),
        len(set(n["size0"] - ext.get(n["key"], 0) -
                pages.get(n["key"], (0, 0))[1] * ps
                for n in nodes if n["size0"]))))
    print("   -> page size %d" % best)

    # BC7 test the residual trailer at its computed offset
    agg = collections.defaultdict(lambda: [0, 0.0])   # residual -> [n, sum47]
    seen = 0
    for n in nodes:
        if n["size0"] == 0:
            continue
        spc = pages.get(n["key"], (0, 0))[1]
        off0 = ext.get(n["key"], 0) + spc * best
        r = n["size0"] - off0
        if r <= 0:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        f = bc7_frac47(buf[off0:off0 + min(r, 17424)])
        a = agg[r]
        a[0] += 1
        a[1] += f
        seen += 1
        if seen >= sample_bc7 * 8:
            break
    print("   trailer m4-7%% by residual (first <=17424 B of trailer):")
    for r, (n, s) in sorted(agg.items(), key=lambda kv: -kv[1][0])[:10]:
        print("      residual %6d  x%3d  mean m4-7 %5.1f%%" % (r, n, s / n))
    return best


def main():
    slugs = [a for a in sys.argv[1:] if not a.startswith("-")] or \
        (["base"] + G.SLUGS)
    for s in slugs:
        study(s)


if __name__ == "__main__":
    main()
