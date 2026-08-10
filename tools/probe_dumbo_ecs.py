"""MP_Dumbo's POPULATED EcsRuntimePrefabAssets, dumped next to the empty stub.

MP_Tungsten's study (MAP-TUNGSTEN.md A2) proved the ent=1/arch=1/edits=0/
comps=[26] prefab is boilerplate emitted per layer. Dumbo is one of the two
maps that also ship populated ones — this probe shows what "populated"
actually holds: named entities, archetype component-type indices, per-segment
edit property names, and whether the SourceAsset partition exists in the dump.

Usage:  probe_dumbo_ecs.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402


def dump_prefab(path, rel):
    D, f = C.open_ebx(path)
    names = collections.Counter()
    segs = []
    pf = None
    for i, gs, tn in C.instances(D):
        rec = C.named(D.read_instance(i))
        if tn == "EcsRuntimePrefabAsset":
            pf = rec
        elif tn == "EcsComponentSegment":
            edits = []
            for e in (rec.get("StaticEdits") or []) + (rec.get("DynamicEdits") or []):
                for k, v in e.items():
                    if isinstance(v, list):
                        for ed in v:
                            if isinstance(ed, dict):
                                for kk, vv in ed.items():
                                    if isinstance(vv, str):
                                        edits.append(vv)
            ct = rec.get("ComponentType") or {}
            ti = ((ct.get("TypeRef") or {}).get("TypeInfo") or [None, None])[1]
            n_stat = sum(1 for x in rec.get("StaticInstances") or [] if x != 0xFFFFFFFF)
            segs.append((ti, n_stat,
                         len(rec.get("StaticEdits") or []),
                         len(rec.get("DynamicEdits") or []),
                         sorted(set(edits))))
        elif isinstance(rec, dict) and "Name" in rec and "PartitionGuid" in rec:
            names[rec["Name"]] += 1
    print("=" * 78)
    print(rel)
    if pf:
        sa = pf.get("SourceAsset") or {}
        src = (sa.get("Partition") or [None, None])[1]
        leaves = C.af_leaf(src) if src else []
        print("  entities %d  variants %d  archetypes %s" % (
            len(pf.get("EntityTable") or []),
            len(pf.get("VariantTable") or []),
            [a.get(2053145166) or a.get("2053145166")
             for a in (pf.get("ArchetypeTable") or [])]))
        print("  SourceAsset partition %s -> %s"
              % (src, ", ".join(leaves) or "NOT IN DUMP"))
    print("  named entity records: %s" % dict(names))
    for ti, n_stat, ns, nd, edits in segs:
        print("  segment type te0x19[%s]  instances=%d  staticEdits=%d "
              "dynamicEdits=%d  edit props %s" % (ti, n_stat, ns, nd, edits))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_dumbo"
    root = os.path.join(C.LEVELS, level)
    for dirpath, _d, files in os.walk(root):
        for fn in sorted(files):
            if not fn.endswith("_ecsprefab.ebx"):
                continue
            p = os.path.join(dirpath, fn)
            if os.path.getsize(p) < 2000:      # the 1.1 KB empty stub
                continue
            dump_prefab(p, os.path.relpath(p, root).replace(os.sep, "/"))


if __name__ == "__main__":
    main()
