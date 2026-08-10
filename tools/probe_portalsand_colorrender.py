"""Assemble MP_Portal_Sand's terrain colour map into a PNG so it can be LOOKED at.

Unlike every previously rendered map, this map's colour tile is BC1
(one 8712-B 132x132 tile per external-height chunk -- probe_portalsand_decomp),
so this probe carries a full BC1 decoder rather than the raw-plane shortcut of
probe_tung_colorrender.py.

Blits coarse-first (depth order) over the block-0 root AABB; the 132x132 tile is
used with a 1-texel apron crop (130 interior texels), matching the 66x66-page
convention scaled x2.

Usage:  probe_portalsand_colorrender.py [--size 1024] [--out path]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_portalsand_common as PC     # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_tung_colorrender as R       # noqa: E402

TILE = 8712
SIDE = 132


def bc1_tile(tile):
    """Decode one 132x132 BC1 tile -> bytearray RGB (SIDE*SIDE*3)."""
    out = bytearray(SIDE * SIDE * 3)
    bs = SIDE // 4
    for by in range(bs):
        for bx in range(bs):
            i = (by * bs + bx) * 8
            c0, c1, idx = struct.unpack_from("<HHI", tile, i)
            pal = []
            for c in (c0, c1):
                pal.append(((c >> 11 & 0x1F) * 255 // 31,
                            (c >> 5 & 0x3F) * 255 // 63,
                            (c & 0x1F) * 255 // 31))
            r0, g0, b0 = pal[0]
            r1, g1, b1 = pal[1]
            if c0 > c1:
                pal.append(((2 * r0 + r1) // 3, (2 * g0 + g1) // 3, (2 * b0 + b1) // 3))
                pal.append(((r0 + 2 * r1) // 3, (g0 + 2 * g1) // 3, (b0 + 2 * b1) // 3))
            else:
                pal.append(((r0 + r1) // 2, (g0 + g1) // 2, (b0 + b1) // 2))
                pal.append((0, 0, 0))
            for t in range(16):
                px = bx * 4 + (t & 3)
                py = by * 4 + (t >> 2)
                r, g, b = pal[(idx >> (t * 2)) & 3]
                di = (py * SIDE + px) * 3
                out[di] = r
                out[di + 1] = g
                out[di + 2] = b
    return out


def main():
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else \
        os.path.join(os.environ["APPDATA"], "Godot", "app_userdata",
                     "Battlefield™ Portal Project", "_cmapprobe",
                     "FIXED_MP_Portal_Sand.png")

    td = T.terr_dir(PC.LEVEL)
    d = PC.read(T._res(td, ".TerrainStreamingTree"))
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
    print("%s: root XZ %s .. %s, %d nodes -> %s" % (PC.LEVEL, lo, hi, len(nodes), out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    acc = [0, 0, 0, 0]
    for n in nodes:
        p = M.chunk_path(n["g0"]) if n["g0"] else None
        if p is None or not os.path.isfile(p):
            continue
        buf = PC.read(p)
        if len(buf) < TILE + 1000:      # the 10368-B page-only chunks have no tile
            continue
        rgb = bc1_tile(buf[-TILE:])
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        for dz in range(hgt):
            sz = 1 + int(dz / hgt * (SIDE - 2))
            for dx in range(w):
                sx = 1 + int(dx / w * (SIDE - 2))
                si = (sz * SIDE + sx) * 3
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    img[di:di + 3] = rgb[si:si + 3]
                    acc[0] += rgb[si]
                    acc[1] += rgb[si + 1]
                    acc[2] += rgb[si + 2]
                    acc[3] += 1
        used += 1
    os.makedirs(os.path.dirname(out), exist_ok=True)
    R.write_png(out, size, size, img)
    print("wrote %s from %d nodes; blitted mean RGB (%.3f, %.3f, %.3f)"
          % (out, used, acc[0] / 255.0 / acc[3], acc[1] / 255.0 / acc[3],
             acc[2] / 255.0 / acc[3]))


if __name__ == "__main__":
    main()
