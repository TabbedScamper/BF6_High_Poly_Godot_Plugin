"""MP_Subsurface: render the terrain colour map to a PNG.

Adapted from probe_tung_colorrender.py, but for this map's actual layout: the
colour tile is the LAST 17,424 bytes of a primary chunk (one 132x132 BC7 tile,
33x33 blocks, 100.0% mode 6 -- probe_subsurface_decomp.py). Blocks are decoded
as full BC7 mode 6 (two RGBA endpoints + 4-bit indices), other modes as their
endpoint-free mean grey, and the tiles are mosaicked coarse-first over the
block-0 root AABB.

Usage: probe_subsurface_colorrender.py [level] [--size 1024] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_tung_colorrender as R       # noqa: E402
import probe_tung_bc7mode6 as B6         # noqa: E402

TILE = 17424
BLOCKS = 33                # 33 x 33 blocks
SIDE = BLOCKS * 4          # 132 texels

W4 = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]


def decode_tile(seg):
    """17,424-byte BC7 tile -> SIDE x SIDE x 3 bytearray (mode 6 exact)."""
    img = bytearray(SIDE * SIDE * 3)
    for bi in range(BLOCKS * BLOCKS):
        block = seg[bi * 16:(bi + 1) * 16]
        bx = (bi % BLOCKS) * 4
        by = (bi // BLOCKS) * 4
        ep = B6.mode6_endpoints(block)
        if ep is None:
            # non-mode-6: flat 0 (rare here; decomp says 100% mode 6)
            continue
        e0, e1 = ep
        b = B6.Bits(block)
        b.get(7 + 8 * 7 + 2)             # skip mode + endpoints + P bits
        for t in range(16):
            n = 3 if t == 0 else 4
            idx = b.get(n)
            w = W4[idx * 2] if t == 0 else W4[idx]
            px = bx + (t % 4)
            py = by + (t // 4)
            di = (py * SIDE + px) * 3
            for c in range(3):
                img[di + c] = (e0[c] * (64 - w) + e1[c] * w + 32) >> 6
    return img


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_subsurface"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "FIXED_%s.png" % level)

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
    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])
    print("%s: root XZ %s .. %s, %d nodes -> %s" % (level, lo, hi, len(nodes), out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    means = []
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < TILE + 100000:      # depth-0/1 chunks have no height+tile
            continue
        tile = decode_tile(buf[-TILE:])
        means.append(sum(tile) / len(tile))
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        for dz in range(hgt):
            sz = int(dz / hgt * SIDE)
            for dx in range(w):
                sx = int(dx / w * SIDE)
                si = (sz * SIDE + sx) * 3
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    img[di:di + 3] = tile[si:si + 3]
        used += 1
    R.write_png(out, size, size, img)
    print("wrote %s from %d tiles; overall mean %.3f (0..1: %.3f)"
          % (out, used, sum(means) / len(means), sum(means) / len(means) / 255.0))


if __name__ == "__main__":
    main()
