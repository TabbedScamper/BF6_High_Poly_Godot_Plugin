"""MP_Portal_Sand: every EBX partition in the level -- types, layers, water,
ECS prefabs, decals -- i.e. the census that says what the MINIMUM viable level
actually ships.

Usage:  probe_portalsand_structure.py [--find <regex>] [--dump <relpath>]
"""
import collections
import fnmatch
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_portalsand_common as PC     # noqa: E402


def all_ebx():
    out = []
    for dp, _dns, fns in os.walk(PC.SAND):
        for f in fns:
            if f.endswith(".ebx"):
                out.append(os.path.join(dp, f))
    return sorted(out)


def main():
    find = None
    if "--find" in sys.argv:
        find = re.compile(sys.argv[sys.argv.index("--find") + 1], re.I)
    dump = sys.argv[sys.argv.index("--dump") + 1] if "--dump" in sys.argv else None

    files = all_ebx()
    print("%d EBX partitions under %s" % (len(files), PC.SAND))
    print("ECS runtime prefabs (*ecsprefab*): %d"
          % sum(1 for f in files if "ecsprefab" in os.path.basename(f).lower()))

    types = collections.Counter()
    type_where = collections.defaultdict(set)
    layers = []
    fails = []
    for p in files:
        rel = os.path.relpath(p, PC.SAND)
        try:
            D, f = PC.open_ebx(p)
        except Exception as e:
            fails.append((rel, str(e)[:60]))
            continue
        tset = set()
        for i, gs, tn in PC.instances(D):
            types[tn] += 1
            tset.add(tn)
            type_where[tn].add(rel)
        if "LayerData" in tset:
            for i, gs, tn in PC.instances(D):
                if tn != "LayerData":
                    continue
                try:
                    rec = PC.named(D.read_instance(i))
                except Exception:
                    continue
                layers.append((rel, rec.get("Name", "?"),
                               len(rec.get("Objects") or [])))
        if find:
            hit = sorted(t for t in tset if find.search(t))
            if hit:
                print("   %-60s %s" % (rel, ", ".join(hit)))
        if dump and rel.replace("\\", "/") == dump.replace("\\", "/"):
            for i, gs, tn in PC.instances(D):
                try:
                    print("   [%d] %s %s" % (i, tn, PC.named(D.read_instance(i))))
                except Exception as e:
                    print("   [%d] %s <decode failed: %s>" % (i, tn, e))

    print("\n%d partitions failed to open:" % len(fails))
    for rel, e in fails[:10]:
        print("   %s  %s" % (rel, e))

    print("\nLayerData partitions: %d   (with zero Objects: %d)"
          % (len(layers), sum(1 for _r, _n, c in layers if c == 0)))
    for rel, name, c in sorted(layers, key=lambda x: -x[2]):
        print("   %4d objects  %s" % (c, name.split("/")[-1]))

    print("\ntype census (top 40):")
    for tn, c in types.most_common(40):
        print("   x%-5d %s" % (c, tn))

    print("\nwater/ocean/river/backdrop/reflection/light types anywhere:")
    pat = re.compile(r"water|ocean|river|backdrop|reflect|light|cloud|scatter", re.I)
    for tn in sorted(types):
        if pat.search(tn):
            print("   x%-4d %-50s in %s" % (types[tn], tn,
                  sorted(type_where[tn])[:3]))


if __name__ == "__main__":
    main()
