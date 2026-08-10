"""Assemble MP_Abbasid's terrain colour map into a PNG, decoding the real BC7
tiles (adapted from probe_limestone_colorrender.py / probe_tung_colorrender.py).

Per probe_abbasid_decomp.py every one of the 57 primary chunks decomposes
EXACTLY as [149,297-byte height payload (52 nodes) or none (root + 4 depth-1
nodes)] + block-1 pageCount x 4,356 + ONE 17,424-byte tile = 132x132 BC7
(128 core + 2 px apron per edge), and the 43 paired chunks as children's pages
+ exactly 4 x 17,424 child colour tiles.  The colour tile is the LAST thing in
the chunk on this map (Tungsten's degenerate second tile does not exist here).

READ-ONLY against the dump; writes only the output PNG.

Usage: probe_abbasid_colorrender.py [level] [--size 2048] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import probe_tung_colorrender as R   # noqa: E402
import probe_limestone_decomp as D   # noqa: E402
import bf6_colormap as CM            # noqa: E402

TILE = 17424
SIDE = 132
PAGE = 4356


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_abbasid"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "FIXED_MP_Abbasid.png")

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    pc = None
    for t, off, sz in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, sz, h)
            root = (ns[0][2], ns[0][3])
        if t == 1:
            pc = D.splat_page_counts(d, off, sz)
    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])
    print("%s: root XZ %s..%s, %d nodes -> %s" % (level, lo, hi, len(nodes), out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    means = []
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        sz = os.path.getsize(p)
        m = pc.get(n["key"], 0)
        # exact decomposition: heights + pages + one tile, else no tile
        has_tile = False
        for pre in (149297, 0):
            if sz - pre - m * PAGE == TILE:
                has_tile = True
                break
        if not has_tile:
            continue
        buf = C.read(p)
        tile = CM.decode_tile(buf[len(buf) - TILE:], SIDE)   # apron cropped
        px = tile.load()
        w = tile.size[0]                                     # 128
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        pw = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        ph = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        acc = [0, 0, 0]
        cnt = 0
        for dz in range(ph):
            sz2 = int(dz / ph * w)
            for dx in range(pw):
                sx = int(dx / pw * w)
                r_, g_, bb, _a = px[sx, sz2]
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    img[di] = r_
                    img[di + 1] = g_
                    img[di + 2] = bb
                acc[0] += r_
                acc[1] += g_
                acc[2] += bb
                cnt += 1
        if cnt:
            means.append((n["depth"], tuple(a / cnt / 255.0 for a in acc)))
        used += 1
    R.write_png(out, size, size, img)
    tot = [0.0, 0.0, 0.0]
    for _d, mn in means:
        for i in range(3):
            tot[i] += mn[i]
    if means:
        print("mean RGB over %d tiles: (%.3f, %.3f, %.3f)"
              % (len(means), tot[0] / len(means), tot[1] / len(means),
                 tot[2] / len(means)))
    print("wrote %s from %d tiles" % (out, used))


if __name__ == "__main__":
    main()
