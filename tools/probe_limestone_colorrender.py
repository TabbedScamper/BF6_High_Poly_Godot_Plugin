"""Assemble MP_Limestone's terrain colour map into a PNG, decoding the real
BC7 tiles (adapted from probe_tung_colorrender.py, which blitted raw planes).

Per probe_limestone_decomp.py the trailer of every height-bearing primary chunk
is exactly ONE 67,600-byte tile = 260x260 BC7 (256 + 2px apron per edge),
100.00%% of blocks in modes 4-7. Tiles are decoded through Pillow via a minimal
DX10 DDS wrapper (BF6_Frostbite_Research/impl/pipeline/bf6_colormap.py), the
2px apron is cropped, and tiles are blitted coarse-first into the block-0 root
world square.

READ-ONLY against the dump; writes only the output PNG.

Usage: probe_limestone_colorrender.py [level] [--size 2048] [--out path]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import probe_tung_colorrender as R   # noqa: E402
import probe_limestone_decomp as D   # noqa: E402
import bf6_colormap as CM            # noqa: E402

TILE = 67600
SIDE = 260
APRON = 2


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_limestone"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "FIXED_MP_Limestone.png")

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
        r = D.decompose(sz, m)
        if r is None or r[2] != TILE:
            continue
        buf = C.read(p)
        tile = CM.decode_tile(buf[len(buf) - TILE:], SIDE)   # apron cropped
        px = tile.load()
        w = tile.size[0]                                     # 256
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
