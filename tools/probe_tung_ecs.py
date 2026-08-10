"""Every `*_ecsprefab_ecsprefab.ebx` in a level, and what is actually inside it.

The river on MP_Tungsten is an `EcsRuntimePrefabAsset`, which reads as a special
case until you count how many of them the level has. This prints one line per
prefab: entity count, archetype count, component segments, whether any segment
carries edits, and the SourceAsset partition it points at -- so "the river is a
runtime prefab" can be checked against "every empty layer is a runtime prefab".

Usage:  probe_tung_ecs.py [level] [--name <substr>]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    want = None
    if "--name" in sys.argv:
        want = sys.argv[sys.argv.index("--name") + 1].lower()
    root = os.path.join(C.LEVELS, level)
    shapes = collections.Counter()
    rows = []
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith("_ecsprefab.ebx"):
                continue
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            if want and want not in rel.lower():
                continue
            D, f = C.open_ebx(p)
            ent = arch = seg = 0
            edits = 0
            src = None
            comps = []
            for i, gs, tn in C.instances(D):
                if tn != "EcsRuntimePrefabAsset":
                    continue
                rec = C.named(D.read_instance(i))
                ent = len(rec.get("EntityTable") or [])
                arch = len(rec.get("ArchetypeTable") or [])
                seg = len(rec.get("Segments") or [])
                sa = rec.get("SourceAsset") or {}
                src = (sa.get("Partition") or [None, None])[1]
                for a in (rec.get("ArchetypeTable") or []):
                    comps += a.get("ExplicitComponents") or []
            for i, gs, tn in C.instances(D):
                if tn != "EcsComponentSegment":
                    continue
                rec = C.named(D.read_instance(i))
                edits += len(rec.get("StaticEdits") or []) + len(rec.get("DynamicEdits") or [])
            shape = (ent, arch, seg, edits, tuple(sorted(set(comps))))
            shapes[shape] += 1
            rows.append((rel, ent, arch, seg, edits, comps, src, os.path.getsize(p)))
    rows.sort()
    for rel, ent, arch, seg, edits, comps, src, sz in rows:
        print("%-72s %5dB ent=%d arch=%d seg=%d edits=%d comps=%s src=%s"
              % (rel, sz, ent, arch, seg, edits, comps, src))
    print("=" * 78)
    print("%d ECS runtime prefabs in %s" % (len(rows), level))
    for shape, c in shapes.most_common():
        print("   x%-4d ent=%d arch=%d seg=%d edits=%d comps=%s"
              % (c, shape[0], shape[1], shape[2], shape[3], list(shape[4])))


if __name__ == "__main__":
    main()
