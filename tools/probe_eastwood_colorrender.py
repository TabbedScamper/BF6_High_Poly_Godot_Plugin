"""Assemble MP_Eastwood's terrain colour map into a PNG so it can be LOOKED at.

Unlike probe_tung_colorrender.py (which blits raw trailing planes), this
decodes the real BC7 colour tiles through
BF6_Frostbite_Research/impl/pipeline/bf6_colormap.py (DDS-wrap + Pillow):

  * primary trailer k=1 x 17424  -> one 132x132 BC7 tile (most nodes);
  * primary trailer 85024        -> a 260x260 + 132x132 mip pair; the 260 tile
    (trailer start) is the colour raster (probe_eastwood_decomp.py's mode scan:
    the clean modes-4-7 region is exactly the first 67,600+ bytes);
  * 5 packed-height chunks have no trailer.

Tiles are blitted coarse-first into a world-square image over the block-0 root
AABB, apron cropped.

READ-ONLY against the dump; writes ONLY the output PNG.

Usage:  probe_eastwood_colorrender.py [level] [--size 1024] [--out path]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402
import probe_tung_colorrender as R       # noqa: E402
import probe_eastwood_decomp as X        # noqa: E402
import bf6_colormap as CM                # noqa: E402


def main():
    from PIL import Image
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_eastwood"
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 1024
    out = sys.argv[sys.argv.index("--out") + 1] if "--out" in sys.argv else \
        os.path.join(os.environ["APPDATA"], "Godot", "app_userdata",
                     "Battlefield™ Portal Project", "_cmapprobe",
                     "FIXED_MP_Eastwood.png")

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            lo = (ns[0][2][0], ns[0][2][2])
            hi = (ns[0][3][0], ns[0][3][2])
            break

    img = Image.new("RGB", (size, size))
    nodes.sort(key=lambda n: n["depth"])
    used, skipped = 0, 0
    means = []
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        decs = X.decompose_any(len(buf), 2592)
        if not decs:
            skipped += 1
            continue
        pre, pages, k, tile = max(decs, key=lambda q: q[2] * q[3])
        if k == 0:
            skipped += 1
            continue
        toff = len(buf) - k * tile
        side = {17424: 132, 85024: 260, 4624: 68}[tile]
        try:
            timg = CM.decode_tile(buf[toff:], side)
        except Exception as ex:
            skipped += 1
            continue
        b0, b1, b2, b3 = R.bounds_of(n["key"], lo, hi)
        x0 = int(round((b0 - lo[0]) / (hi[0] - lo[0]) * size))
        z0 = int(round((b1 - lo[1]) / (hi[1] - lo[1]) * size))
        x1 = int(round((b2 - lo[0]) / (hi[0] - lo[0]) * size))
        z1 = int(round((b3 - lo[1]) / (hi[1] - lo[1]) * size))
        if x1 <= x0 or z1 <= z0:
            continue
        img.paste(timg.convert("RGB").resize((x1 - x0, z1 - z0)), (x0, z0))
        used += 1
        st = timg.convert("RGB").resize((1, 1)).getpixel((0, 0))
        means.append(st)
    img.save(out)
    if means:
        mr = sum(m[0] for m in means) / len(means) / 255.0
        mg = sum(m[1] for m in means) / len(means) / 255.0
        mb = sum(m[2] for m in means) / len(means) / 255.0
        print("mean tile RGB (%.3f, %.3f, %.3f) over %d tiles" % (mr, mg, mb, used))
    print("wrote %s from %d nodes (%d skipped)" % (out, used, skipped))


if __name__ == "__main__":
    main()
