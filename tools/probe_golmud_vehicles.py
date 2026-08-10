"""Vehicle spawner assembly + livery evidence on MP_GolmudRailway (task #32).

For each gameplay-layer partition given (default the conquest/breakthrough/
rush layers), prints: instance-type histogram, every import resolved to its
asset leaf name through the _af store, and for spawner-shaped instances the
fields that matter (Transform, referenced blueprint, team, VehicleVariation).

Usage: probe_golmud_vehicles.py [level] [relpath ...]
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402

DEFAULT = [
    "_layers_gameplay/conquest/conquest0.ebx",
    "_layers_gameplay/conquest/conquest_global.ebx",
    "_layers_gameplay/breakthrough/breakthrough0.ebx",
    "_layers_gameplay/rush/rush0.ebx",
]

INTEREST = ("spawn", "vehicle", "variation", "livery")


def dump(root, rel):
    p = os.path.join(root, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        print("MISSING", rel)
        return
    print("=" * 78)
    print("%s  %d bytes" % (rel, os.path.getsize(p)))
    D, f = C.open_ebx(p)
    hist = collections.Counter()
    inst = C.instances(D)
    for i, gs, tn in inst:
        hist[tn] += 1
    for tn, c in hist.most_common():
        print("   x%-4d %s" % (c, tn))
    print("   imports (%d partitions):" % len({pg for pg, _i, _l in C.imports_of(f)}))
    seen = set()
    for pgs, igs, leaves in C.imports_of(f):
        if pgs in seen:
            continue
        seen.add(pgs)
        print("      %s" % (", ".join(leaves) or "<%s not in _af>" % pgs))
    for i, gs, tn in inst:
        if not any(k in tn.lower() for k in INTEREST):
            continue
        rec = D.read_instance(i)
        if not rec:
            continue
        print("   [%d] %s" % (i, tn))
        for k, v in C.named(rec).items():
            if k == "__type":
                continue
            s = json.dumps(v, default=str)
            if len(s) > 200:
                s = s[:200] + "..."
            print("        %-30s %s" % (k, s))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_golmudrailway"
    rels = sys.argv[2:] or DEFAULT
    root = os.path.join(C.LEVELS, level)
    for rel in rels:
        dump(root, rel)


if __name__ == "__main__":
    main()
