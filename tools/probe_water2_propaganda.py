"""mp_propaganda census: does it exist as a level, and does it ship water?

RESEARCH-WATER2.md 5. READ-ONLY.  Usage:  probe_water2_propaganda.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402


def main():
    base = os.path.dirname(os.path.dirname(C.LEVELS.rstrip("\\/")))
    # every directory named *propaganda* in the whole bundles dump (walk
    # pruned at depth 6; level dirs sit at depth 4)
    bundles = C.BUNDLES
    hits = []
    for dp, dn, fn in os.walk(bundles):
        for d in list(dn):
            if "propaganda" in d.lower():
                hits.append(os.path.join(dp, d))
        if dp[len(bundles):].count(os.sep) > 5:
            dn[:] = []
    for h in hits:
        print("dir:", h)
        n_ebx = 0
        names = []
        for dp, _dn, fns in os.walk(h):
            for f in fns:
                n_ebx += 1
                names.append(os.path.join(dp, f).replace(h, ""))
        for n in names:
            print("   ", n)
        has_level = any("level" in n.lower() and n.endswith(".ebx")
                        for n in names)
        has_terrain = any("terrain" in n.lower() or "streamingtree" in n.lower()
                          for n in names)
        has_water = any(s in n.lower() for n in names
                        for s in ("water", "lake", "river", "ocean"))
        print("    -> level.ebx: %s   terrain: %s   water-named: %s"
              % (has_level, has_terrain, has_water))
    if not hits:
        print("no propaganda directory anywhere in the dump")


if __name__ == "__main__":
    main()
