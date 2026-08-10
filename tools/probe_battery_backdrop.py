"""MP_Battery's backdrop/skyline inventory (open-task #36: which backdrop
meshes exist for the map).

Three backdrop tiers on battery:

  * `backdrop/buildings/` inside the level: `bd_seu_buildingsbattery_NN_mid`
    prefabs whose MeshSets SHIP INSIDE THE LEVEL DIRECTORY (rare -- most props
    live under common/);
  * `_layers_world/backdrop.ebx`: billboard buildings
    (`seu_bd_buildingsbillboard_01..08` from common/);
  * `_layers_world/backdrop_near.ebx`: real facade/roof prefabs, and the ONE
    populated EcsRuntimePrefabAsset of the level (47 entities);
  * `_layers_world/world.ebx`: the far vista StaticModelGroup (251 members)
    including the ocean plane and the Spanish-coast vista meshes.

Usage:  probe_battery_backdrop.py [level]
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_guidscan as G      # noqa: E402
import ebx as ebxmod                 # noqa: E402


def load_index():
    p = os.path.join(G.CACHE, "..json")
    if os.path.isfile(p):
        with open(p, encoding="utf-8") as fh:
            return json.load(fh)
    return {}


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_battery"
    root = os.path.join(C.LEVELS, level)
    gi = load_index()

    # 1. in-level backdrop meshes ---------------------------------------------
    bd = os.path.join(root, "backdrop")
    prefabs = []
    meshsets = []
    for dirpath, _d, files in os.walk(bd):
        for f in files:
            if f.endswith(".MeshSet"):
                meshsets.append(f)
            elif f.endswith(".ebx") and not f.endswith("_mesh.ebx"):
                prefabs.append(f)
    print("backdrop/ dir: %d prefab ebx, %d shipped MeshSets" %
          (len(prefabs), len(meshsets)))
    nums = sorted({p.split("_")[3] for p in prefabs if "buildingsbattery" in p})
    print("   bd_seu_buildingsbattery numbers: %s" % ",".join(nums))

    # 2 + 3. the backdrop layers ----------------------------------------------
    for rel in ("_layers_world/backdrop.ebx", "_layers_world/backdrop_near.ebx",
                "_layers_world/backdropbuildingsnear.ebx"):
        p = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            print(rel, "MISSING")
            continue
        D, f = C.open_ebx(p)
        nobj = None
        for i, gs, tn in C.instances(D):
            if tn == "LayerData":
                rec = C.named(D.read_instance(i))
                nobj = len(rec.get("Objects") or [])
                break
        leaves = sorted({os.path.basename(gi.get(pgs, pgs))
                         for _pg, _ig, pgs, _igs in f.imports})
        print("%s: %d bytes, %s Objects, %d import partitions"
              % (rel, os.path.getsize(p), nobj, len(f.imports)))
        for l in leaves[:12]:
            print("      %s" % l)

    # 4. the two StaticModelGroups that place the skyline ---------------------
    # THE PLACEMENT ODDITY: the 50 bd_seu_*battery_NN_mid tiles are placed by a
    # StaticModelGroup inside the LEVEL ROOT partition (mp_battery.ebx), not by
    # any layer. world.ebx carries the catch-all group (windows/doors/facade
    # parts + the ocean plane + building 44).
    for rel in ("mp_battery.ebx", "_layers_world/world.ebx"):
        p = os.path.join(root, rel.replace("/", os.sep))
        D, f = C.open_ebx(p)
        for idx, gs, tn in C.instances(D):
            if tn != "StaticModelGroupEntityData":
                continue
            rec = C.named(D.read_instance(idx))
            mems = rec["MemberDatas"]
            fam = collections.Counter()
            inst_total = 0
            for m in mems:
                mt = (m.get("MemberType") or {}).get("import")
                leaf = os.path.basename(gi.get(mt, mt or "?"))
                leaf = leaf.replace(".ebx", "")
                fam[leaf] += int(m.get("InstanceCount") or 1)
                inst_total += int(m.get("InstanceCount") or 1)
            print("%s StaticModelGroup: %d members, %d placed instances"
                  % (rel, len(mems), inst_total))
            for leaf, cnt in fam.most_common(20):
                print("   x%-4d %s" % (cnt, leaf))


if __name__ == "__main__":
    main()
