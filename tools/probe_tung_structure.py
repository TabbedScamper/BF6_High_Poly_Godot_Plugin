"""The shape of a level: layers, subworlds, depots, and where the content sits.

Prints
  * the LayerData tree (every partition that declares one, with its Objects count)
  * the biggest partitions by byte size -- content follows size closely
  * every ShaderBlockDepotResource under the level, with its record count, since
    a placement's depot scope is a graph ancestor and the set of candidate
    depots is the first thing to check when materials go missing
  * the level root's own instance types

Usage:  probe_tung_structure.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_tungsten"
    root = os.path.join(C.LEVELS, level)
    sizes = []
    depots = []
    layers = []
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            p = os.path.join(dirpath, fn)
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            sz = os.path.getsize(p)
            if fn.endswith(".ShaderBlockDepotResource"):
                depots.append((rel, sz))
                continue
            if not fn.endswith(".ebx"):
                sizes.append((sz, rel, ""))
                continue
            sizes.append((sz, rel, "ebx"))
    sizes.sort(reverse=True)
    print("=== %s: 25 largest files" % level)
    for sz, rel, kind in sizes[:25]:
        print("   %10d  %s" % (sz, rel))
    print("=== ShaderBlockDepots under the level (%d)" % len(depots))
    for rel, sz in sorted(depots, key=lambda r: -r[1])[:20]:
        print("   %10d  %s" % (sz, rel))

    print("=== LayerData partitions (Objects count)")
    rows = []
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                f = ebxmod.parse(p)
            except Exception:
                continue
            names = [C.tname(ebxmod._guid_str(g)) for g in f.type_guids]
            if "LayerData" not in names:
                continue
            try:
                D, _f = C.open_ebx(p)
            except Exception:
                continue
            for i, gs, tn in C.instances(D):
                if tn != "LayerData":
                    continue
                rec = C.named(D.read_instance(i))
                rows.append((len(rec.get("Objects") or []),
                             os.path.relpath(p, root).replace(os.sep, "/"),
                             rec.get("Name", "")))
    rows.sort(reverse=True)
    empty = sum(1 for r in rows if r[0] == 0)
    print("   %d LayerData partitions, %d with ZERO Objects" % (len(rows), empty))
    for n, rel, nm in rows[:25]:
        print("   %6d  %s" % (n, rel))
    print("   --- empty layers ---")
    for n, rel, nm in rows:
        if n == 0:
            print("        0  %s" % rel)


if __name__ == "__main__":
    main()
