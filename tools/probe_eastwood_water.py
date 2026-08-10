"""What represents water on MP_Eastwood.

The level's single WaterSurfaceEntityData is authored at y = 3.08, which is
171.7 m BELOW the terrain floor of 174.82 (MAP-TUNGSTEN.md A3) -- so the ocean
plane is buried and can render nothing. This probe establishes what ELSE the
map ships that is water: LakeData spline polygons, the terrain puddle layer,
and the empty WaterAsset, with numbers for each.

  1. every partition in the level containing LakeData, and for every LakeData
     instance: its water level Y, point count, XZ bounding box, area estimate;
  2. the WaterSurfaceEntityData transform read BY FIELD NAME (Transform rows,
     QueryBoxHalfExtent, TileOffset) -- note eastwood's basis is ROTATED, not
     axis-aligned;
  3. water.mesh.ebx's WaterAsset (empty or not);
  4. the terrain floor from block 0, and each lake's clearance above it.

READ-ONLY.  Usage:  probe_eastwood_water.py [level]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402

# field hashes inside the LakeData spline-point struct (bac217bd-...):
# printed as decimal keys by the deserialiser; X/Y/Z identified by value ranges
# (Y is constant per lake, X/Z span the polygon).
PT_X = 956422932
PT_Y = 1123815262
PT_Z = 849976220


def terrain_floor(level):
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    for t, off, size_b in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            nodes, _k, _s, _z = T.hf_walk(d, off, size_b, h)
            return nodes[0][2][1], nodes[0][3][1]
    return None, None


def poly_area(pts):
    """Shoelace over XZ."""
    a = 0.0
    for i in range(len(pts)):
        x0, z0 = pts[i]
        x1, z1 = pts[(i + 1) % len(pts)]
        a += x0 * z1 - x1 * z0
    return abs(a) / 2.0


def lakes_in(path):
    out = []
    try:
        D, f = C.open_ebx(path)
    except Exception as e:
        return out
    for i, gs, tn in C.instances(D):
        if tn != "LakeData":
            continue
        rec = D.read_instance(i)          # RAW: keys are field-hash ints
        pts = []
        ys = set()
        for v in rec.values():
            if isinstance(v, list) and v and isinstance(v[0], dict) \
                    and PT_X in v[0]:
                for p in v:
                    pts.append((p[PT_X], p[PT_Z]))
                    ys.add(round(p[PT_Y], 3))
                break
        nrec = C.named(rec)
        out.append(dict(idx=i, n=len(pts), ys=sorted(ys), pts=pts,
                        closed=nrec.get("IsClosed"),
                        draworder=nrec.get("DrawOrderIndex"),
                        split=nrec.get("SplitToMatchHeightfield")))
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_eastwood"
    root = os.path.join(C.LEVELS, level)
    floor, ceil = terrain_floor(level)
    print("%s terrain Y: floor %.3f  ceil %.3f" % (level, floor, ceil))

    # --- 1. every LakeData in the level --------------------------------------
    # partitions found by probe_tung_types.py <level> --find lake; hardcoding
    # the scan here keeps this probe standalone.
    hits = []
    for dirpath, _dn, fns in os.walk(root):
        for fn in fns:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                with open(p, "rb") as fh:
                    blob = fh.read()
            except OSError:
                continue
            # cheap pre-filter: LakeData type guid b722bdf7-718e-5eb5-...
            if bytes.fromhex("f7bd22b78e71b55e") not in blob:
                continue
            ls = lakes_in(p)
            if ls:
                hits.append((p, ls))

    total = 0
    print("\nLakeData polygons (water level Y is the per-lake constant):")
    for p, ls in hits:
        rel = p.replace(C.BUNDLES, "<bundles>")
        print("  %s  (%d lakes)" % (rel, len(ls)))
        for lk in ls:
            xs = [x for x, _z in lk["pts"]]
            zs = [z for _x, z in lk["pts"]]
            area = poly_area(lk["pts"])
            y = lk["ys"][0] if len(lk["ys"]) == 1 else lk["ys"]
            clr = (lk["ys"][0] - floor) if lk["ys"] else float("nan")
            print("     [%2d] y=%-9s  %2d pts  area %8.0f m2  x %7.1f..%7.1f  "
                  "z %7.1f..%7.1f  (%.1f m above terrain floor)"
                  % (lk["idx"], y, lk["n"], area, min(xs), max(xs),
                     min(zs), max(zs), clr))
            total += 1
    print("  TOTAL LakeData instances: %d in %d partitions" % (total, len(hits)))

    # --- 2. the buried ocean surface, read by field name ---------------------
    p = os.path.join(root, "_layers_content", "water.ebx")
    if os.path.isfile(p):
        D, f = C.open_ebx(p)
        for i, gs, tn in C.instances(D):
            if tn != "WaterSurfaceEntityData":
                continue
            rec = C.named(D.read_instance(i))
            t = rec["Transform"]
            print("\nWaterSurfaceEntityData [%d] Transform rows:" % i)
            for k, v in t.items():
                if k == "__type":
                    continue
                print("   %-14s (%10.4f, %10.4f, %10.4f)" % (k, v["X"], v["Y"], v["Z"]))
            for k in ("QueryBoxHalfExtent", "TileOffset"):
                v = rec[k]
                print("   %-14s (%10.4f, %10.4f, %10.4f)" % (k, v["X"], v["Y"], v["Z"]))
            mp = rec.get("MaterialPair")
            print("   MaterialPair.Packed %d = 0x%08X" % (mp["Packed"], mp["Packed"]))

    # --- 3. the WaterAsset ---------------------------------------------------
    td = T.terr_dir(level)
    wm = None
    for dirpath, _dn, fns in os.walk(td):
        for fn in fns:
            if fn == "water.mesh.ebx":
                wm = os.path.join(dirpath, fn)
    if wm:
        D, f = C.open_ebx(wm)
        print("\nwater.mesh.ebx: %d bytes, %d instance(s)" % (os.path.getsize(wm),
                                                              len(f.instance_offsets)))
        for i, gs, tn in C.instances(D):
            rec = C.named(D.read_instance(i))
            print("   [%d] %s: %s" % (i, tn,
                  {k: v for k, v in rec.items() if k != "__type"}))
    else:
        print("\nno water.mesh.ebx under the terrain dir")


if __name__ == "__main__":
    main()
