"""The scatter join: SingleTerrainLayerData.MeshScatteringTypes -> the
MeshScatteringDatabase catalogue.

The fleet brief flags the join key (per-layer `Identifier` <-> catalogue entry)
as UNVALIDATED. Badlands turns out to have EMPTY MeshScatteringTypes on all of
its SingleTerrainLayerData instances, so step 1 is a cross-map census: which
levels populate the EBX side at all? For any that do, dump the
TerrainMeshScatteringType records with field names from the retail exe layout
and attempt the join against that level's MSDB entries (typeHash / kitHash /
key / meshGuid candidates).

Usage:  probe_badlands_scatter.py [--census] [--join <level>]
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import msdb                          # noqa: E402


def terrain_ebx(level):
    """The TerrainData partition: <lvl>/<x>terrain<y>/<x>terrain<y>.ebx."""
    root = os.path.join(C.LEVELS, level)
    if not os.path.isdir(root):
        return None
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d)
        if os.path.isdir(p) and "terrain" in d.lower():
            cand = os.path.join(p, d + ".ebx")
            if os.path.isfile(cand):
                return cand
    return None


def msdb_path(level):
    root = os.path.join(C.LEVELS, level)
    for dp, _d, fs in os.walk(root):
        for fn in fs:
            if fn.startswith("meshscatteringdatabaseasset.") and \
                    not fn.endswith(".ebx"):
                return os.path.join(dp, fn)
    return None


def scan_level(level):
    """(#SingleTerrainLayerData, #with non-empty MeshScatteringTypes, entries)"""
    p = terrain_ebx(level)
    if p is None:
        return None
    D, f = C.open_ebx(p)
    n = 0
    populated = []
    for i, gs, tn in C.instances(D):
        if tn != "SingleTerrainLayerData":
            continue
        n += 1
        rec = C.named(D.read_instance(i))
        mst = rec.get("MeshScatteringTypes")
        if mst:
            populated.append((i, mst))
    return n, populated


def main():
    if "--join" in sys.argv:
        levels = [sys.argv[sys.argv.index("--join") + 1]]
    else:
        levels = sorted(d for d in os.listdir(C.LEVELS)
                        if os.path.isdir(os.path.join(C.LEVELS, d)))
    for lv in levels:
        try:
            r = scan_level(lv)
        except Exception as e:
            print("%-22s scan failed: %s" % (lv, e))
            continue
        if r is None:
            print("%-22s no terrain ebx" % lv)
            continue
        n, pop = r
        mp = msdb_path(lv)
        ents = None
        if mp:
            try:
                _h, ents = msdb.parse(mp)
            except Exception:
                pass
        print("%-22s SingleTerrainLayerData x%-3d populated x%-3d   msdb %s"
              % (lv, n, len(pop),
                 ("%d entries" % len(ents)) if ents is not None else "none"))
        for i, mst in pop:
            print("      inst %d  MeshScatteringTypes: %s" % (i, mst))


if __name__ == "__main__":
    main()
