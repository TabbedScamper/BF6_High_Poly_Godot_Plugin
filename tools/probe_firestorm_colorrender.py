"""Assemble MP_FireStorm's terrain colour map into a PNG so it can be LOOKED at.

Unlike mp_tungsten (raw-plane render in probe_tung_colorrender.py), firestorm's
colour data is one 260x260 BC7 tile at the END of every depth>=2 primary chunk
(probe_firestorm_decomp.py). Tiles are decoded through
BF6_Frostbite_Research/impl/pipeline/bf6_colormap.py (BC7 via a minimal DDS
wrapper and Pillow), aprons cropped, and blitted coarse-first into a square
covering the block-0 root AABB. Depth 0/1 nodes ship no tile and are skipped —
depth 2 already covers the world 4x4.

Usage:  probe_firestorm_colorrender.py [level] [--size 2048] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_tung_colorrender as R       # noqa: E402
import bf6_colormap as CM                # noqa: E402

TILE = 67600
SIDE = 260


def main():
    from PIL import Image
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_firestorm"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
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
    print("%s: root XZ %s .. %s, %d nodes -> %s" % (level, lo, hi, len(nodes), out))

    img = Image.new("RGB", (size, size))
    nodes.sort(key=lambda n: n["depth"])
    used = skipped = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < TILE:
            skipped += 1
            continue
        tail = buf[-TILE:]
        # only depth>=2 primaries end in a tile; verify cheaply via mode bytes
        if CM and True:
            good = sum(1 for i in range(0, TILE, 16 * 64)
                       if tail[i] and not (tail[i] & 0x0F))
            if good < (TILE // (16 * 64)) * 0.9:
                skipped += 1
                continue
        tile = CM.decode_tile(tail, SIDE)          # RGBA, apron cropped -> 256^2
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        w, hgt = max(1, x1 - x0), max(1, z1 - z0)
        img.paste(tile.convert("RGB").resize((w, hgt), Image.BILINEAR), (x0, z0))
        used += 1
    img.save(out)
    px = list(img.resize((64, 64), Image.BILINEAR).getdata())
    mean = tuple(sum(c[i] for c in px) / len(px) / 255.0 for i in range(3))
    print("wrote %s from %d tiles (%d chunks without a tile); mean RGB (%.3f, %.3f, %.3f)"
          % (out, used, skipped, *mean))


if __name__ == "__main__":
    main()
