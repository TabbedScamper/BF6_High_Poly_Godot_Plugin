"""Q4 -- does the per-layer float3 0x4FDCF6B1 PREDICT ground colour for
TEXTURELESS layers?

For every textureless layer that carries the tint const and wins splat texels
(probe_painted_coverage's dominance canvas, %TEMP%/bf6_painted/<level>_dom.npy),
this samples the CORRECTED decoded colour map (the per-map probe_*_colorrender
machinery -- page size and tile codec per docs/MAP-*.md) over exactly that
layer's dominant texels and correlates the mean against the tint, per map:

    points = (tint[c], mean_colour[c])  for each qualifying layer x channel
    r_srgb  = Pearson r against the colour-map byte / 255
    r_lin   = Pearson r against (byte/255)^2.2 (linear light)

The colour canvases are produced by shelling out to the fleet's own render
probes (--size SIZE --out <cache>) so the decode is exactly the audited one;
mp_tungsten is decoded inline (its colour tile is the FIRST 17,424-byte tile of
the 2x17,424 trailer -- MAP-TUNGSTEN.md B; no fleet probe renders it corrected).
Canvas extent for every renderer is the block-0 root AABB (verified in each
probe); the dominance canvas extent is the block-1 splat root, so texels are
joined through WORLD coordinates, not pixel indices.

Requires probe_painted_table.py + probe_painted_coverage.py caches (banked).
READ-ONLY on game data; writes only under %TEMP%/bf6_painted.

Usage:  probe_painted_tint.py [all|level...] [--size 2112] [--min-dom 150]
"""
import json
import os
import subprocess
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_painted_common as PC     # noqa: E402
import probe_tung_common as C         # noqa: E402
import probe_tung_terrain as T        # noqa: E402
import probe_tung_colormap as M       # noqa: E402
import bf6_colormap as CM             # noqa: E402

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable

# level -> the audited renderer (None = no corrected renderer / no candidates)
RENDERER = {
    "mp_abbasid": "probe_abbasid_colorrender.py",
    "mp_aftermath": "probe_aftermath_colorrender.py",
    "mp_badlands": "probe_badlands_colorrender.py",
    "mp_battery": "probe_battery_colorrender.py",
    "mp_capstone": "probe_capstone_colorrender.py",
    "mp_contaminated": "probe_contaminated_colorrender.py",
    "mp_dumbo": "probe_dumbo_colorrender.py",
    "mp_eastwood": "probe_eastwood_colorrender.py",
    "mp_firestorm": "probe_firestorm_colorrender.py",
    "mp_golmudrailway": "probe_golmud_bc1color.py",
    "mp_limestone": "probe_limestone_colorrender.py",
    "mp_outskirts": "probe_outskirts_colorrender.py",
    "mp_plaza": "probe_plaza_colorrender.py",
    "mp_portal_sand": "probe_portalsand_colorrender.py",
    "mp_subsurface": "probe_subsurface_colorrender.py",
    "mp_tungsten": None,                       # inline (see render_tungsten)
}


def root_aabb(level):
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            root = (ns[0][2], ns[0][3])
            return (root[0][0], root[0][2]), (root[1][0], root[1][2])
    raise SystemExit("no block 0 in %s" % level)


def render_tungsten(level, size, out):
    """Corrected tungsten colour render: FIRST 17,424-B BC7 tile of the
    2 x 17,424 trailer (MAP-TUNGSTEN.md B4); coarse-first over root AABB."""
    from probe_tung_colorrender import bounds_of
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)
    lo, hi = root_aabb(level)
    img = np.zeros((size, size, 3), np.uint8)
    nodes.sort(key=lambda n: n["depth"])
    used = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < 34848:
            continue
        payload = buf[-34848:-17424]
        h = M.bc7_modes(payload)
        tot = sum(h.values())
        hi4 = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        if not tot or hi4 / tot < 0.5:
            continue                       # not a colour tile (5 odd chunks)
        tile = CM.decode_tile(payload, 132).convert("RGB")
        b0, b1, b2, b3 = bounds_of(n["key"], lo, hi)
        x0 = int((b0 - lo[0]) / (hi[0] - lo[0]) * size)
        z0 = int((b1 - lo[1]) / (hi[1] - lo[1]) * size)
        w = max(1, int((b2 - b0) / (hi[0] - lo[0]) * size))
        hh = max(1, int((b3 - b1) / (hi[1] - lo[1]) * size))
        img[z0:z0 + hh, x0:x0 + w] = np.asarray(
            tile.resize((w, hh), Image.BILINEAR))
        used += 1
    Image.fromarray(img).save(out)
    print("   [tungsten inline] %d tiles -> %s" % (used, out))


def colour_png(level, size):
    out = os.path.join(PC.CACHE, "%s_tintcolor%d.png" % (level, size))
    if os.path.isfile(out):
        return out
    if level == "mp_tungsten":
        render_tungsten(level, size, out)
        return out
    script = RENDERER.get(level)
    if script is None:
        raise SystemExit("no corrected renderer for %s" % level)
    if level == "mp_plaza":
        cmd = [PY, os.path.join(HERE, script), level,
               "--size", str(size), "--outdir", PC.CACHE]
    else:
        cmd = [PY, os.path.join(HERE, script), level,
               "--size", str(size), "--out", out]
    print("   render: %s" % " ".join(os.path.basename(c) for c in cmd[1:]))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit("renderer failed for %s:\n%s\n%s"
                         % (level, r.stdout[-2000:], r.stderr[-2000:]))
    if level == "mp_plaza":
        src = os.path.join(PC.CACHE, "FIXED_MP_Plaza.png")
        os.replace(src, out)
    if not os.path.isfile(out):
        raise SystemExit("renderer for %s wrote nothing at %s" % (level, out))
    return out


