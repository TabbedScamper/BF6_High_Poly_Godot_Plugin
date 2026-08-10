"""Deep-decode MP_Aftermath's ONE populated EcsRuntimePrefabAsset.

mp_aftermath ships 50 `*_ecsprefab_ecsprefab.ebx` partitions; 49 are the
universal empty stub (ent=1 arch=1 seg=1 edits=0 comps=[26]) and exactly one is
populated: `lay_backdropbuildingsescsplines_ecsprefab_ecsprefab.ebx`. This
probe prints everything the populated one carries, so a REAL runtime prefab can
be told from a stub by structure, not by size.

Usage:  probe_aftermath_ecs.py [level] [--prefab <filename>]
        (level defaults to mp_aftermath; also accepts the portal variant via
         --portal, which reads game/glacierportal/levels/mp_aftermath_portal)
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402


def main():
    if "--portal" in sys.argv:
        root = os.path.join(C.BUNDLES, "game", "glacierportal", "levels",
                            "mp_aftermath_portal")
    else:
        level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
            else "mp_aftermath"
        root = os.path.join(C.LEVELS, level)
    name = sys.argv[sys.argv.index("--prefab") + 1] if "--prefab" in sys.argv \
        else "lay_backdropbuildingsescsplines_ecsprefab_ecsprefab.ebx"

    path = None
    for dirpath, _d, files in os.walk(root):
        if name in files:
            path = os.path.join(dirpath, name)
            break
    if path is None:
        print("prefab %s not found under %s" % (name, root))
        return
    D, f = C.open_ebx(path)
    print(path.replace(C.BUNDLES, "<bundles>"), os.path.getsize(path), "bytes")
    cnt = collections.Counter(tn for _i, _g, tn in C.instances(D))
    print("instances:", cnt.most_common())

    ent_names = collections.Counter()
    for i, gs, tn in C.instances(D):
        if tn == "EcsRuntimePrefabAsset":
            rec = C.named(D.read_instance(i))
            sa = rec.get("SourceAsset") or {}
            print("EcsRuntimePrefabAsset: entities=%d archetypes=%d segments=%d"
                  % (len(rec.get("EntityTable") or []),
                     len(rec.get("ArchetypeTable") or []),
                     len(rec.get("Segments") or [])))
            for ai, a in enumerate(rec.get("ArchetypeTable") or []):
                comps = [v for k, v in a.items() if isinstance(v, list)]
                print("   archetype %d ExplicitComponents %s" % (ai, comps))
            print("   SourceAsset.Partition =", (sa.get("Partition") or [None, None])[1],
                  "(authoring-side; NOT shipped in the dump)")
        elif tn == "EcsComponentSegment":
            rec = C.named(D.read_instance(i))
            ct = rec["ComponentType"]["TypeRef"]["TypeInfo"]
            se, de = rec["StaticEdits"], rec["DynamicEdits"]
            print("segment @%d  ComponentType TypeInfoRef %s  static %d  dynamic %d"
                  % (i, ct, len(se), len(de)))
            for e in (de or se)[:1]:
                print("   first edit:", json.dumps(e, default=str)[:300])
        elif tn.startswith("be62bf1f"):
            rec = C.named(D.read_instance(i))
            ent_names[rec.get("Name")] += 1
    print("payload entity-record names:", ent_names.most_common())


if __name__ == "__main__":
    main()
