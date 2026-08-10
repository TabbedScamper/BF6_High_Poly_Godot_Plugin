"""Dumbo generated skyline: is there a statically readable transform list?
(RESEARCH-LEVELROOT question 1.)

MAP-DUMBO.md left the skyline as the one placement-walk gap: 92 authored
bd_eus_dumbo_{brooklyn,manhattan}_NN_mid MeshSets referenced only by the
MeshVariationDatabase, placements presumed to live inside a generated-city
blueprint. probe_lvlroot_survey has since measured that mp_dumbo.ebx's root
StaticModelGroup (inst @30) places 155 ag_motivebackdropsoutputs_
generated_blueprints_* partitions WITH InstanceTransforms. This probe closes
the question end-to-end:

  A. dump the root SMG's generated-blueprint members and their transforms
     (the candidate static transform list);
  B. decode one generated blueprint partition + its _mesh.ebx: what the
     placed thing actually is (entity type, mesh, materials, imports --
     especially whether it imports any bd_eus_dumbo_* mid mesh);
  C. census the 963 TerrainFillDecalData records of ..._city_blocks: field
     set, value ranges, imports -- do they carry mesh refs / transforms?
  D. the MVDB: which record type references the 92 mid meshes and what the
     record holds (materials vs transforms);
  E. the lay_backdropbuildingsescsplines ECS prefab: the 3 "Manual City
     Blocks" entities and spline control points -- the generator's INPUT.

READ-ONLY on game data.
Usage: probe_lvlroot_dumbo_cityblocks.py
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_lvlroot_survey as S     # noqa: E402

DUMBO = os.path.join(C.LEVELS, "mp_dumbo")
GEN = os.path.join(DUMBO, "generated")
BD = os.path.join(DUMBO, "backdrop", "buildings")

GENBP = "ag_motivebackdropsoutputs_generated_blueprints_"


def fmt_lt(lt):
    """named LinearTransform -> compact basis+trans string."""
    if not isinstance(lt, dict):
        return repr(lt)
    def row(n):
        v = lt.get(n) or {}
        return (round(v.get("X", 0), 2), round(v.get("Y", 0), 2),
                round(v.get("Z", 0), 2))
    return "T=%s R=%s U=%s F=%s" % (row("Trans"), row("Right"),
                                    row("Up"), row("Forward"))


# --- A. the root SMG's generated-blueprint members ---------------------------
def part_a():
    print("=" * 78)
    print("A. mp_dumbo.ebx root SMG: generated-blueprint members + transforms")
    D, f = C.open_ebx(os.path.join(DUMBO, "mp_dumbo.ebx"))
    for i, gs, tn in C.instances(D):
        if tn != "StaticModelGroupEntityData":
            continue
        rec = C.named(D.read_instance(i))
        mems = rec.get("MemberDatas") or []
        gen, other = [], collections.Counter()
        ys = []
        for m in mems:
            mt = (m.get("MemberType") or {}).get("import")
            leaf = S.leaf_of(mt)
            xfs = [S.lt_trans(x) for x in (m.get("InstanceTransforms") or [])]
            if leaf and leaf.startswith(GENBP):
                gen.append((leaf[len(GENBP):], len(xfs), xfs))
                ys += [t[1] for t in xfs if t]
            else:
                other[leaf or "?"] += len(xfs)
        print("  SMG @%d: %d members total; %d are generated blueprints, "
              "%d transform rows on them, y %.1f..%.1f"
              % (i, len(mems), len(gen), sum(n for _, n, _ in gen),
                 min(ys), max(ys)))
        multi = [g for g in gen if g[1] != 1]
        print("  members with !=1 instances: %d" % len(multi))
        for leaf, n, xfs in gen[:6]:
            print("    %s x%d  trans %s" % (leaf, n,
                                            [tuple(round(c, 1) for c in t)
                                             for t in xfs[:2]]))
        print("  non-generated members (placed count): %s"
              % dict(other.most_common(6)))
        # full transform list dump for the doc's evidence trail
        return {leaf: xfs for leaf, n, xfs in gen}


# --- B. one generated blueprint + its mesh -----------------------------------
def dump_partition(path, label, max_inst=None):
    print("-" * 78)
    print(label, os.path.basename(path))
    D, f = C.open_ebx(path)
    for i, gs, tn in C.instances(D):
        if max_inst is not None and i >= max_inst:
            break
        rec = C.named(D.read_instance(i))
        blob = json.dumps(rec, default=str)
        print("  @%d %-38s %s" % (i, tn, blob[:600]))
    imps = C.imports_of(f)
    print("  imports (%d):" % len(imps))
    for pgs, igs, leaves in imps:
        print("    %s -> %s" % (pgs, ", ".join(leaves)
                                or S.leaf_of(pgs, full=True)
                                or "UNRESOLVED"))
    return D, f


def part_b():
    print("=" * 78)
    print("B. one generated city-block blueprint, fully decoded")
    bp = sorted(fn for fn in os.listdir(GEN)
                if fn.startswith(GENBP) and fn.endswith(".ebx")
                and "_mesh" not in fn and "physics" not in fn)
    print("  (%d generated blueprint partitions exist)" % len(bp))
    dump_partition(os.path.join(GEN, bp[0]), "BLUEPRINT")
    mesh = bp[0][:-4] + "_mesh.ebx"
    dump_partition(os.path.join(GEN, mesh), "MESH")
    # do ANY of the 155 blueprints/meshes import a bd_eus mid mesh?
    hits = 0
    checked = 0
    for fn in bp:
        for stem in (fn, fn[:-4] + "_mesh.ebx"):
            p = os.path.join(GEN, stem)
            if not os.path.isfile(p):
                continue
            checked += 1
            try:
                D, f = C.open_ebx(p)
            except Exception:
                continue
            for pgs, igs, leaves in C.imports_of(f):
                if any("bd_eus_dumbo" in l for l in leaves):
                    hits += 1
                    print("  IMPORT HIT: %s imports %s" % (stem, leaves))
    print("  bd_eus_dumbo_* imports across all %d generated ebx: %d"
          % (checked, hits))


# --- C. the 963 TerrainFillDecalData records ---------------------------------
def part_c():
    print("=" * 78)
    print("C. ag_motivebackdrops_outputs_city_blocks: TerrainFillDecalData")
    p = os.path.join(GEN, "ag_motivebackdrops_outputs_city_blocks_dbfa4760.ebx")
    D, f = C.open_ebx(p)
    n = 0
    fields = collections.Counter()
    numeric_ranges = {}
    ref_fields = collections.Counter()
    sample = None
    types = collections.Counter()
    for i, gs, tn in C.instances(D):
        types[tn] += 1
        if tn != "TerrainFillDecalData":
            continue
        n += 1
        rec = C.named(D.read_instance(i))
        if sample is None:
            sample = rec
        for k, v in rec.items():
            fields[k] += 1
            if isinstance(v, (int, float)) and k != "__type":
                lo, hi = numeric_ranges.get(k, (v, v))
                numeric_ranges[k] = (min(lo, v), max(hi, v))
            if isinstance(v, dict) and "import" in v:
                ref_fields["%s -> %s" % (k, S.leaf_of(v["import"]))] += 1
    print("  instance types: %s" % dict(types.most_common(8)))
    print("  TerrainFillDecalData records: %d" % n)
    print("  field presence: %s" % dict(fields))
    print("  numeric ranges:")
    for k, (lo, hi) in sorted(numeric_ranges.items()):
        print("    %-28s %s .. %s" % (k, lo, hi))
    print("  import-reference fields: %s" % dict(ref_fields.most_common(12)))
    print("  SAMPLE record: %s" % json.dumps(sample, default=str)[:1500])
    imps = C.imports_of(f)
    leafset = collections.Counter()
    for pgs, igs, leaves in imps:
        for l in leaves:
            if l.endswith(".ebx"):
                leafset[l[:-4]] += 1
    print("  partition imports (%d), leaves: %s"
          % (len(imps), dict(leafset.most_common(12))))


# --- D. the MVDB records for the 92 mid meshes -------------------------------
def part_d():
    print("=" * 78)
    print("D. meshvariationdb_win32: what references bd_eus_dumbo_*_mid")
    p = os.path.join(DUMBO, "mp_dumbo", "meshvariationdb_win32.ebx")
    D, f = C.open_ebx(p)
    # map import slot -> leaf, find bd_eus targets among the imports
    bd_parts = set()
    for pgs, igs, leaves in C.imports_of(f):
        hit = any("bd_eus_dumbo" in l for l in leaves)
        if not hit:
            l2 = S.leaf_of(pgs)
            hit = bool(l2 and "bd_eus_dumbo" in l2)
        if hit:
            # decoded records carry the PARTITION guid in their "import" slots
            bd_parts.add(str(pgs))
            bd_parts.add(str(igs))
    print("  import instance-guids resolving to bd_eus_dumbo_*: %d"
          % len(bd_parts))
    shown = 0
    hit_records = 0
    for i, gs, tn in C.instances(D):
        rec = C.named(D.read_instance(i))
        blob = json.dumps(rec, default=str)
        if any(g in blob for g in bd_parts):
            hit_records += 1
            if shown < 2:
                shown += 1
                print("  record @%d %s holds a bd_eus ref:" % (i, tn))
                print("    %s" % blob[:1200])
    print("  records containing a bd_eus_dumbo instance guid: %d" % hit_records)


# --- E. the ECS spline prefab: Manual City Blocks + control points -----------
def part_e():
    print("=" * 78)
    print("E. lay_backdropbuildingsescsplines ECS prefab: generator inputs")
    target = None
    for dirpath, _d, files in os.walk(DUMBO):
        for fn in files:
            if fn.endswith("_ecsprefab.ebx") and "backdropbuildings" in fn:
                target = os.path.join(dirpath, fn)
    if target is None:
        print("  prefab NOT FOUND")
        return
    print("  file: %s" % os.path.relpath(target, DUMBO))
    D, f = C.open_ebx(target)
    for i, gs, tn in C.instances(D):
        rec = C.named(D.read_instance(i))
        nm = rec.get("Name") if isinstance(rec, dict) else None
        if isinstance(nm, str) and ("city block" in nm.lower()
                                    or "manual" in nm.lower()):
            print("  @%d %s Name=%r:" % (i, tn, nm))
            print("    %s" % json.dumps(rec, default=str)[:1600])
    # count transform-carrying edits to show the spline geometry IS here
    lt_edits = 0
    for i, gs, tn in C.instances(D):
        if tn != "EcsComponentSegment":
            continue
        rec = C.named(D.read_instance(i))
        for e in (rec.get("StaticEdits") or []) + (rec.get("DynamicEdits") or []):
            blob = json.dumps(e, default=str)
            lt_edits += blob.count("LocalTransform")
    print("  LocalTransform edit mentions across segments: %d" % lt_edits)


def main():
    part_a()
    part_b()
    part_c()
    part_d()
    part_e()


if __name__ == "__main__":
    main()
