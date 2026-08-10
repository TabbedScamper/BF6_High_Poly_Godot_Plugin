"""Assemble MP_Outskirts' terrain colour map into a PNG so it can be LOOKED at.

MP_Outskirts trails exactly ONE 17,424-byte tile per primary chunk
(probe_outskirts_decomp.py: residual 166,721 = 149,297 height prefix +
1 x 17,424 on all 80 tile-bearing chunks; the 5 pages-only chunks have none),
so the colour tile is the last 17,424 bytes — there is no tungsten-style
degenerate second raster. Decoded as 132x132 BC7 via bf6_colormap.decode_tile
(DDS wrap -> Pillow), apron cropped, blitted coarse-first; then each paired
chunk's four child tiles (reversed child order [3,2,1,0]) refine the leaves.

Usage:  probe_outskirts_colorrender.py [level] [--size 4096] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as M        # noqa: E402
import probe_tung_colorrender as R     # noqa: E402
import probe_outskirts_decomp as DC    # noqa: E402
import bf6_colormap as CM              # noqa: E402

import numpy as np                     # noqa: E402

TILE = 17424
SIDE = 132
CHILD_X = [0, 1, 1, 0]
CHILD_Z = [0, 0, 1, 1]


def blit(canvas, asum, acnt, arr, x0, z0, x1, z1, lo, hi, size):
    px0 = int((x0 - lo[0]) / (hi[0] - lo[0]) * size)
    pz0 = int((z0 - lo[1]) / (hi[1] - lo[1]) * size)
    px1 = max(px0 + 1, int((x1 - lo[0]) / (hi[0] - lo[0]) * size))
    pz1 = max(pz0 + 1, int((z1 - lo[1]) / (hi[1] - lo[1]) * size))
    px1, pz1 = min(px1, size), min(pz1, size)
    if px1 <= px0 or pz1 <= pz0:
        return
    h, w = arr.shape[0], arr.shape[1]
    zi = (np.arange(pz0, pz1) - pz0) * h // (pz1 - pz0)
    xi = (np.arange(px0, px1) - px0) * w // (px1 - px0)
    canvas[pz0:pz1, px0:px1] = arr[np.ix_(zi, xi)][:, :, :3]
    asum[0] += int(arr[:, :, 3].astype(np.uint64).sum())
    acnt[0] += arr.shape[0] * arr.shape[1]


def child_bounds(x0, z0, x1, z1, ci):
    hx, hz = (x0 + x1) / 2.0, (z0 + z1) / 2.0
    return (hx if CHILD_X[ci] else x0, hz if CHILD_Z[ci] else z0,
            x1 if CHILD_X[ci] else hx, z1 if CHILD_Z[ci] else hz)


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_outskirts"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 4096
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else os.path.join(
        os.environ["APPDATA"], "Godot", "app_userdata",
        "Battlefield™ Portal Project", "_cmapprobe", "FIXED_MP_Outskirts.png")

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            root = (ns[0][2], ns[0][3])
            break
    lo, hi = (root[0][0], root[0][2]), (root[1][0], root[1][2])
    b1 = next(b for b in blocks if b[0] == 1)
    pages = DC.splat_pages_per_node(d, b1[1], b1[2])

    canvas = np.zeros((size, size, 3), np.uint8)
    asum, acnt = [0], [0]
    nodes.sort(key=lambda n: n["depth"])
    used = pused = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p) or os.path.getsize(p) < TILE:
            continue
        buf = C.read(p)
        # skip chunks with no tile trailer (pages-only: size0 == m x 4356)
        m = pages.get(n["key"], 0)
        r = len(buf) - m * 4356
        if not any(r - pref >= TILE and (r - pref) % TILE == 0
                   for pref in DC.PREFIXES):
            continue
        tile = buf[-TILE:]
        if all(b == 0 for b in tile):
            continue
        arr = np.asarray(CM.decode_tile(tile, SIDE))
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        blit(canvas, asum, acnt, arr, b0, b1, b2, b3, lo, hi, size)
        used += 1
    for n in nodes:
        if n["g1"] is None:
            continue
        p = M.chunk_path(n["g1"])
        if not os.path.isfile(p) or os.path.getsize(p) < 4 * TILE:
            continue
        buf = C.read(p)
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        for k, ci in enumerate(CM.PAIRED_TILE_ORDER):
            seg = buf[len(buf) - (4 - k) * TILE: len(buf) - (3 - k) * TILE]
            if all(b == 0 for b in seg[:1024]):
                continue
            arr = np.asarray(CM.decode_tile(seg, SIDE))
            cb = child_bounds(b0, b1, b2, b3, ci)
            blit(canvas, asum, acnt, arr, cb[0], cb[1], cb[2], cb[3], lo, hi, size)
        pused += 1

    nz = canvas.reshape(-1, 3)
    nzm = nz[nz.any(axis=1)]
    print("%s: %d primary tiles + %d paired chunks blitted" % (level, used, pused))
    print("mean RGB of painted texels  (%.3f, %.3f, %.3f)   mean alpha %.3f"
          % (nzm[:, 0].mean() / 255, nzm[:, 1].mean() / 255,
             nzm[:, 2].mean() / 255,
             (asum[0] / acnt[0] / 255.0) if acnt[0] else -1))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    R.write_png(out, size, size, bytearray(canvas.tobytes()))
    print("wrote %s" % out)


if __name__ == "__main__":
    main()
