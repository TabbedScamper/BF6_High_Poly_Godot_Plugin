"""Validate the SingleTerrainLayerData.MeshScatteringTypes -> catalogue join
on MP_GolmudRailway (open item in the fleet brief).

Left side:  <terrain>.ebx SingleTerrainLayerData instances, each with
            MeshScatteringTypes entries carrying an `Identifier`.
Right side: the level's meshscatteringdatabaseasset.MeshScatteringDatabase
            (decoded by BF6_Frostbite_Research/impl/pipeline/msdb.py), whose
            entries carry typeHash / kitHash / groupHash / key.

The join is validated if every left Identifier appears in exactly one of the
right-side hash columns.

Usage: probe_golmud_scatterjoin.py [level]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import msdb                          # noqa: E402  (research pipeline module)


def walk(v, path, out):
    if isinstance(v, dict):
        for k, x in v.items():
            walk(x, path + [str(k)], out)
    elif isinstance(v, list):
        for i, x in enumerate(v):
            walk(x, path + [str(i)], out)
    else:
        out.append((".".join(path), v))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_golmudrailway"
    td = T.terr_dir(level)
    tebx = None
    for f in sorted(os.listdir(td)):
        if f.endswith(".ebx") and "layergraph" not in f and "streamingtree" not in f:
            tebx = os.path.join(td, f)
            break
    print("terrain ebx:", tebx)
    D, f = C.open_ebx(tebx)
    idents = []
    for i, gs, tn in C.instances(D):
        rec = D.read_instance(i)
        if not rec:
            continue
        named = C.named(rec)
        if "SingleTerrainLayerData" not in str(named.get("__type", "")) \
                and "MeshScatteringTypes" not in json.dumps(named, default=str):
            continue
        flat = []
        walk(named, [tn or "?", "[%d]" % i], flat)
        for pth, v in flat:
            if "scatter" in pth.lower() or "Identifier" in pth:
                idents.append((pth, v))
    print("%d scatter-ish fields in terrain ebx" % len(idents))
    for pth, v in idents[:60]:
        print("   %s = %s" % (pth, v))

    # catalogue side
    root = os.path.join(C.LEVELS, level)
    db = None
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if fn.endswith(".MeshScatteringDatabase"):
                db = os.path.join(dirpath, fn)
    print("msdb:", db)
    hdr, entries = msdb.parse(db)
    print("msdb: %d entries, budgets %s" % (len(entries), hdr[1:6]))
    cols = {"typeHash": set(), "kitHash": set(), "groupHash": set()}
    for e in entries:
        for c in cols:
            cols[c].add(e[c])
    left = {v for _p, v in idents if isinstance(v, int) and v > 0}
    print("left-side integer identifiers: %d distinct" % len(left))
    for c, s in cols.items():
        inter = left & s
        print("   %-10s matches %d of %d left identifiers (col has %d values)"
              % (c, len(inter), len(left), len(s)))


if __name__ == "__main__":
    main()
