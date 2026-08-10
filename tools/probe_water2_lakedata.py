"""Does mp_eastwood's block 2 cover the LakeData polygons - i.e. is a LakeData
reader redundant?

MAP-TUNGSTEN.md U4 matched eastwood's block-2 wet plateau LEVELS to the
authored LakeData levels to the centimetre. This probe closes the remaining
gap: FOOTPRINTS. For every LakeData polygon it samples the polygon interior on
a 2-m comb and asks the block-2 mosaic (deepest External last, same compositing
as the plugin) two questions per sample:

    covered   is there a block-2 texel above the dry fill here?
    at level  is that texel within 0.5 m of the lake's authored Y?

and, in reverse, how much block-2 above-fill area lies OUTSIDE every polygon
(water block 2 has that LakeData does not).

READ-ONLY.  Usage:  probe_water2_lakedata.py
"""
import os
import struct
import sys

import numpy as np

sys.setrecursionlimit(200000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402
from probe_water2_block5 import data_size, TAILS   # noqa: E402
from probe_eastwood_water import lakes_in          # noqa: E402

LEVEL = "mp_eastwood"
R = 2048                       # 2 m/px over the 4,096-m world square
HALF = 2048.0
PX = 2 * HALF / R


def block2_mosaic():
    td = T.terr_dir(LEVEL)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    bl = {t: (o, s) for t, o, s in blocks}
    h0 = T.hf_header(d, bl[0][0])
    h2 = T.hf_header(d, bl[2][0])
    xs0, xs2 = h0["xs"], h2["xs"]
    p0, p2 = data_size(h0), data_size(h2)
    wy2 = h2["WorldSizeY"]
    l2 = T.hf_walk(d, bl[2][0], bl[2][1], h2)[0]
    ext2 = sorted((n for n in l2 if n[4] == "External"), key=lambda n: n[1])
    dirnodes, _ = CM.chunk_dir(d, T.container(d)[2])
    bykey = {n["key"]: n for n in dirnodes}
    m2 = np.zeros((R, R), dtype=np.float64) - 1.0
    fill_tally = {}
    b = 4
    n2i = xs2 - 1 - 2 * b
    used = 0
    for key, dep, mn, mx, kind in ext2:
        dn = bykey.get(key)
        if dn is None or dn["g0"] is None:
            continue
        p = CM.chunk_path(dn["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        lo16 = int((mn[1] - 0.5) / wy2 * 65536)
        hi16 = int((mx[1] + 0.5) / wy2 * 65536)

        def inband(off):
            if off < p0 or off + xs2 * xs2 * 2 > len(buf):
                return -1.0
            u = struct.unpack_from("<%dH" % (xs2 * xs2), buf, off)
            pick = [u[(j + 4) * xs2 + (i + 4)]
                    for j in range(0, xs2 - 8, 13)
                    for i in range(0, xs2 - 8, 13)]
            return sum(1 for v in pick if lo16 <= v <= hi16) / float(len(pick))
        cands = [len(buf) - t - p2 for t in TAILS if len(buf) - t - p2 >= p0]
        if not cands:
            continue
        off2 = max(cands, key=inband)
        if inband(off2) < 0.9:
            continue
        g2 = np.array(struct.unpack_from("<%dH" % (xs2 * xs2), buf, off2),
                      dtype=np.int64).reshape(xs2, xs2)
        used += 1
        for v in g2.ravel()[::97]:
            fill_tally[int(v)] = fill_tally.get(int(v), 0) + 1
        px0 = int((mn[0] + HALF) / PX)
        pz0 = int((mn[2] + HALF) / PX)
        px1 = int((mx[0] + HALF) / PX)
        pz1 = int((mx[2] + HALF) / PX)
        jj, ii = np.mgrid[pz0:pz1, px0:px1]
        fx = ((ii + 0.5) * PX - HALF - mn[0]) / (mx[0] - mn[0])
        fz = ((jj + 0.5) * PX - HALF - mn[2]) / (mx[2] - mn[2])
        sj = b + np.clip(np.rint(fz * n2i), 0, n2i).astype(int)
        si = b + np.clip(np.rint(fx * n2i), 0, n2i).astype(int)
        m2[pz0:pz1, px0:px1] = g2[sj, si] / 65536.0 * wy2
    fill = max(fill_tally, key=fill_tally.get) / 65536.0 * wy2
    print("block 2: %d External nodes composited, dry fill %.2f m" %
          (used, fill))
    return m2, fill


def point_in_poly(px, pz, pts):
    """Even-odd crossing test, vectorised over sample arrays."""
    inside = np.zeros(px.shape, dtype=bool)
    n = len(pts)
    for i in range(n):
        x0, z0 = pts[i]
        x1, z1 = pts[(i + 1) % n]
        cond = ((z0 > pz) != (z1 > pz))
        with np.errstate(divide="ignore", invalid="ignore"):
            xint = x0 + (pz - z0) * (x1 - x0) / (z1 - z0)
        inside ^= cond & (px < xint)
    return inside


def main():
    m2, fill = block2_mosaic()
    above = m2 > fill + 0.25

    root = os.path.join(C.LEVELS, LEVEL)
    lakes = []
    for dirpath, _dn, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                blob = open(p, "rb").read()
            except OSError:
                continue
            if bytes.fromhex("f7bd22b78e71b55e") not in blob:
                continue
            for lk in lakes_in(p):
                if lk["pts"]:
                    lakes.append((p, lk))
    print("LakeData polygons found: %d" % len(lakes))

    in_any = np.zeros((R, R), dtype=bool)
    tot_area = tot_cov = tot_lvl = 0
    print("\nper lake: coverage = block2 above fill inside the polygon; "
          "at-level = |block2 - lakeY| < 0.5 m")
    for p, lk in lakes:
        pts = lk["pts"]
        y = lk["ys"][0] if lk["ys"] else float("nan")
        xs = [x for x, _ in pts]
        zs = [z for _, z in pts]
        px0 = max(0, int((min(xs) + HALF) / PX) - 1)
        px1 = min(R, int((max(xs) + HALF) / PX) + 2)
        pz0 = max(0, int((min(zs) + HALF) / PX) - 1)
        pz1 = min(R, int((max(zs) + HALF) / PX) + 2)
        jj, ii = np.mgrid[pz0:pz1, px0:px1]
        wx = (ii + 0.5) * PX - HALF
        wz = (jj + 0.5) * PX - HALF
        inside = point_in_poly(wx, wz, pts)
        n_in = int(inside.sum())
        if n_in == 0:
            print("   [%2d] y %8.2f  polygon smaller than one 2-m sample - "
                  "skipped" % (lk["idx"], y))
            continue
        sub2 = m2[pz0:pz1, px0:px1]
        cov = inside & (sub2 > fill + 0.25)
        lvl = inside & (np.abs(sub2 - y) < 0.5)
        in_any[pz0:pz1, px0:px1] |= inside
        a = n_in * PX * PX
        tot_area += a
        tot_cov += int(cov.sum())
        tot_lvl += int(lvl.sum())
        print("   [%2d] y %8.2f  %6.0f m2  covered %5.1f%%  at level %5.1f%%"
              % (lk["idx"], y, a, 100.0 * cov.sum() / n_in,
                 100.0 * lvl.sum() / n_in))
    n_all = tot_area / (PX * PX)
    print("\nTOTAL: %.0f m2 of polygon, covered %.1f%%, at authored level "
          "%.1f%%" % (tot_area, 100.0 * tot_cov / n_all,
                      100.0 * tot_lvl / n_all))
    extra = above & ~in_any
    print("block-2 above-fill area: %.0f m2;  outside every polygon: %.0f m2 "
          "(%.1f%%) - water block 2 ships that LakeData does not"
          % (above.sum() * PX * PX, extra.sum() * PX * PX,
             100.0 * extra.sum() / max(1, above.sum())))


if __name__ == "__main__":
    main()
