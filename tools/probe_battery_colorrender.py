"""Assemble MP_Battery's terrain colour map (the 260x260 BC7 tile per node)
into one PNG so it can be LOOKED at, and report its mean against the SDK's
overhead image.

Battery's trailer is a SINGLE 67,600-byte tile per primary chunk (residual
216,897 = 149,297 height prefix + 1 x 67,600; probe_battery_decomp.py), decoded
here through bf6_colormap.decode_tile (BC7 via the Pillow DDS wrap). Coarse
nodes are blitted first, leaves overwrite -- same scheme as
probe_tung_colorrender.py, but with a real BC7 decode instead of raw planes.

Usage:  probe_battery_colorrender.py [level] [--size 2048] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402
import probe_battery_decomp as D     # noqa: E402
import bf6_colormap as CM            # noqa: E402

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


def main():
    from PIL import Image
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_battery"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2048
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else \
        os.path.join(os.environ["APPDATA"], "Godot", "app_userdata",
                     "Battlefield™ Portal Project", "_cmapprobe",
                     "FIXED_MP_Battery.png")

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    pages = {}
    root = None
    for t, off, bsz in blocks:
        if t == 1:
            pages = D.splat_pages_per_node(d, off, bsz)
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, bsz, h)
            root = (ns[0][2], ns[0][3])
    lo = (root[0][0], root[0][2])
    hi = (root[1][0], root[1][2])

    # detect layout the same way the probe does
    resid = {}
    for n in nodes:
        pc = pages.get(n["key"], 0)
        resid.setdefault(n["key"], pc)
    PS = 4356
    TB = 67600
    SIDE = 260

    canvas = Image.new("RGB", (size, size))
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    acc = [0.0, 0.0, 0.0, 0.0]
    accn = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        pc = pages.get(n["key"], 0)
        r = len(buf) - pc * PS
        f = D.tiles_in(r, TB)
        if f is None or f[0] != 1:
            continue
        tile = buf[len(buf) - TB:]
        img = CM.decode_tile(tile, SIDE, crop_apron=True)      # 256x256 RGBA
        # accumulate mean. NOTE: never resize RGBA before measuring -- Pillow
        # premultiplies by alpha when resampling RGBA, and these tiles carry
        # alpha ~0.002, which collapses the RGB mean to ~0. Convert to RGB
        # (and measure alpha separately) BEFORE any resize.
        px = list(img.convert("RGB").getdata())
        pa = [q[3] for q in img.getdata()]
        for c in range(3):
            acc[c] += sum(q[c] for q in px) / len(px) / 255.0
        acc[3] += sum(pa) / len(pa) / 255.0
        accn += 1
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        w = max(1, x1 - x0)
        hgt = max(1, z1 - z0)
        canvas.paste(img.convert("RGB").resize((w, hgt)), (x0, z0))
        used += 1
    os.makedirs(os.path.dirname(out), exist_ok=True)
    canvas.save(out)
    print("wrote %s from %d node tiles (%d directory nodes)" % (out, used, len(nodes)))
    if accn:
        print("mean RGBA over per-tile means: (%.3f, %.3f, %.3f, %.3f)"
              % tuple(a / accn for a in acc))


if __name__ == "__main__":
    main()
