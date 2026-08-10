"""Assemble MP_Dumbo's terrain colour map — REAL BC7 decode — into a PNG.

Unlike probe_tung_colorrender.py (raw-plane heat view), this decodes each
node's colour tile as actual BC7 through BF6_Frostbite_Research's
bf6_colormap helper (DDS-wrap + Pillow) and blits coarse-first into a square
covering the block-0 root AABB. The tile is the FIRST tile of the trailer at
heightPrefix + pages*2592 (on dumbo the trailer is a single 4624-byte tile,
so first == last; depth 0-1 chunks have NO tile and are skipped). Paired
chunks contribute their four child tiles in reversed child order [3,2,1,0].

Usage:  probe_dumbo_colorrender.py [level] [--size 2048] [--out path]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import bf6_colormap as CM            # noqa: E402

PAGE = 2592
TILE = 4624
SIDE = 68
HEIGHT = 149297

CHILD_X = [0, 1, 1, 0]
CHILD_Z = [0, 0, 1, 1]
PAIRED_ORDER = [3, 2, 1, 0]


def bounds_of(key, lo, hi):
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


def splat_pages(d, base, size):
    end = base + size
    per = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        painted = 0
        for _ in range(rc):
            if not struct.unpack_from("<H", d, o + 20)[0] & 0x0100:
                painted += 1
            o += 33
        per[key] = painted
        if rc == 0:
            return o + 1
        o += 1
        has_children = d[o]
        o += 1
        if o < end:
            o += 1
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return per


def main():
    from PIL import Image
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_dumbo"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv \
        else os.path.join(os.environ.get("TEMP", "."), "FIXED_%s_probe.png" % level)

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    pages = {}
    hkind = {}
    for t, off, sz in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            hn, _k, _s, _z = T.hf_walk(d, off, sz, h)
            hkind = {n[0]: n[4] for n in hn}
            root = hn[0]
            lo = (root[2][0], root[2][2])
            hi = (root[3][0], root[3][2])
        elif t == 1:
            pages = splat_pages(d, off, sz)

    canvas = Image.new("RGB", (size, size))
    tiles = []                      # (depth, key, tile bytes)
    for n in nodes:
        # primary: one tile after heights + pages
        if n["g0"] is not None:
            p = M.chunk_path(n["g0"])
            if os.path.isfile(p):
                buf = C.read(p)
                hp = HEIGHT if hkind.get(n["key"]) == "External" else 0
                toff = hp + pages.get(n["key"], 0) * PAGE
                if len(buf) - toff >= TILE:
                    tiles.append((n["depth"], n["key"], buf[toff:toff + TILE]))
        # paired: four child tiles at the end, reversed child order
        if n["g1"] is not None:
            p = M.chunk_path(n["g1"])
            if os.path.isfile(p):
                buf = C.read(p)
                if len(buf) >= 4 * TILE:
                    for i, ci in enumerate(PAIRED_ORDER):
                        toff = len(buf) - (4 - i) * TILE
                        key = (n["key"] << 4) | ci
                        tiles.append((n["depth"] + 1, key,
                                      buf[toff:toff + TILE]))

    tiles.sort(key=lambda t: t[0])
    used = 0
    for depth, key, payload in tiles:
        try:
            img = CM.decode_tile(payload, SIDE)   # RGBA, apron cropped -> 64x64
        except Exception as ex:
            print("   decode fail 0x%X: %s" % (key, ex))
            continue
        b0, b1, b2, b3 = bounds_of(key, lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        w, hgt = max(1, x1 - x0), max(1, z1 - z0)
        canvas.paste(img.convert("RGB").resize((w, hgt), Image.BILINEAR),
                     (x0, z0))
        used += 1
    canvas.save(out)
    px = canvas.resize((1, 1), Image.BILINEAR).getpixel((0, 0))
    print("%s: wrote %s from %d tiles (%d collected)  mean RGB (%.3f, %.3f, %.3f)"
          % (level, out, used, len(tiles),
             px[0] / 255.0, px[1] / 255.0, px[2] / 255.0))


if __name__ == "__main__":
    main()
