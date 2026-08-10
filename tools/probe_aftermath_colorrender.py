"""Assemble MP_Aftermath's terrain colour map (BC7-decoded) into a PNG.

Unlike probe_tung_colorrender.py (which blitted raw trailing planes), this
decodes each primary chunk's single trailing 17,424-byte 132^2 BC7 tile through
BF6_Frostbite_Research/impl/pipeline/bf6_colormap.decode_tile (DDS-wrap +
Pillow) and blits coarse-first into a world-square image. Chunks whose trailing
bytes are not a colour tile (pages-only chunks; BC7 modes 4-7 share < 50%) are
skipped.

Also prints the assembled map's mean RGB against the SDK overhead image's mean,
which is the correctness check MAP-TUNGSTEN.md C2 established.

Usage:  probe_aftermath_colorrender.py [level] [--size 2048] [--out path]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import bf6_colormap as CM            # noqa: E402

TILE = 17424
SIDE = 132

CHILD_X = [0, 1, 1, 0]
CHILD_Z = [0, 0, 1, 1]


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


def modes47(buf):
    hi = tot = 0
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        tot += 1
        if b and not (b & 0x0F):
            hi += 1
    return hi / tot if tot else 0.0


def main():
    from PIL import Image
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_aftermath"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else os.path.join(
        os.environ.get("APPDATA", "."), "Godot", "app_userdata",
        "Battlefield\u2122 Portal Project", "_cmapprobe", "FIXED_MP_Aftermath.png")

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
    print("%s: root XZ (%.0f, %.0f)..(%.0f, %.0f), %d nodes -> %s"
          % (level, lo[0], lo[1], hi[0], hi[1], len(nodes), out))

    img = Image.new("RGB", (size, size))
    nodes.sort(key=lambda n: n["depth"])
    used = skipped = 0
    per_depth = collections.Counter()
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < TILE or modes47(buf[-TILE:]) < 0.5:
            skipped += 1
            continue
        tile = CM.decode_tile(buf[-TILE:], SIDE)        # RGBA, apron cropped
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        img.paste(tile.convert("RGB").resize((max(1, x1 - x0), max(1, z1 - z0)),
                                             Image.BILINEAR), (x0, z0))
        used += 1
        per_depth[n["depth"]] += 1
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    px = img.resize((256, 256), Image.BILINEAR)
    stat = [sum(ch) / (256 * 256 * 255.0) for ch in zip(*px.getdata())]
    print("wrote %s  from %d tiles (skipped %d tile-less)  per depth %s"
          % (out, used, skipped, dict(per_depth)))
    print("assembled mean RGB (%.3f, %.3f, %.3f)" % tuple(stat))

    sdk = os.path.join(r"C:\PortalSDK\GodotProject", "addons", "bf_portal",
                       "terrain_decal", "textures", "MP_Aftermath.jpg")
    if os.path.isfile(sdk):
        ref = Image.open(sdk).convert("RGB").resize((256, 256))
        rstat = [sum(ch) / (256 * 256 * 255.0) for ch in zip(*ref.getdata())]
        print("SDK overhead mean  (%.3f, %.3f, %.3f)  (%s)" % (*rstat, sdk))


if __name__ == "__main__":
    main()
