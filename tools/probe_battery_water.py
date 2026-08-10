"""MP_Battery's water, end to end. Battery is one of the two levels
(with mp_capstone) that TERRAIN.md 14.11 leaves open: NO WaterSurfaceEntityData
anywhere in the level. This probe measures what battery has instead:

  1. a type scan proving no Water* typed instance exists in the level tree;
  2. the empty `_layers_content/water.ebx` LayerData (Objects = []);
  3. the WaterSurfaceEntityData exe layout law (size 0x280, +0x90
     QueryBoxHalfExtent, +0xB0 TileOffset) -- verifiable even with no instance;
  4. THE SEA: a StaticModelGroupMemberData in `_layers_world/world.ebx` placing
     `common/environment/europe/southerneurope/backdrop/ocean/bd_seu_oceanplane_01`
     -- its transform (translation Y = the sea level) and the mesh's declared
     box (flat at local y = 0);
  5. sea level vs the terrain floor from block 0.

Usage:  probe_battery_water.py [level]      (default mp_battery)
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import ebx as ebxmod                 # noqa: E402

OCEAN_PREFAB = "ea6fe8de-6554-4140-94ee-f0071d1d1aed"   # bd_seu_oceanplane_01.ebx
OCEAN_MESH = "e4047073-0701-4f88-fd4b-5ecc0fd2969b"     # bd_seu_oceanplane_01_mesh.ebx
OCEAN_MS = (r"A:\bf6pull\dump\bundles\common\environment\europe\southerneurope"
            r"\backdrop\ocean\bd_seu_oceanplane_01_mesh.MeshSet")


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_battery"
    root = os.path.join(C.LEVELS, level)

    # 1. no Water* type anywhere ------------------------------------------------
    pat = re.compile(r"water|ocean", re.I)
    n_part = 0
    hits = []
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                f = ebxmod.parse(p)
            except Exception:
                continue
            n_part += 1
            names = {C.tname(ebxmod._guid_str(g)) for g in f.type_guids}
            hit = sorted(t for t in names if pat.search(t) and "Database" not in t)
            if hit:
                hits.append((os.path.relpath(p, root), hit))
    print("scanned %d partitions; water/ocean-typed:" % n_part)
    for rel, hit in hits:
        print("   %-60s %s" % (rel, ", ".join(hit)))
    if not hits:
        print("   (none)")

    # 2. the empty water layer --------------------------------------------------
    p = os.path.join(root, "_layers_content", "water.ebx")
    if os.path.isfile(p):
        D, f = C.open_ebx(p)
        for i, gs, tn in C.instances(D):
            if tn == "LayerData":
                rec = C.named(D.read_instance(i))
                print("water.ebx LayerData Objects = %d" % len(rec.get("Objects") or []))

    # 3. the exe layout law -----------------------------------------------------
    import typesdk
    g = "ae0b69fc-2207-d874-8230-fcd467a592cf"
    h = g.replace("-", "")
    raw = (struct.pack("<IHH", int(h[0:8], 16), int(h[8:12], 16), int(h[12:16], 16))
           + bytes.fromhex(h[16:]))
    lay = typesdk.get_type_layout_full(C.pe(), raw)
    want = {"Transform": 0x20, "QueryBoxHalfExtent": 0x90, "TileOffset": 0xB0}
    print("WaterSurfaceEntityData size 0x%X (law: 0x280)" % lay["size"])
    for fl in lay["fields"]:
        n = C.fname(fl["nameHash"])
        if n in want:
            ok = "OK" if fl["offset"] == want[n] else "MISMATCH"
            print("   +0x%03X %-20s %s" % (fl["offset"], n, ok))

    # 4. the ocean plane placement ---------------------------------------------
    wp = os.path.join(root, "_layers_world", "world.ebx")
    D, f = C.open_ebx(wp)
    for idx, gs, tn in C.instances(D):
        if tn != "StaticModelGroupEntityData":
            continue
        rec = C.named(D.read_instance(idx))
        mems = rec["MemberDatas"]
        print("world.ebx StaticModelGroup: %d members" % len(mems))
        for m in mems:
            mt = m.get("MemberType") or {}
            if mt.get("import") != OCEAN_PREFAB:
                continue
            tr = m["InstanceTransforms"][0]
            rows = [v for k, v in tr.items() if isinstance(v, dict) and "X" in v]
            print("ocean member: MeshAsset import %s" % (m.get("MeshAsset") or {}).get("import"))
            for k, v in tr.items():
                if isinstance(v, dict) and "X" in v:
                    print("   %-12s (%10.3f, %10.3f, %10.3f)" % (k, v["X"], v["Y"], v["Z"]))
            trans = rows[-1]
            sea_y = trans["Y"]
            print("   -> SEA LEVEL y = %.3f (mesh is flat at local y=0, see below)" % sea_y)

    # the mesh's own box
    if os.path.isfile(OCEAN_MS):
        sys.path.insert(0, C.PIPELINE)
        import meshset_read as M
        print("oceanplane mesh declared box:", M.declared_box(OCEAN_MS))

    # 5. terrain floor ----------------------------------------------------------
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    _h, blocks, _a = T.container(d)
    for t, off, size in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            ns, _k, _s, _z = T.hf_walk(d, off, size, h)
            r = ns[0]
            print("terrain root AABB Y %.3f .. %.3f  (WorldSizeY %.1f)"
                  % (r[2][1], r[3][1], h["WorldSizeY"]))
            break


if __name__ == "__main__":
    main()
