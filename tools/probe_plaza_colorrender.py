"""Assemble MP_Plaza's colour tiles into PNGs so they can be LOOKED at.

Unlike probe_tung_colorrender.py (raw 66x66 planes), plaza's trailer is a
single 67600-byte BC7 tile per node (65x65 blocks = 260x260 texels). This
renders at BLOCK resolution using probe_plaza_bc7mean.block_mean (endpoint
midpoints, rotation-aware), coarse-first so finer nodes overwrite.

Writes TWO images: the RGB colour map (FIXED_<Level>.png, the fleet-brief
deliverable) and the alpha plane (ALPHA_<Level>.png, the AO/shadow question).

Usage:  probe_plaza_colorrender.py [level] [--size 1040] [--outdir path]
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_plaza_bc7mean as B          # noqa: E402
from probe_tung_colorrender import bounds_of, write_png   # noqa: E402

BSIDE = 65


def write_png_gray(path, w, h, gray):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += gray[y * w:(y + 1) * w]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_plaza"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1040
    outdir = sys.argv[sys.argv.index("--outdir") + 1] if "--outdir" in sys.argv \
        else os.path.join(os.environ["APPDATA"], "Godot", "app_userdata",
                          "Battlefield™ Portal Project", "_cmapprobe")
    os.makedirs(outdir, exist_ok=True)

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

    img = bytearray(size * size * 3)
    alp = bytearray(size * size)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        s = os.path.getsize(p)
        if s % B.PSIZE == 0:
            continue                       # pages-only chunk, no tile
        buf = C.read(p)
        tile = buf[-B.TILE:]
        # decode the 65x65 block means once
        grid = [None] * (BSIDE * BSIDE)
        for bi in range(BSIDE * BSIDE):
            grid[bi] = B.block_mean(tile[bi * 16:bi * 16 + 16])
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        for dz in range(hgt):
            sz = int(dz / hgt * BSIDE)
            for dx in range(w):
                sx = int(dx / w * BSIDE)
                g = grid[sz * BSIDE + sx]
                if g is None:
                    continue
                di = ((z0 + dz) * size + (x0 + dx))
                if 0 <= di < size * size and 0 <= x0 + dx < size:
                    img[di * 3 + 0] = int(g[0])
                    img[di * 3 + 1] = int(g[1])
                    img[di * 3 + 2] = int(g[2])
                    alp[di] = int(g[3])
        used += 1
    p1 = os.path.join(outdir, "FIXED_%s.png" % level.replace("mp_", "MP_", 1).replace("plaza", "Plaza"))
    p2 = os.path.join(outdir, "ALPHA_%s.png" % level.replace("mp_", "MP_", 1).replace("plaza", "Plaza"))
    write_png(p1, size, size, img)
    write_png_gray(p2, size, size, alp)
    print("wrote %s and %s from %d nodes" % (p1, p2, used))


if __name__ == "__main__":
    main()
