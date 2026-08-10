"""MP_Contaminated's placed FX: what is placed, where it lives, and what the
referenced effect blueprints contain (graph shapes).

Layer inventory (probe_tung_structure): fx_global.ebx has 307 objects,
fx_gasmodedisabled.ebx 200, plus per-area vfx layers.  Each placed FX is an
EffectReferenceObjectData with a Blueprint import; this probe groups the
placements by blueprint (resolved through the cached full-dump GUID index),
then opens the most-used blueprints and histograms their instance types.

READ-ONLY.  Usage:  probe_contaminated_fx.py [level]
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_guidscan as G        # noqa: E402
import ebx as ebxmod                   # noqa: E402

FX_LAYERS = ["_layers_content/fx_global.ebx",
             "_layers_content/fx_gasmodedisabled.ebx",
             "_layers_world/area_01_vfx.ebx",
             "_layers_world/area_08_vfx.ebx",
             "_layers_world/area_09_vfx.ebx"]


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"
    root = os.path.join(C.LEVELS, level)
    cp = os.path.join(G.CACHE, "..json")
    idx = {}
    if os.path.isfile(cp):
        with open(cp, encoding="utf-8") as fh:
            idx = json.load(fh)
    print("guid index: %d partitions" % len(idx))

    placements = collections.Counter()      # blueprint guid -> count
    media = []
    for rel in FX_LAYERS:
        p = os.path.join(root, rel.replace("/", os.sep))
        if not os.path.isfile(p):
            print("MISSING", rel)
            continue
        D, f = C.open_ebx(p)
        n_eff = 0
        for i in range(len(f.instance_offsets)):
            g = D.inst_type[i]
            if g is None:
                continue
            tn = C.tname(ebxmod._guid_str(g))
            if tn == "EffectReferenceObjectData":
                rec = C.named(D.read_instance(i))
                bp = rec.get("Blueprint")
                if isinstance(bp, dict) and "import" in bp:
                    placements[bp["import"]] += 1
                n_eff += 1
            elif tn == "ParticipatingMediaVolumeEntityData":
                rec = C.named(D.read_instance(i))
                media.append((rel, rec))
        print("%-42s EffectReferenceObjectData x%d" % (rel, n_eff))

    print("\n== placements by blueprint (%d distinct) ==" % len(placements))
    top = placements.most_common()
    for gid, cnt in top:
        name = idx.get(gid.lower(), "<unresolved>")
        print("   x%-4d %s" % (cnt, name))

    print("\n== ParticipatingMediaVolumeEntityData (%d) ==" % len(media))
    for rel, rec in media[:12]:
        keys = [k for k in rec.keys() if k not in ("__type",)]
        tr = rec.get("Transform") or rec.get("BlueprintTransform")
        print("   %s: fields %s" % (rel, sorted(keys)[:14]))

    # ---- open the most-used blueprints and histogram their contents --------
    print("\n== blueprint graph shapes (top 12 by placement count) ==")
    for gid, cnt in top[:12]:
        rel = idx.get(gid.lower())
        if not rel:
            print("   x%-4d %s <unresolved>" % (cnt, gid))
            continue
        p = os.path.join(C.BUNDLES, rel.replace("/", os.sep))
        try:
            D, f = C.open_ebx(p)
        except Exception as e:
            print("   x%-4d %s  OPEN FAILED %s" % (cnt, rel, e))
            continue
        th = collections.Counter()
        for i in range(len(f.instance_offsets)):
            g = D.inst_type[i]
            th[C.tname(ebxmod._guid_str(g)) if g else "?"] += 1
        print("   x%-4d %s" % (cnt, rel.split("/")[-1]))
        print("          %s" % dict(th.most_common()))


if __name__ == "__main__":
    main()