def candidates(doc):
    """Textureless tinted layers (the plugin's grey-fallback set)."""
    cov = doc.get("coverage", {})
    out = []
    for r in doc["rows"]:
        c = r["consts"].get("%08x" % PC.TINT_HASH)
        if not c:
            continue
        slot, _cv = PC.albedo_of(r)
        if slot is not None:
            continue                        # textured; fallback not used
        dom = cov.get(str(r["idx"]), {}).get("dominant_texels", 0)
        out.append((r["idx"], [float(v) for v in c[1]], dom))
    return out


def pearson(a, b):
    a = np.asarray(a, np.float64)
    b = np.asarray(b, np.float64)
    if len(a) < 3 or a.std() == 0 or b.std() == 0:
        return float("nan")
    return float(np.corrcoef(a, b)[0, 1])


def one(level, size, min_dom, pooled):
    doc = PC.load_level(level)
    if doc is None:
        print("%s: NO CACHE" % level)
        return
    cand = [c for c in candidates(doc) if c[2] >= min_dom]
    if not cand:
        print("%s: no textureless tinted layer with >=%d dominant texels"
              % (level, min_dom))
        return
    meta = doc["coverage_meta"]
    dom = np.load(os.path.join(PC.CACHE, level + "_dom.npy"))
    full = meta["full"]
    png = colour_png(level, size)
    col = np.asarray(Image.open(png).convert("RGB"))
    lo, hi = root_aabb(level)

    # world coords of every dominance texel centre -> colour canvas indices
    xs = meta["world_x0"] + (np.arange(full) + 0.5) * meta["texel_m"]
    zs = meta["world_z0"] + (np.arange(full) + 0.5) * meta["texel_m"]
    cx = np.clip(((xs - lo[0]) / (hi[0] - lo[0]) * size), 0, size - 1).astype(np.int32)
    cz = np.clip(((zs - lo[1]) / (hi[1] - lo[1]) * size), 0, size - 1).astype(np.int32)

    print("%s  (%d candidate layers; canvas dom %d vs colour %d; splat root "
          "x0=%.0f vs block0 x0=%.0f)"
          % (level, len(cand), full, size, meta["world_x0"], lo[0]))
    tints, means_s = [], []
    rows_out = []
    for idx, tint, domtex in sorted(cand, key=lambda t: -t[2]):
        mask = dom == idx
        if not mask.any():
            continue
        zi, xi = np.nonzero(mask)
        px = col[cz[zi], cx[xi]]
        valid = px.sum(axis=1) > 0             # unwritten canvas is pure black
        if valid.sum() < 60:
            print("   L%02d  dom %7d  <60 valid colour texels -- skipped" % (idx, domtex))
            continue
        mean = px[valid].mean(axis=0) / 255.0
        tints.append(tint)
        means_s.append(mean.tolist())
        rows_out.append(dict(idx=idx, tint=tint, mean_srgb=mean.tolist(),
                             dom_texels=int(domtex), valid=int(valid.sum())))
        print("   L%02d  dom %7d  tint (%.3f %.3f %.3f)  colour-mean "
              "(%.3f %.3f %.3f)"
              % (idx, domtex, tint[0], tint[1], tint[2],
                 mean[0], mean[1], mean[2]))
    if len(tints) >= 2:
        tv = np.array(tints).ravel()
        mv = np.array(means_s).ravel()
        r_s = pearson(tv, mv)
        r_l = pearson(tv, mv ** 2.2)
        print("   => r_srgb %.3f   r_linear %.3f   (%d layers, %d points)"
              % (r_s, r_l, len(tints), len(tv)))
    else:
        r_s = r_l = float("nan")
        print("   => only %d usable layer(s); no per-map r" % len(tints))
    pooled.append((level, tints, means_s))
    PC.merge_level(level, dict(tint=dict(size=size, min_dom=min_dom,
                                         layers=rows_out,
                                         r_srgb=None if np.isnan(r_s) else r_s,
                                         r_linear=None if np.isnan(r_l) else r_l)))


def main():
    size = int(sys.argv[sys.argv.index("--size") + 1]) if "--size" in sys.argv else 2112
    min_dom = int(sys.argv[sys.argv.index("--min-dom") + 1]) \
        if "--min-dom" in sys.argv else 150
    levels = PC.roster(sys.argv)
    pooled = []
    for lv in levels:
        try:
            one(lv, size, min_dom, pooled)
        except (SystemExit, Exception) as e:      # noqa: BLE001 -- keep sweeping
            print("%s: FAILED %s" % (lv, e))
    tv, mv = [], []
    for _lv, ts, ms in pooled:
        for t, m in zip(ts, ms):
            tv.extend(t)
            mv.extend(m)
    if len(tv) >= 6:
        tva, mva = np.array(tv), np.array(mv)
        print()
        print("=== POOLED across maps: %d layer-channels  r_srgb %.3f  "
              "r_linear %.3f" % (len(tv), pearson(tva, mva),
                                 pearson(tva, mva ** 2.2)))


if __name__ == "__main__":
    main()
