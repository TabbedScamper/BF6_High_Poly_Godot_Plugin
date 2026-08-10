"""MP_GolmudRailway's colour map: a 132x132 BC1 tile (8,712 bytes), not BC7.

Golmud's primary chunks fall in residue classes {0, 936, 2489} mod 2592, and
936 = 8712 mod 2592, where 8712 = 33x33 blocks x 8 bytes = one 132x132 BC1
tile -- half the size of Tungsten's 132x132 BC7 tile (17,424). This probe
(a) verifies the BC1 reading structurally (endpoint colour statistics, index
usage, punch-through fraction), (b) computes the map-wide mean colour, and
(c) assembles the colour map coarse-first into a PNG at block resolution.

Usage: probe_golmud_bc1color.py [level] [--size 2048] [--out path]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import probe_tung_colorrender as R   # noqa: E402

TILE = 8712          # 33x33 BC1 blocks = 132x132 texels
BSIDE = 33


def c565(v):
    return (((v >> 11) & 31) * 255 // 31,
            ((v >> 5) & 63) * 255 // 63,
            (v & 31) * 255 // 31)


# per-byte 2-bit index histogram, precomputed
_BH = []
for b in range(256):
    h = [0, 0, 0, 0]
    for s in range(0, 8, 2):
        h[(b >> s) & 3] += 1
    _BH.append(tuple(h))


def block_mean(blk):
    """(r,g,b, n_transparent, fourcolor) mean over the 16 texels."""
    c0, c1 = struct.unpack_from("<HH", blk, 0)
    p0, p1 = c565(c0), c565(c1)
    four = c0 > c1
    if four:
        pal = (p0, p1,
               tuple((2 * a + b) // 3 for a, b in zip(p0, p1)),
               tuple((a + 2 * b) // 3 for a, b in zip(p0, p1)))
    else:
        pal = (p0, p1,
               tuple((a + b) // 2 for a, b in zip(p0, p1)),
               (0, 0, 0))
    h = [0, 0, 0, 0]
    for i in range(4, 8):
        bh = _BH[blk[i]]
        for j in range(4):
            h[j] += bh[j]
    n = 16
    r = sum(pal[j][0] * h[j] for j in range(4)) / n
    g = sum(pal[j][1] * h[j] for j in range(4)) / n
    b = sum(pal[j][2] * h[j] for j in range(4)) / n
    return r, g, b, (0 if four else h[3]), four


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_golmudrailway"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    if "--out" in sys.argv:
        out = sys.argv[sys.argv.index("--out") + 1]
    else:
        out = os.path.join(os.environ["APPDATA"], "Godot", "app_userdata",
                           "Battlefield™ Portal Project", "_cmapprobe",
                           "FIXED_MP_GolmudRailway.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)

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

    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    acc = [0.0, 0.0, 0.0]
    nacc = 0
    trans = 0
    four = 0
    nblk = 0
    per_depth = collections.Counter()
    epdist = collections.Counter()
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        s = os.path.getsize(p)
        if s % 2592 not in (936, 2489):
            continue                     # no colour tile in this chunk
        buf = C.read(p)
        tile = buf[-TILE:]
        # block means, row-major 33x33
        means = []
        for i in range(0, TILE, 8):
            r, g, b, tr, fc = block_mean(tile[i:i + 8])
            means.append((r, g, b))
            acc[0] += r; acc[1] += g; acc[2] += b
            nacc += 1
            trans += tr
            four += fc
            nblk += 1
            c0, c1 = struct.unpack_from("<HH", tile, i)
            q0, q1 = c565(c0), c565(c1)
            dd = max(abs(a - b2) for a, b2 in zip(q0, q1))
            epdist[min(dd // 32, 7)] += 1
        per_depth[n["depth"]] += 1
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        for dz in range(hgt):
            sz = int((dz + 0.5) / hgt * BSIDE)
            for dx in range(w):
                sx = int((dx + 0.5) / w * BSIDE)
                mr, mg, mb = means[sz * BSIDE + sx]
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2:
                    img[di] = int(mr); img[di + 1] = int(mg); img[di + 2] = int(mb)
        used += 1
    R.write_png(out, size, size, img)
    print("%s: %d tiles rendered (%d blocks) -> %s" % (level, used, nblk, out))
    print("   tiles per node depth: %s" % dict(sorted(per_depth.items())))
    print("   mean RGB (%.3f, %.3f, %.3f)"
          % (acc[0] / nacc / 255, acc[1] / nacc / 255, acc[2] / nacc / 255))
    print("   four-colour blocks %.1f%%   punch-through texels %.2f%%"
          % (100.0 * four / nblk, 100.0 * trans / (nblk * 16)))
    print("   endpoint max-channel-delta histogram (x32): %s"
          % dict(sorted(epdist.items())))


if __name__ == "__main__":
    main()
