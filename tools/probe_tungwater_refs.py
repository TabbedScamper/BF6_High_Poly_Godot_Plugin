"""Suspect 1 of the tungsten-water hunt: THE PARENT TRANSFORM.

The study read the water entity's LOCAL transform (ty = 0) out of
`_layers_content/water.ebx` and stopped. If any partition that *references*
that partition (layer include, subworld instance, prefab placement) carries a
translation, the world-space water is local + parent, and ty=0 local can land
in the river band.

This probe:
  1. builds a reverse-import map over EVERY partition under the level
     (imports are (partition_guid, instance_guid) pairs in each EFIX);
  2. climbs from the water partition to every root that reaches it, printing
     the chain;
  3. deserializes each direct importer and prints every instance that holds a
     PointerRef into the water partition, together with THAT instance's own
     Transform (the candidate parent transform).

READ-ONLY.  Usage:  probe_tungwater_refs.py [level] [target-rel-or-guid]
Default level mp_tungsten, default target _layers_content/water.ebx.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402


def efix_index(root):
    """rel -> EFIX for every .ebx under root (headers only, no payload)."""
    out = {}
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                f = ebxmod.parse(p)
            except Exception:
                continue
            out[os.path.relpath(p, root).replace(os.sep, "/")] = (p, f)
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_tungsten"
    target_rel = sys.argv[2] if len(sys.argv) > 2 else "_layers_content/water.ebx"
    root = os.path.join(C.LEVELS, level)

    idx = efix_index(root)
    print("%d partitions under %s" % (len(idx), level))

    tpath = os.path.join(root, target_rel.replace("/", os.sep))
    tf = ebxmod.parse(tpath)
    tguid = tf.partition_guid_str
    print("target %s  partition %s" % (target_rel, tguid))

    # reverse import map: partition guid -> [rel of importer]
    guid_of = {rel: f.partition_guid_str for rel, (p, f) in idx.items()}
    rev = {}
    for rel, (p, f) in idx.items():
        for pg, ig, pgs, igs in f.imports:
            rev.setdefault(pgs, []).append(rel)

    # 1) who imports the target, transitively up
    print("\n--- reverse chain (who reaches the water partition) ---")
    seen = set()
    frontier = [(tguid, [])]
    any_importer = False
    while frontier:
        g, chain = frontier.pop()
        for rel in sorted(set(rev.get(g, []))):
            any_importer = True
            line = " <- ".join([target_rel] + chain + [rel])
            print("  " + line)
            g2 = guid_of[rel]
            if g2 not in seen:
                seen.add(g2)
                frontier.append((g2, chain + [rel]))
    if not any_importer:
        print("  NO partition under the level imports the water partition.")

    # 2) direct importers: which instance holds the pointer, with what transform
    print("\n--- direct referencing instances and their transforms ---")
    for rel in sorted(set(rev.get(tguid, []))):
        p, f = idx[rel]
        D, _ = C.open_ebx(p)
        print("%s:" % rel)
        for i, gs, tn in C.instances(D):
            try:
                rec = D.read_instance(i)
            except Exception:
                continue
            if not isinstance(rec, dict):
                continue
            txt = json.dumps(rec, default=str)
            if tguid in txt:
                nrec = C.named(rec)
                t = nrec.get("Transform")
                print("  [%d] %s" % (i, tn))
                if isinstance(t, dict):
                    for k, v in t.items():
                        if isinstance(v, dict) and "X" in v:
                            print("      %-14s (%.3f, %.3f, %.3f)"
                                  % (k, v["X"], v["Y"], v["Z"]))
                else:
                    print("      (no Transform field)")

    # 3) sanity: does ANY partition in the whole level carry an import whose
    # instance guid equals one of the water partition's exported instances?
    # (an entity-level import would not show as a partition import mismatch,
    # but list it anyway)
    print("\n--- level root / description importers of the water LAYER NAME ---")
    for rel, (p, f) in sorted(idx.items()):
        if os.path.basename(rel) in ("mp_%s.ebx" % level.replace("mp_", ""),
                                     level + ".ebx", "description.ebx"):
            print("%s: %d imports" % (rel, len(f.imports)))
            for pg, ig, pgs, igs in f.imports:
                leaves = C.af_leaf(pgs)
                if any("water" in l.lower() for l in leaves) or pgs == tguid:
                    print("   -> %s  %s" % (pgs, leaves))


if __name__ == "__main__":
    main()
