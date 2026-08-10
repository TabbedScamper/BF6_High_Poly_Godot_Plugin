"""Simulate bf6_splat.gd::detect_layout (the FIXED algorithm) on real chunks.

Mirrors the rewritten GDScript exactly: page size = the candidate in
PAGE_SIZES with the FEWEST distinct residuals (sz - pages*ps) over nodes with
pages > 0, none negative; tile size = the first candidate in TILE_SIZES whose
prefix-decomposition (PREFIXES, fewest-tiles preference, k <= 8) covers every
residual. Run per map; MP_Dumbo is the baseline map that must not regress —
it must come out (2592, 4624).

Usage:  probe_dumbo_detectsim.py [level ...]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PAGE_SIZES = [2592, 4356, 5184]
TILE_SIZES = {4624: 68, 17424: 132, 67600: 260}
PREFIXES = [0, 39919, 149297, 189216, 298594]


def splat_pages(d, base, size):
    end = base + size
    per = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        painted = 0
        for _ in range(rc):
            if not struct.unpack_from("<H", d, o + 20)[0] & 0x0100:
                painted += 1
            o += 33
        per[key] = painted
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
    return per


def tiles_in(residual, tb):
    best = -1
    for p in PREFIXES:
        rem = residual - p
        if rem < 0 or rem % tb:
            continue
        k = rem // tb
        if k > 8:
            continue
        if best < 0 or k < best:
            best = k
    return best


def simulate(level):
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    pages = {}
    for t, off, sz in blocks:
        if t == 1:
            pages = splat_pages(d, off, sz)
    rows = []
    for n in nodes:
        p = pages.get(n["key"], 0)
        if p <= 0 or n["size0"] <= 0:
            continue
        rows.append((p, n["size0"]))
    best_ps, best_resid = 0, None
    for ps in PAGE_SIZES:
        resid = set()
        ok = True
        for p, sz in rows:
            r = sz - p * ps
            if r < 0:
                ok = False
                break
            resid.add(r)
        if not ok or not resid:
            print("   ps %5d  REJECTED (negative residual or empty)" % ps)
            continue
        print("   ps %5d  %d distinct residuals" % (ps, len(resid)))
        if best_ps == 0 or len(resid) < len(best_resid):
            best_ps, best_resid = ps, resid
    tile = 0
    for tb in TILE_SIZES:
        if all(tiles_in(r, tb) >= 0 for r in best_resid):
            tile = tb
            break
    print("%s: picks page %d, tile %d   residuals %s"
          % (level, best_ps, tile, sorted(best_resid)))


if __name__ == "__main__":
    for lvl in (sys.argv[1:] or ["mp_dumbo"]):
        simulate(lvl)
