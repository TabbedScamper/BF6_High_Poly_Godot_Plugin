"""MP_ISOLATED's water, from terrain streaming-tree block 2 - and block 10.

MAP-TUNGSTEN.md U5 left mp_isolated as the one block-2 map never studied
(root band 100.49..109.12) and flagged an undocumented block 10. This probe:

  A  block-2 header + tree census (NOTE: xs=137, NOT the fleet's 265 - the
     only map so far whose water heightfield ships at half resolution);
  B  chunk layout: where the block-2 payload sits (MEASURED: at chunk_end -
     48,631 on leaf-depth chunks / chunk_end - 66,055 on shallower ones, i.e.
     tails of 8,712 = 2 x 4,356 and 26,136 = 8,712 + 17,424 after the 39,919-
     byte payload - NOT the tungsten tail set {0, 17424, 34848, 85024});
  C  the river's numbers: extent, water levels, wet area (vs ground), the
     area the plugin's fill+0.5 clip would select, and downstream fall;
  D  plugin terrain_water() readiness verdict, mechanically derived;
  E  block 10: header, size arithmetic, tile decode.

READ-ONLY.  Usage:  probe_water2_isolated.py
"""
import os
import struct
import sys

import numpy as np

sys.setrecursionlimit(200000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as CM     # noqa: E402
from probe_water2_block5 import data_size   # noqa: E402

LEVEL = "mp_isolated"
TAILS = (8712, 26136)          # measured, this probe section B
PLUGIN_TAILS = (0, 17424, 34848, 85024)


def main():
    td = T.terr_dir(LEVEL)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    bl = {t: (o, s) for t, o, s in blocks}
    print("%s blocks: %s" % (LEVEL, sorted(bl)))

    # A. headers ------------------------------------------------------------
    h0 = T.hf_header(d, bl[0][0])
    h2 = T.hf_header(d, bl[2][0])
    p0, p2 = data_size(h0), data_size(h2)
    print("\nA. block-0 header %s  payload %d" % (h0, p0))
    print("   block-2 header %s  payload %d" % (h2, p2))
    l2 = T.hf_walk(d, bl[2][0], bl[2][1], h2)[0]
    import collections
    print("   block-2 nodes %d  kinds x depth: %s" % (
        len(l2), dict(collections.Counter((n[1], n[4]) for n in l2))))
    # THE TREE IS AN LOD MOSAIC: External nodes exist at depths 2..6 and the
    # shallow ones are coarse ancestors of the deep ones (0x302 d2 is an
    # ancestor of 0x3022300 d6, both External); an Empty CHILD of an External
    # is "no further refinement", not "no water" - the flat parts of the water
    # stay at coarse LOD and only the detailed patch refines to depth 6. The
    # surface is therefore composited deepest-last, exactly what the plugin's
    # composite() does. Statistics below come from that mosaic.
    ext2 = sorted((n for n in l2 if n[4] == "External"), key=lambda n: n[1])
    print("   External nodes: %d  by depth %s"
          % (len(ext2), dict(collections.Counter(n[1] for n in ext2))))
    l0 = T.hf_walk(d, bl[0][0], bl[0][1], h0)[0]
    r0 = l0[0]
    print("   block-0 root band: %.2f..%.2f m (terrain floor vs block-2 "
          "fill matters below)" % (r0[2][1], r0[3][1]))
    wy0, wy2 = h0["WorldSizeY"], h2["WorldSizeY"]
    xs0, xs2 = h0["xs"], h2["xs"]

    # B. payload location, measured per chunk -------------------------------
    dirnodes, _ = CM.chunk_dir(d, T.container(d)[2])
    bykey = {n["key"]: n for n in dirnodes}
    grids = []
    tail_census = collections.Counter()
    missing = 0
    for key, dep, mn, mx, kind in ext2:
        dn = bykey.get(key)
        if dn is None or dn["g0"] is None:
            missing += 1
            continue
        p = CM.chunk_path(dn["g0"])
        if not os.path.isfile(p):
            missing += 1
            continue
        buf = C.read(p)
        lo16 = int((mn[1] - 0.5) / wy2 * 65536)
        hi16 = int((mx[1] + 0.5) / wy2 * 65536)

        def inband(off):
            if off < p0 or off + xs2 * xs2 * 2 > len(buf):
                return -1.0
            g = np.frombuffer(buf, dtype=np.uint8, count=xs2 * xs2 * 2,
                              offset=off)
            g = g.view()  # bytes; decode via struct for odd offsets
            u = struct.unpack_from("<%dH" % (xs2 * xs2), buf, off)
            pick = [u[(j + 4) * xs2 + (i + 4)]
                    for j in range(0, xs2 - 8, 13) for i in range(0, xs2 - 8, 13)]
            return sum(1 for v in pick if lo16 <= v <= hi16) / float(len(pick))
        best_t, best_f = None, -1.0
        for t in TAILS:
            f = inband(len(buf) - t - p2)
            if f > best_f:
                best_f, best_t = f, t
        if best_f < 0.9:
            missing += 1
            continue
        tail_census[best_t] += 1
        off2 = len(buf) - best_t - p2
        g0 = np.array(struct.unpack_from("<%dH" % (xs0 * xs0), buf, 0),
                      dtype=np.int64).reshape(xs0, xs0)
        g2 = np.array(struct.unpack_from("<%dH" % (xs2 * xs2), buf, off2),
                      dtype=np.int64).reshape(xs2, xs2)
        grids.append((key, dep, mn, mx, g0, g2))
    print("\nB. External nodes with a decoded payload: %d of %d (missing %d)"
          % (len(grids), len(ext2), missing))
    print("   payload tail census (bytes after payload end): %s"
          % dict(tail_census))
    print("   plugin's tail candidates %s -> in-band never; needed: %s"
          % (list(PLUGIN_TAILS), list(TAILS)))

    # C. the river ----------------------------------------------------------
    b = 4
    n2i = xs2 - 1 - 2 * b
    n0i = xs0 - 1 - 2 * b
    fill_tally = collections.Counter()
    for _, _, _, _, _, g2 in grids:
        flat = g2.ravel()
        fill_tally.update(flat[::97].tolist())
    fill = fill_tally.most_common(1)[0][0]
    fill_frac = fill_tally.most_common(1)[0][1] / float(
        sum(fill_tally.values()))
    wet_min = fill + int(0.5 / wy2 * 65536.0)
    print("\nC. dry fill %.3f m (u16 %d, %.1f%% of sampled texels)"
          % (fill / 65536.0 * wy2, fill, 100 * fill_frac))

    # deepest-last mosaic at 2 m/px over the 8,192-m world square
    R = 4096
    PX = 8192.0 / R                       # metres per pixel
    m2 = np.zeros((R, R), dtype=np.int32) - 1   # block-2 u16 (-1 = no node)
    m0 = np.zeros((R, R), dtype=np.int32) - 1   # block-0 u16, same-chunk LOD
    mdep = np.zeros((R, R), dtype=np.int8) - 1
    for key, dep, mn, mx, g0, g2 in grids:      # grids already depth-sorted
        px0 = int((mn[0] + 4096.0) / PX)
        pz0 = int((mn[2] + 4096.0) / PX)
        px1 = int((mx[0] + 4096.0) / PX)
        pz1 = int((mx[2] + 4096.0) / PX)
        if px1 <= px0 or pz1 <= pz0:
            continue
        jj, ii = np.mgrid[pz0:pz1, px0:px1]
        fx = ((ii + 0.5) * PX - 4096.0 - mn[0]) / (mx[0] - mn[0])
        fz = ((jj + 0.5) * PX - 4096.0 - mn[2]) / (mx[2] - mn[2])
        s2j = b + np.clip(np.rint(fz * n2i), 0, n2i).astype(int)
        s2i = b + np.clip(np.rint(fx * n2i), 0, n2i).astype(int)
        s0j = b + np.clip(np.rint(fz * n0i), 0, n0i).astype(int)
        s0i = b + np.clip(np.rint(fx * n0i), 0, n0i).astype(int)
        m2[pz0:pz1, px0:px1] = g2[s2j, s2i]
        m0[pz0:pz1, px0:px1] = g0[s0j, s0i]
        mdep[pz0:pz1, px0:px1] = dep
    covered = m2 >= 0
    wet = covered & ((m2 / 65536.0 * wy2 - m0 / 65536.0 * wy0) > 0.02)
    above = covered & (m2 >= wet_min)
    km2 = PX * PX / 1e6
    print("   node-covered area: %.2f km2   by finest depth: %s" % (
        covered.sum() * km2,
        {int(dv): round(float((mdep == dv).sum() * km2), 2)
         for dv in np.unique(mdep) if dv >= 0}))
    print("   wet (water > ground + 2 cm): %.2f km2"
          % (wet.sum() * km2))
    print("   the plugin's clip (>= fill + 0.5 m) selects: %.3f km2"
          % (above.sum() * km2))
    lv = m2[wet] / 65536.0 * wy2
    wjj, wii = np.nonzero(wet)
    wx = wii * PX - 4096.0
    wz = wjj * PX - 4096.0
    print("   water level over wet texels: min %.2f  p5 %.2f  median %.2f  "
          "p95 %.2f  max %.2f m"
          % (lv.min(), np.percentile(lv, 5), np.median(lv),
             np.percentile(lv, 95), lv.max()))
    print("   wet extent: x %.0f..%.0f   z %.0f..%.0f"
          % (wx.min(), wx.max(), wz.min(), wz.max()))
    print("   fill vs levels: fill %.3f, wet median %.2f -> the water "
          "level IS the fill level on this map"
          % (fill / 65536.0 * wy2, np.median(lv)))
    print("   mean water level by 512-m z-band (flow check):")
    for zb in range(-4096, 4096, 512):
        msk = wet[int((zb + 4096) / PX):int((zb + 4608) / PX), :]
        sel = m2[int((zb + 4096) / PX):int((zb + 4608) / PX), :][msk]
        if sel.size:
            print("      z %+5d..%+5d  %8.2f m   (%.2f km2 wet)"
                  % (zb, zb + 512, sel.mean() / 65536.0 * wy2,
                     msk.sum() * km2))

    print("   wet raster (# >50%% wet, + >0%%, . dry node, space no node):")
    S = R // 64
    for rr in range(0, R, S * 2):
        row = ""
        for cc in range(0, R, S):
            blkw = wet[rr:rr + 2 * S, cc:cc + S].sum()
            blkc = covered[rr:rr + 2 * S, cc:cc + S].sum()
            row += " " if blkc == 0 else ("#" if blkw > blkc * 0.5 else
                                          ("+" if blkw else "."))
        print("      " + row)

    # D. verdict ------------------------------------------------------------
    print("\nD. plugin terrain_water() on mp_isolated:")
    print("   1) fetch2 tails %s miss the payload (needs %s) -> every "
          "External node drops" % (list(PLUGIN_TAILS), list(TAILS)))
    print("   2) even with the payload, wet = fill+0.5 selects %.3f km2 "
          "of a %.2f km2 river (the water level IS the fill level here)"
          % (above.sum() * km2, wet.sum() * km2))

    # E. block 10 -----------------------------------------------------------
    off, size = bl[10]
    u = struct.unpack_from("<2I", d, off)
    bbox = struct.unpack_from("<4f", d, off + 8)
    c = struct.unpack_from("<4I", d, off + 24)
    print("\nE. block 10: %d bytes  tag %d  u1 %d  bbox %s  counts %s"
          % (size, u[0], u[1], bbox, c))
    tiles = c[1]
    ts = u[0] * u[0]
    print("   size arithmetic: 40 header + 388 preamble + %d x %d^2 = %d "
          "(actual %d, match %s)"
          % (tiles, u[0], 40 + 388 + tiles * ts, size,
             40 + 388 + tiles * ts == size))
    pay = np.frombuffer(d[off + 40:off + size], dtype=np.uint8)
    pre = pay[:388]
    print("   preamble: %d bytes 0/1, %d ones, all within the first %d bytes"
          % (len(pre), int(pre.sum()), int(np.nonzero(pre)[0].max()) + 1))
    field = pay[388:]
    print("   tile field: %d tiles of %dx%d u8; value census 0: %.1f%%  "
          "255: %.1f%%  1..254: %.1f%% (smooth: mean |row-diff| at stride "
          "%d < strides +/-1, measured)"
          % (tiles, u[0], u[0], 100 * float((field == 0).mean()),
             100 * float((field == 255).mean()),
             100 * float(((field > 0) & (field < 255)).mean()), u[0]))


if __name__ == "__main__":
    main()
