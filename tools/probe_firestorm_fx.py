"""MP_FireStorm's FX layers — fire/smoke density and the big distant FX cards.

Walks the level's FX LayerData partitions (fx_global, fx_backdrop,
fx_oilfields, fx_sketch, plus gameplay_global), decodes every
EffectReferenceObjectData / SpatialPrefabReferenceObjectData instance, and
reports: per-blueprint instance counts, world-position spread, and Y range.
Blueprint import GUIDs are resolved through the cached full-dump guid index
(probe_tung_guidscan CACHE/..json).

Usage:  probe_firestorm_fx.py [level]
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402

LAYERS = [
    "_layers_content/fx_global.ebx",
    "_layers_content/fx_backdrop.ebx",
    "_layers_content/fx_oilfields.ebx",
    "_layers_content/fx_sketch.ebx",
    "_layers_gameplay/gameplay_global.ebx",
]
TRANS = 0xBC4B07B4              # LinearTransform translation field hash
REF_TYPES = ("EffectReferenceObjectData", "SpatialPrefabReferenceObjectData",
             "ObjectReferenceObjectData")


def find_trans(rec):
    """The Vec3 translation inside BlueprintTransform, by field hash."""
    if not isinstance(rec, dict):
        return None
    for k, v in rec.items():
        if k == TRANS and isinstance(v, dict):
            return (v.get(0x395A9EFB, v.get("X", 0.0)) if isinstance(v, dict)
                    else None)
    return None


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_firestorm"
    root = os.path.join(C.LEVELS, level)
    gi = {}
    try:
        import probe_tung_guidscan as G
        cp = os.path.join(G.CACHE, "..json")
        if os.path.isfile(cp):
            gi = json.load(open(cp, encoding="utf-8"))
    except Exception:
        pass

    for rel in LAYERS:
        p = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            print("MISSING", rel)
            continue
        D, f = C.open_ebx(p)
        by_bp = collections.Counter()
        pos = collections.defaultdict(list)
        n_ref = 0
        for i, gs, tn in C.instances(D):
            if tn not in REF_TYPES:
                continue
            rec = D.read_instance(i)
            if not rec:
                continue
            n_ref += 1
            bp = None
            tr = None
            for k, v in rec.items():
                nm = C.fname(k) if isinstance(k, int) else str(k)
                if nm == "Blueprint" and isinstance(v, dict):
                    bp = v.get("import")
                elif nm == "BlueprintTransform" and isinstance(v, dict):
                    t = v.get(TRANS)
                    if isinstance(t, dict):
                        xyz = [t.get(h) for h in t if h != "__type"]
                        vals = [t[h] for h in t if h != "__type"]
                        tr = tuple(vals[:3]) if len(vals) >= 3 else None
            name = gi.get(str(bp).lower()) if bp else None
            if name and name.endswith(".ebx"):
                name = name[:-4]
            key = name or str(bp)
            by_bp[key] += 1
            if tr:
                pos[key].append(tr)
        print("=" * 100)
        print("%s  (%d reference objects)" % (rel, n_ref))
        for k, c in by_bp.most_common():
            ps = pos.get(k, [])
            if ps:
                xs = [q[0] for q in ps]; ys = [q[1] for q in ps]; zs = [q[2] for q in ps]
                span = ("x %7.0f..%-7.0f y %6.1f..%-6.1f z %7.0f..%-7.0f"
                        % (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
            else:
                span = "(no transform read)"
            print("   x%-4d %-70s %s" % (c, k.split("/")[-1], span))
        # long names once, for the doc
        for k in by_bp:
            if "/" in k:
                print("      full: %s" % k)


if __name__ == "__main__":
    main()
