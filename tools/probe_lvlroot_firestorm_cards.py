"""FireStorm's giant FX-card meshes: WHO places them and with WHAT transforms
(RESEARCH-LEVELROOT question 3).

MAP-FIRESTORM.md D2 measured the cards themselves (ObjectBlueprint ->
StaticModelEntityData, unit-square bounds scaled by the instance transform);
probe_lvlroot_survey then found the mp_firestorm.ebx ROOT SMG places 16
members categorised "fx" at y 257..1452. This probe pins each named card to
its placing partition + carrier type + full transform so the walk can be
asserted against:

  A. the root SMG @26: full member list with transforms (leaf-resolved);
  B. _layers_content/fx_oilfields.ebx and fx_backdrop.ebx: every
     ObjectReferenceObjectData whose blueprint leaf matches an ob_fx_bd_* /
     *smokecard* / *topblend* / *smoke_background* / *distantonly* pattern,
     with its BlueprintTransform (basis rows = the scale that stretches the
     unit card into a kilometre plume).

READ-ONLY on game data.
Usage: probe_lvlroot_firestorm_cards.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_lvlroot_survey as S     # noqa: E402

FIRE = os.path.join(C.LEVELS, "mp_firestorm")

CARD_PAT = ("ob_fx_bd_", "smokecard", "topblend", "smoke_background",
            "smokepillar_background", "smoke_distantonly", "smokeplume")


def is_card(leaf):
    return leaf is not None and any(p in leaf for p in CARD_PAT)


def fmt_lt(lt):
    if not isinstance(lt, dict):
        return repr(lt)
    def row(n, alts=()):
        v = lt.get(n)
        if not isinstance(v, dict):
            for a in alts:
                v = lt.get(a)
                if isinstance(v, dict):
                    break
        v = v or {}
        return (round(v.get("X", 0), 2), round(v.get("Y", 0), 2),
                round(v.get("Z", 0), 2))
    return "T=%s R=%s U=%s F=%s" % (
        row("Trans", ("0xBC4B07B4",)), row("Right", ("0xC478CC3B",)),
        row("Up", ("0xBF151EF9",)), row("Forward", ("0x695D12A4",)))


def part_a():
    print("=" * 78)
    print("A. mp_firestorm.ebx root SMG: FULL member list + transforms")
    D, f = C.open_ebx(os.path.join(FIRE, "mp_firestorm.ebx"))
    for i, gs, tn in C.instances(D):
        if tn != "StaticModelGroupEntityData":
            continue
        rec = C.named(D.read_instance(i))
        mems = rec.get("MemberDatas") or []
        print("  SMG @%d: %d members" % (i, len(mems)))
        for m in mems:
            mt = (m.get("MemberType") or {}).get("import")
            leaf = S.leaf_of(mt) or str(mt)
            for lt in (m.get("InstanceTransforms") or []):
                print("    %-52s %s" % (leaf, fmt_lt(lt)))


def scan_layer(rel):
    p = os.path.join(FIRE, rel.replace("/", os.sep))
    if not os.path.isfile(p):
        print("  MISSING", rel)
        return
    D, f = C.open_ebx(p)
    total = 0
    for i, gs, tn in C.instances(D):
        if not tn.endswith("ReferenceObjectData"):
            continue
        rec = C.named(D.read_instance(i))
        bp = (rec.get("Blueprint") or {}).get("import")
        leaf = S.leaf_of(bp)
        if not is_card(leaf):
            continue
        total += 1
        lt = rec.get("BlueprintTransform") or rec.get("Transform")
        print("  %s @%d %s" % (rel, i, tn))
        print("    blueprint %s" % leaf)
        print("    %s" % fmt_lt(lt))
        excl = rec.get("Excluded")
        idx = rec.get("IndexInBlueprint")
        print("    Excluded=%s IndexInBlueprint=%s" % (excl, idx))
    print("  -> %d card placements in %s" % (total, rel))


def part_b():
    print("=" * 78)
    print("B. FX-card ObjectReferenceObjectData in the content FX layers")
    for rel in ("_layers_content/fx_oilfields.ebx",
                "_layers_content/fx_backdrop.ebx",
                "_layers_content/fx_global.ebx",
                "_layers_content/fx_sketch.ebx"):
        scan_layer(rel)


def main():
    part_a()
    part_b()


if __name__ == "__main__":
    main()
