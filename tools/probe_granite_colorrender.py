"""Assemble a Granite level's terrain colour map to a PNG.

THE GRANITE LEVELS SHIP TWO DIFFERENT COLOUR-TILE CODECS — the load-bearing
finding of this probe:

2592-family (base, underground, clubhouse, mainstreet, techcampus) —
page size 2592, per-node trailer:

    residual 26136 = [ 8712 B BC1 132x132 colour tile ]  <- FIRST
                     [ 17424 B degenerate BC7 tile (mode-3 constant blocks) ]
    residual 17424 = [ 8712 BC1 colour ] [ 8712 second raster ]
    residual  8712 = [ 8712 BC1 colour ]
    residual     0 = no colour

    The colour tile is BC1, not BC7. Decoding the FIRST 8712 bytes of the
    trailer as a 33x33-block BC1 tile mosaicks into a seamless aerial photo;
    decoding the same bytes as BC7 modes, raw planes, or BC4 yields noise
    (all three were tried and are ruled out).

5184-family (marina, militaryrnd, militarystorage) — page size 5184,
per-node trailer:

    residual 85024 = [ 67600 B BC7 260x260 colour tile ][ 17424 B 132 mip ]
    residual 67600 = [ 67600 B BC7 260x260 colour tile ]
    residual 17424 = one degenerate BC7 tile (100% mode-3 constant) — no colour
    residual     0 = no colour

    Their BC7 colour tiles are ~97% mode 6, rendered here from the mode-6
    endpoint midpoints (block-mean, 65x65 per node — ample for a mosaic).

Usage:  probe_granite_colorrender.py [slug] [--size 1024] [--out path]
        probe_granite_colorrender.py --all        (all 8, writes FIXED_*.png
                                                   into the _cmapprobe dir)
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G         # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_granite_layout as L         # noqa: E402
from probe_tung_colorrender import bounds_of, write_png   # noqa: E402

C = G.C
TILE = 8712          # 33x33 BC1 blocks = 132x132 texels
TS = 132
BC7TILE = 67600      # 65x65 BC7 blocks = 260x260 texels
BTS = 65             # rendered at block resolution (mode-6 block means)
HP = {0: 149297, 2: 39919}
PS = {"base": 2592, "clubhouse": 2592, "mainstreet": 2592, "techcampus": 2592,
      "underground": 2592, "marina": 5184, "militaryrnd": 5184,
      "militarystorage": 5184}

CMAPDIR = os.path.join(os.environ.get("APPDATA", ""), "Godot", "app_userdata",
                       "Battlefield™ Portal Project", "_cmapprobe")


def bc1_decode(tile):
    """8712 B BC1 -> RGB bytearray 132*132*3."""
    out = bytearray(TS * TS * 3)
    bi = 0
    for by in range(33):
        for bx in range(33):
            o = bi * 8
            bi += 1
            c0, c1 = struct.unpack_from("<HH", tile, o)
            bits = struct.unpack_from("<I", tile, o + 4)[0]

            def rgb(c):
                return (((c >> 11) & 31) * 255 // 31,
                        ((c >> 5) & 63) * 255 // 63,
                        (c & 31) * 255 // 31)
            p0, p1 = rgb(c0), rgb(c1)
            if c0 > c1:
                pal = [p0, p1,
                       tuple((2 * a + b) // 3 for a, b in zip(p0, p1)),
                       tuple((a + 2 * b) // 3 for a, b in zip(p0, p1))]
            else:
                pal = [p0, p1,
                       tuple((a + b) // 2 for a, b in zip(p0, p1)),
                       (0, 0, 0)]
            for py in range(4):
                row = (by * 4 + py) * TS
                for px in range(4):
                    idx = (bits >> (2 * (py * 4 + px))) & 3
                    d = (row + bx * 4 + px) * 3
                    out[d:d + 3] = bytes(pal[idx])
    return out


def bc7_mode6_means(tile):
    """67600 B BC7 -> RGB bytearray 65*65*3 of per-block means (mode 6 only;
    other modes inherit the previous block's colour)."""
    out = bytearray(BTS * BTS * 3)
    prev = (127, 127, 127)
    for bi in range(BTS * BTS):
        o = bi * 8 * 2
        v = int.from_bytes(tile[o:o + 16], "little")
        if (v & 0x7F) == 0x40:               # mode 6
            r0 = (v >> 7) & 0x7F
            r1 = (v >> 14) & 0x7F
            g0 = (v >> 21) & 0x7F
            g1 = (v >> 28) & 0x7F
            b0 = (v >> 35) & 0x7F
            b1 = (v >> 42) & 0x7F
            p0 = (v >> 63) & 1
            p1 = (v >> 64) & 1
            r = (((r0 << 1) | p0) + ((r1 << 1) | p1)) // 2
            g = (((g0 << 1) | p0) + ((g1 << 1) | p1)) // 2
            b = (((b0 << 1) | p0) + ((b1 << 1) | p1)) // 2
            prev = (r, g, b)
        d = bi * 3
        out[d:d + 3] = bytes(prev)
    return out


def render(slug, size, out):
    td = G.terr_dir(slug)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    ext = collections.defaultdict(int)
    root = None
    for t, off, size_b in blocks:
        if t in (0, 2):
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            if t == 0:
                root = (ns[0][2], ns[0][3])
            for key, dep, mn, mx, kind in ns:
                if kind == "External":
                    ext[key] += HP[t]
    pages = {}
    for t, off, size_b in blocks:
        if t == 1:
            pages = L.splat_pages_by_key(d, off, size_b)

    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])
    ps = PS[slug]
    img = bytearray(size * size * 3)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        if not n["size0"]:
            continue
        spc = pages.get(n["key"], (0, 0))[1]
        t0 = ext.get(n["key"], 0) + spc * ps
        r = n["size0"] - t0
        if ps == 2592:
            if r < TILE:
                continue
            codec = "bc1"
        else:
            if r < BC7TILE:
                continue                      # 17424 residual = degenerate
            codec = "bc7"
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if codec == "bc1":
            tile, side, apron = bc1_decode(buf[t0:t0 + TILE]), TS, 2
        else:
            tile, side, apron = bc7_mode6_means(buf[t0:t0 + BC7TILE]), BTS, 1
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hgt = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        for dz in range(hgt):
            sz = apron + int(dz / hgt * (side - 2 * apron))
            for dx in range(w):
                sx = apron + int(dx / w * (side - 2 * apron))
                si = (sz * side + sx) * 3
                di = ((z0 + dz) * size + (x0 + dx)) * 3
                if 0 <= di < len(img) - 2 and 0 <= x0 + dx < size:
                    img[di:di + 3] = tile[si:si + 3]
        used += 1
    write_png(out, size, size, img)
    mean = [0.0, 0.0, 0.0]
    tot = r = 0
    for i in range(0, len(img), 3):
        if img[i] or img[i + 1] or img[i + 2]:
            mean[0] += img[i]
            mean[1] += img[i + 1]
            mean[2] += img[i + 2]
            tot += 1
    if tot:
        mean = [m / tot / 255.0 for m in mean]
    print("%-16s wrote %s from %d nodes, mean RGB (%.3f, %.3f, %.3f)"
          % (slug, out, used, *mean))


def main():
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    if "--all" in sys.argv:
        os.makedirs(CMAPDIR, exist_ok=True)
        names = {"base": "MP_Granite",
                 "clubhouse": "MP_Granite_ClubHouse_Portal",
                 "mainstreet": "MP_Granite_MainStreet_Portal",
                 "marina": "MP_Granite_Marina_Portal",
                 "militaryrnd": "MP_Granite_MilitaryRnD_Portal",
                 "militarystorage": "MP_Granite_MilitaryStorage_Portal",
                 "techcampus": "MP_Granite_TechCampus_Portal",
                 "underground": "MP_Granite_Underground_Portal"}
        for slug in ["base"] + G.SLUGS:
            render(slug, size, os.path.join(CMAPDIR, "FIXED_%s.png" % names[slug]))
        return
    slug = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "base"
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "granite_%s_bc1.png" % slug)
    render(slug, size, out)


if __name__ == "__main__":
    main()
