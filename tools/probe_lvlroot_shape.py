"""Record-shape diff: level-root / world.ebx StaticModelGroups vs the subworld
ones the walk already parses (RESEARCH-LEVELROOT question 2).

For each sampled SMG this prints, from the RAW (hash-keyed) decode:
  * the instance's raw type GUID (must equal bf6_walk.gd SMG_TYPE
    2e5723ed-effe-ff86-2c68-26573e1011a6 for the walk to even look at it --
    though the walk actually keys on the MemberDatas FIELD, not the type);
  * the top-level field-hash set and the member field-hash set;
  * which of 0xB608BEEE (MemberType) / 0x1B4A547C (MeshAsset) is populated
    and what each resolves to;
  * the InstanceTransforms element type and the LT member hashes;
  * whether InstanceEnabled / 0x8F8D9F78 (Visible) come back packed
    (ints of 0x01010101) or empty -- the flat_bools hazard.

Usage: probe_lvlroot_shape.py
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C            # noqa: E402
import probe_lvlroot_survey as S         # noqa: E402
import ebx as ebxmod                     # noqa: E402

WALK_SMG_TYPE = "2e5723ed-effe-ff86-2c68-26573e1011a6"
F = {
    "MEMBERS": 0xA43BD992, "XFORMS": 0xEBF4D386,
    "MEMBERTYPE": 0xB608BEEE, "MESHASSET": 0x1B4A547C,
    "ENABLED": 0xFB410D18, "VISIBLE": 0x8F8D9F78, "OBJVAR": 0xE2FFCC45,
    "LT_RIGHT": 0xC478CC3B, "LT_UP": 0xBF151EF9,
    "LT_FORWARD": 0x695D12A4, "LT_TRANS": 0xBC4B07B4,
}

SAMPLES = [
    # (label, path relative to LEVELS)
    ("ROOT   battery", "mp_battery/mp_battery.ebx"),
    ("ROOT   tungsten", "mp_tungsten/mp_tungsten.ebx"),
    ("ROOT   eastwood", "mp_eastwood/mp_eastwood.ebx"),
    ("WORLD  battery", "mp_battery/_layers_world/world.ebx"),
    ("WORLD  contaminated", "mp_contaminated/_layers_world/world.ebx"),
    ("LAYER  battery area_001 (walk-proven class)",
     "mp_battery/_layers_world/area_001.ebx"),
    ("GMODE  battery conquest_subworld",
     "mp_battery/_layers_world/conquest_subworld.ebx"),
]


def describe(label, path):
    p = os.path.join(C.LEVELS, path.replace("/", os.sep))
    if not os.path.isfile(p):
        print(label, "MISSING", path)
        return None
    D, f = C.open_ebx(p)
    found = 0
    sig = None
    for i, gs, tn in C.instances(D):
        if tn != "StaticModelGroupEntityData":
            continue
        found += 1
        if found > 1:
            continue
        raw = D.read_instance(i)
        top = sorted(k for k in raw if isinstance(k, int))
        mems = raw.get(F["MEMBERS"]) or []
        m0 = mems[0] if mems else {}
        mhash = sorted(k for k in m0 if isinstance(k, int))
        mt = m0.get(F["MEMBERTYPE"])
        ma = m0.get(F["MESHASSET"])

        def ref(v):
            if isinstance(v, dict) and "import" in v:
                g = v["import"]
                return "import:%s (%s)" % (g, S.leaf_of(g))
            return repr(v)[:60]

        xfs = m0.get(F["XFORMS"]) or []
        lt_keys = sorted(k for k in xfs[0] if isinstance(k, int)) if xfs else []
        en = m0.get(F["ENABLED"])
        vi = m0.get(F["VISIBLE"])

        def boolshape(v):
            if not isinstance(v, list):
                return repr(v)
            if not v:
                return "empty(list)"
            kinds = {type(x).__name__ for x in v}
            return "list[%d] of %s e.g. %r" % (len(v), kinds, v[0])

        print("-" * 70)
        print("%s  (%s)" % (label, path))
        print("  type guid      %s  %s" %
              (gs, "== walk SMG_TYPE" if gs == WALK_SMG_TYPE
               else "*** DIFFERS FROM WALK SMG_TYPE ***"))
        print("  members        %d" % len(mems))
        print("  top hashes     %s" % " ".join("%08X" % k for k in top))
        print("  member hashes  %s" % " ".join("%08X" % k for k in mhash))
        print("  MemberType     %s" % ref(mt))
        print("  MeshAsset      %s" % ref(ma))
        print("  xforms         %s, LT member hashes %s"
              % ("list[%d]" % len(xfs) if isinstance(xfs, list) else repr(xfs),
                 " ".join("%08X" % k for k in lt_keys)))
        print("  InstanceEnabled %s" % boolshape(en))
        print("  Visible(8F8D)   %s" % boolshape(vi))
        sig = (tuple(top), tuple(mhash))
    if found == 0:
        print(label, ": no SMG in", path)
    else:
        print("  (%d SMG instance(s) in partition)" % found)
    return sig


def main():
    sigs = {}
    for label, path in SAMPLES:
        sig = describe(label, path)
        if sig:
            sigs.setdefault(sig, []).append(label)
    print("=" * 70)
    print("distinct (top-hash-set, member-hash-set) signatures: %d" % len(sigs))
    for sig, labels in sigs.items():
        print("  shared by:", ", ".join(labels))


if __name__ == "__main__":
    main()
