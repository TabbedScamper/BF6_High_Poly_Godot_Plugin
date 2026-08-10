"""Q2 -- PER-LAYER TEXEL COVERAGE and the Texture2DArray slice budget.

Decodes every splat weight page of a level (bf6_splat.SplatMap), composites
the layers with the verified over-operator (higher layerIdx paints OVER lower,
contribution_i = w_i * prod_{j>i}(1 - w_j)) on a world-aligned canvas, and
measures per-layer composited area in texels.  The dominant-layer id per texel
is saved as an .npy next to the level JSON for probe_painted_tint.py.

Usage:  probe_painted_coverage.py [level|all|all+granite] [--depth N]

    --depth N   canvas res = 66 * 2**N over the world square (default 5 =
                2112x2112; area percentages move <0.5pp vs depth 6 -- measured
                on mp_aftermath).

Requires probe_painted_table.py to have cached the level first.
READ-ONLY on game data; writes only under %TEMP%/bf6_painted.
"""
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_painted_common as PC    # noqa: E402
import bf6_splat                     # noqa: E402  (via PC's pipeline path)

try:
    from PIL import Image
except ImportError:
    Image = None


def canvas_for_layer(placements, x0, z0, world, full):
    """Paint one layer's pages coarse-to-fine onto a full-canvas uint8."""
    grid = np.zeros((full, full), np.uint8)
    for bb, plane in sorted(placements, key=lambda t: -(t[0][2] - t[0][0])):
        px0 = int(round((bb[0] - x0) / world * full))
        pz0 = int(round((bb[1] - z0) / world * full))
        px1 = min(int(round((bb[2] - x0) / world * full)), full)
        pz1 = min(int(round((bb[3] - z0) / world * full)), full)
        if px1 <= px0 or pz1 <= pz0:
            continue
        if (px1 - px0, pz1 - pz0) == plane.shape[::-1]:
            grid[pz0:pz1, px0:px1] = plane
        elif Image is not None:
            im = Image.fromarray(plane).resize((px1 - px0, pz1 - pz0),
                                               Image.BILINEAR)
            grid[pz0:pz1, px0:px1] = np.asarray(im)
        else:
            k = max(1, (px1 - px0) // plane.shape[0])
            up = np.repeat(np.repeat(plane, k, 0), k, 1)[:pz1 - pz0, :px1 - px0]
            grid[pz0:pz1, px0:px1] = up
    return grid


def one(level, depth):
    doc = PC.load_level(level)
    if doc is None:
        raise SystemExit("run probe_painted_table.py %s first" % level)
    td = doc["terr_dir"]
    tree = PC._res(td, ".TerrainStreamingTree")
    sm = bf6_splat.SplatMap(tree)
    per_layer = sm.all_placements()
    x0, z0, x1, z1 = sm.bounds
    world = x1 - x0
    full = 66 * (2 ** depth)
    texel_m = world / full

    # Two rules, both reported:
    #  * ARGMAX -- per-texel winner by RAW weight (higher idx wins ties).  This
    #    is what the plugin's splat idx encodes (a slice per texel) and what
    #    probe_splat.gd counted in the editor.
    #  * OVER   -- contribution_i = w_i * prod_{j>i}(1 - w_j), the verified
    #    game composite.  Full-weight textureless veil layers (aftermath L23,
    #    w~0.94 everywhere) dominate it, so it is NOT the slice-choosing rule.
    remaining = np.ones((full, full), np.float32)
    dom = np.full((full, full), 255, np.uint8)      # 255 = fallback
    dom_w = np.zeros((full, full), np.uint8)
    stats = {}
    for idx in sorted(per_layer, reverse=True):     # higher paints OVER lower
        w = canvas_for_layer(per_layer[idx], x0, z0, world, full)
        wf = w.astype(np.float32) / 255.0
        contrib = wf * remaining
        area = float(contrib.sum())
        dominant = w > dom_w                        # raw-weight argmax
        dom[dominant] = idx if idx < 255 else 254
        dom_w[dominant] = w[dominant]
        remaining *= (1.0 - wf)
        stats[idx] = dict(area_texels=area,
                          area_km2=area * texel_m * texel_m / 1e6,
                          dominant_texels=int(dominant.sum()),
                          pages=len(per_layer[idx]))
        del w, wf, contrib, dominant
    # dominance is provisional above (a lower layer later can NOT steal a texel
    # because we iterate descending with strict >) -- recount exactly:
    dcount = np.bincount(dom.ravel(), minlength=256)
    for idx in stats:
        stats[idx]["dominant_texels"] = int(dcount[idx]) if idx < 255 else 0
    leftover = float(remaining.sum())
    covered = full * full - leftover               # texels the splat accounts for
    any_touch = float((dom_w > 0).sum())

    os.makedirs(PC.CACHE, exist_ok=True)
    np.save(os.path.join(PC.CACHE, level + "_dom.npy"), dom)
    meta = dict(depth=depth, full=full, world_x0=x0, world_z0=z0,
                world_size=world, texel_m=texel_m,
                page_size=sm.page_size, leftover_texels=leftover,
                any_touch_texels=any_touch)
    PC.merge_level(level, dict(coverage={str(k): v for k, v in stats.items()},
                               coverage_meta=meta))

    rows = {r["idx"]: r for r in doc["rows"]}
    print("=" * 100)
    print("%s  canvas %dx%d (%.2f m/texel)  page codec %d  splat-covered %.1f%% "
          "of world square" % (level, full, full, texel_m, sm.page_size,
                               100.0 * covered / (full * full)))
    order = sorted(stats, key=lambda i: -stats[i]["area_texels"])
    cv_slices = 0
    for idx in order:
        s = stats[idx]
        r = rows.get(idx, {})
        slot, cv = PC.albedo_of(r) if r else (None, None)
        if slot:
            cv_slices += 1
        pct = 100.0 * s["area_texels"] / covered if covered else 0.0
        if pct < 0.005 and not slot:
            continue
        print("  L%02d  %6.2f%%  %8.3f km2  dom %8d  pages %5d  %s"
              % (idx, pct, s["area_km2"], s["dominant_texels"], s["pages"],
                 os.path.basename(cv) if cv else "(no _cv)"))
    print("  -> %d colour-bearing (cv) layers with splat presence; %.1f%% of "
          "covered ground lands on a cv layer"
          % (cv_slices, 100.0 * sum(stats[i]["area_texels"] for i in stats
                                    if PC.albedo_of(rows.get(i, {"textures": {}}))[0])
             / covered if covered else 0.0))
    return cv_slices


def main():
    depth = 5
    if "--depth" in sys.argv:
        depth = int(sys.argv[sys.argv.index("--depth") + 1])
    levels = PC.roster(sys.argv)
    budget = []
    for lv in levels:
        try:
            budget.append((lv, one(lv, depth)))
        except (SystemExit, Exception) as e:      # noqa: BLE001 -- keep sweeping
            print("%s: FAILED %s" % (lv, e))
    print()
    print("=== slice budget (colour-bearing layers with splat presence) ===")
    for lv, n in sorted(budget, key=lambda t: -t[1]):
        print("   %-28s %3d %s" % (lv, n, "<-- EXCEEDS 32" if n > 32 else ""))


if __name__ == "__main__":
    main()
