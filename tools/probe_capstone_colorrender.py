"""Assemble MP_Capstone's terrain colour map into a PNG so it can be LOOKED at.

Unlike probe_tung_colorrender.py (which blits raw byte planes), this decodes the
real BC7 colour tile -- the LAST 17,424 bytes of each primary chunk on this map
(probe_capstone_decomp.py: 189/197 primary chunks end with exactly one
132 x 132 BC7 tile at 99.6% modes 4-7) -- through
BF6_Frostbite_Research/impl/pipeline/bf6_colormap.py's DDS-wrap decoder, and
blits coarse-first into a square spanning the block-0 root AABB.

Also prints the assembled image's mean RGB against the SDK overhead image
(addons/bf_portal/terrain_decal/textures/MP_Capstone.jpg) when Pillow can read
it, which is the tungsten acceptance test (mean within ~0.03/channel, no
channel swap).

Usage:  probe_capstone_colorrender.py [level] [--size 1024] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import probe_tung_colorrender as R   # noqa: E402
import bf6_colormap as CM            # noqa: E402

TILE = 17424
SIDE = 132


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_capstone"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else os.path.join(
        os.environ.get("APPDATA", "."), "Godot", "app_userdata",
        "Battlefield\u2122 Portal Project", "_cmapprobe", "FIXED_MP_Capstone.png")

    from PIL import Image
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

    img = Image.new("RGB", (size, size))
    nodes.sort(key=lambda n: n["depth"])
    used = skipped = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < TILE:
            continue
        win = buf[-TILE:]
        hcnt = M.bc7_modes(win)
        tot = sum(hcnt.values())
        hi47 = sum(c for m, c in hcnt.items() if isinstance(m, int) and m >= 4)
        if tot == 0 or hi47 / tot < 0.90:
            skipped += 1
            continue
        tile = CM.decode_tile(win, SIDE).convert("RGB")   # apron cropped -> 128x128
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        w, hh = max(1, x1 - x0), max(1, z1 - z0)
        img.paste(tile.resize((w, hh), Image.BILINEAR), (x0, z0))
        used += 1
    os.makedirs(os.path.dirname(out), exist_ok=True)
    img.save(out)
    px = list(img.resize((64, 64), Image.BILINEAR).getdata())
    mean = tuple(sum(c[i] for c in px) / len(px) / 255.0 for i in range(3))
    print("wrote %s from %d nodes (%d skipped, no image tile)" % (out, used, skipped))
    print("assembled mean RGB (%.3f, %.3f, %.3f)" % mean)

    sdk = r"C:\PortalSDK\GodotProject\addons\bf_portal\terrain_decal\textures\MP_Capstone.jpg"
    if os.path.isfile(sdk):
        try:
            ref = Image.open(sdk).convert("RGB").resize((64, 64), Image.BILINEAR)
            rp = list(ref.getdata())
            rmean = tuple(sum(c[i] for c in rp) / len(rp) / 255.0 for i in range(3))
            print("SDK overhead mean RGB (%.3f, %.3f, %.3f)" % rmean)
        except Exception as e:
            print("SDK overhead unreadable: %s" % e)


if __name__ == "__main__":
    main()
