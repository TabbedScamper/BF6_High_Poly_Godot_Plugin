"""Assemble a level's terrain colour planes into a PNG so they can be LOOKED at.

A mean is not evidence that a decode is correct (that mistake is recorded in
docs/GROUND-LAYERS.md). This writes the actual picture.

Reads each streaming node's primary chunk, takes the trailing 66x66 raw planes,
crops the 1-texel apron, and blits coarse-first into a square whose extent is
the block-0 root AABB. Writes PNG with nothing but zlib.

Usage:  probe_tung_colorrender.py [level] [--size 1024] [--planes 0,1,2] [--out path]
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PLANE = 4356
SIDE = 66
CHILD_X = [0, 1, 1, 0]
CHILD_Z = [0, 0, 1, 1]


def bounds_of(key, lo, hi):
    """TERRAIN.md 2.4 traversal-order child quadrants, from root key 3."""
    nib = []
    k = key
    while k > 3:
        nib.append(k & 0xF)
        k >>= 4
    nib.reverse()
    x0, z0, x1, z1 = lo[0], lo[1], hi[0], hi[1]
    for i in nib:
        hx = (x0 + x1) / 2.0
        hz = (z0 + z1) / 2.0
        if CHILD_X[i]:
            x0 = hx
        else:
            x1 = hx
        if CHILD_Z[i]:
            z0 = hz
        else:
            z1 = hz
    return x0, z0, x1, z1


def write_png(path, w, h, rgb):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw += rgb[y * w * 3:(y + 1) * w * 3]

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    planes = [int(x) for x in (sys.argv[sys.argv.index("--planes") + 1].split(",")
                               if "--planes" in sys.argv else "0,1,2".split(","))]
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "%s_color.png" % level)

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    root = None
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            root = (ns[0][2], ns[0][3])
            break
    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])
    print("%s: root XZ %s .. %s, %d nodes, planes %s -> %s"
          % (level, lo, hi, len(nodes), planes, out))

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        need = (8 - min(planes)) * PLANE
        if len(buf) < need:
            continue
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        chans = []
        for pi in planes:
            s = len(buf) - (8 - pi) * PLANE
            chans.append(buf[s:s + PLANE])
        for dz in range(hgt):
            sz = 1 + int(dz / hgt * (SIDE - 2))
            for dx in range(w):
                sx = 1 + int(dx / w * (SIDE - 2))
                si = sz * SIDE + sx
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    for c in range(3):
                        img[di + c] = chans[c][si]
        used += 1
    write_png(out, size, size, img)
    print("wrote %s from %d nodes" % (out, used))


if __name__ == "__main__":
    main()
