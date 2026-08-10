"""Level-root + _layers_world placement census, fleet-wide (RESEARCH-LEVELROOT).

The build is about to extend the placement walk to the LEVEL-ROOT partition
(mp_<level>.ebx) and the _layers_world/* partitions (world.ebx especially),
because three fleet studies found skylines and seas placed there. This probe
measures, for every level, WHAT those partitions place and HOW:

  * every StaticModelGroupEntityData: member count, placed-instance count,
    whether InstanceTransforms are present, member categories (backdrop /
    vegetation / water / fx / other) via the _af leaf store, translation range;
  * every other placement carrier (*ReferenceObjectData with a Blueprint
    import, StaticModelEntityData, ...), counted per partition;
  * how the root reaches _layers_world (SubWorldReferenceObjectData BundleName
    + AutoLoad), which decides whether the existing walk already visits it.

READ-ONLY on game data. Results also dumped as JSON for the doc table.

Usage:  probe_lvlroot_survey.py [level ...]        (default: whole fleet)
        probe_lvlroot_survey.py --json OUT.json mp_battery
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402

# level leaf -> studio dir under bundles/game/
FLEET = {
    "mp_abbasid": "glaciermp", "mp_aftermath": "glaciermp",
    "mp_badlands": "glaciermp", "mp_battery": "glaciermp",
    "mp_capstone": "glaciermp", "mp_contaminated": "glaciermp",
    "mp_dumbo": "glaciermp", "mp_eastwood": "glaciermp",
    "mp_firestorm": "glaciermp", "mp_golmudrailway": "glaciermp",
    "mp_isolated": "glaciermp", "mp_limestone": "glaciermp",
    "mp_outskirts": "glaciermp", "mp_plaza": "glaciermp",
    "mp_subsurface": "glaciermp", "mp_tungsten": "glaciermp",
    "mp_propaganda": "glaciermp",
    # extras beyond the 17 glaciermp worlds
    "mp_granite": "glaciergranite", "mp_portal_sand": "glacierportal",
    "mp_aftermath_portal": "glacierportal",
    "mp_portal_lobby": "glacierportal",
    "mp_granite_clubhouse_portal": "glacierportal",
    "mp_granite_mainstreet_portal": "glacierportal",
    "mp_granite_marina_portal": "glacierportal",
    "mp_granite_militaryrnd_portal": "glacierportal",
    "mp_granite_militarystorage_portal": "glacierportal",
    "mp_granite_techcampus_portal": "glacierportal",
    "mp_granite_underground_portal": "glacierportal",
}

GAME = os.path.join(C.BUNDLES, "game")

# The full-dump partition-guid -> path index, built by probe_tung_guidscan over
# the whole bundles tree (cache key "."). 449k entries; the _af store alone
# covers only ~17k partitions and misses most SMG member targets.
import probe_tung_guidscan as G      # noqa: E402

_gi = None


def gindex():
    global _gi
    if _gi is None:
        p = os.path.join(G.CACHE, "..json")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                _gi = json.load(fh)
        else:
            _gi = {}
    return _gi

# LinearTransform member hashes (bf6_walk.gd, exe-declared order)
LT_TRANS = "0xBC4B07B4"


def lt_trans(lt):
    """named LinearTransform dict -> (x, y, z) of the translation row."""
    if not isinstance(lt, dict):
        return None
    v = lt.get("Trans") or lt.get(LT_TRANS)
    if not isinstance(v, dict):
        return None
    return (v.get("X", 0.0), v.get("Y", 0.0), v.get("Z", 0.0))


def leaf_of(guid_str, full=False):
    if guid_str is None:
        return None
    hit = gindex().get(str(guid_str))
    if hit:
        hit = str(hit).replace("\\", "/")
        return hit if full else os.path.basename(hit).replace(".ebx", "")
    ls = C.af_leaf(guid_str)
    if ls:
        for l in ls:
            if l.endswith(".ebx"):
                return l[:-4]
        return ls[0]
    return None


def category(leaf):
    if leaf is None:
        return "unresolved"
    l = leaf.lower()
    if ("ocean" in l or "waterplane" in l or "watersurface" in l
            or ("water" in l and ("plane" in l or l.startswith("bd_")))
            or l.startswith("wp_")):
        return "water"
    if "smoke" in l or l.startswith("fx") or "_fx_" in l or "fire" in l \
            or "plume" in l:
        return "fx"
    if ("veg" in l or "tree" in l or "bush" in l or "grass" in l
            or "plant" in l or "foliage" in l or "hedge" in l
            or "weed" in l or "ivy" in l):
        return "vegetation"
    if (l.startswith("bd_") or "_bd_" in l or "backdrop" in l
            or "billboard" in l or "vista" in l or "skyline" in l
            or "skirt" in l):
        return "backdrop"
    if ("cliff" in l or "rock" in l or "mountain" in l or "terrain" in l
            or "dune" in l or "hill" in l):
        return "terrain-vista"
    return "other"


def analyze_smg(D, i, rec):
    """named SMG instance -> summary dict."""
    mems = rec.get("MemberDatas") or []
    total = 0
    no_xf = 0
    xf_count = 0
    cats = collections.Counter()
    names = collections.Counter()
    ymin, ymax = None, None
    water_members = []
    for m in mems:
        n = int(m.get("InstanceCount") or 1)
        total += n
        xfs = m.get("InstanceTransforms") or []
        if not xfs:
            no_xf += 1
        xf_count += len(xfs)
        mt = (m.get("MemberType") or {}).get("import")
        ma = (m.get("MeshAsset") or {}).get("import")
        leaf = leaf_of(mt) or leaf_of(ma)
        cat = category(leaf)
        cats[cat] += n
        names[leaf or "?"] += n
        if cat == "water":
            water_members.append((leaf, n,
                                  [lt_trans(x) for x in xfs[:2]]))
        for x in xfs:
            t = lt_trans(x)
            if t is None:
                continue
            y = t[1]
            ymin = y if ymin is None else min(ymin, y)
            ymax = y if ymax is None else max(ymax, y)
    return {
        "inst": i, "members": len(mems), "placed": total,
        "xf_rows": xf_count, "members_without_xf": no_xf,
        "cats": dict(cats), "y_range": [ymin, ymax],
        "top": names.most_common(8), "water": water_members,
    }


CARRIER_SUFFIX = "ReferenceObjectData"
CARRIER_EXTRA = {"StaticModelEntityData", "StaticModelGroupEntityData"}


def analyze_partition(path, deep_carriers=True):
    """One EBX -> {types, smgs, carriers, subworlds, layers}."""
    out = {"file": os.path.basename(path), "bytes": os.path.getsize(path)}
    try:
        D, f = C.open_ebx(path)
    except Exception as e:                      # noqa: BLE001 - survey, report
        out["error"] = "%s: %s" % (type(e).__name__, e)
        return out
    types = collections.Counter()
    smgs = []
    carriers = collections.Counter()
    carrier_targets = collections.Counter()
    subworlds = []
    layers = []
    for i, gs, tn in C.instances(D):
        types[tn] += 1
        interesting = (tn == "StaticModelGroupEntityData"
                       or tn.endswith(CARRIER_SUFFIX)
                       or tn in CARRIER_EXTRA)
        if not interesting:
            continue
        try:
            rec = C.named(D.read_instance(i))
        except Exception as e:                  # noqa: BLE001
            carriers["DECODE_FAIL:" + tn] += 1
            continue
        if tn == "StaticModelGroupEntityData":
            smgs.append(analyze_smg(D, i, rec))
        elif tn == "SubWorldReferenceObjectData":
            subworlds.append({"bundle": rec.get("BundleName"),
                              "autoload": rec.get("AutoLoad")})
        elif tn == "LayerReferenceObjectData":
            bp = (rec.get("Blueprint") or {}).get("import")
            layers.append(leaf_of(bp) or bp)
        else:
            carriers[tn] += 1
            if deep_carriers:
                bp = (rec.get("Blueprint") or {}).get("import")
                if bp:
                    carrier_targets["%s -> %s" % (tn, leaf_of(bp) or bp)] += 1
    out.update(types={k: v for k, v in types.most_common()},
               smgs=smgs, carriers=dict(carriers),
               carrier_targets={k: v for k, v in
                                carrier_targets.most_common(25)},
               subworlds=subworlds, layers=layers,
               instances=sum(types.values()))
    return out


def survey_level(level, studio):
    lvl_dir = os.path.join(GAME, studio, "levels", level)
    res = {"level": level, "studio": studio}
    root = os.path.join(lvl_dir, level + ".ebx")
    if not os.path.isfile(root):
        res["root"] = None
        return res
    res["root"] = analyze_partition(root)
    lw_dir = os.path.join(lvl_dir, "_layers_world")
    lw = []
    if os.path.isdir(lw_dir):
        for fn in sorted(os.listdir(lw_dir)):
            if not fn.endswith(".ebx"):
                continue
            a = analyze_partition(os.path.join(lw_dir, fn))
            # keep only files that place anything (SMG or carriers)
            if a.get("smgs") or a.get("carriers"):
                lw.append(a)
    res["layers_world"] = lw
    return res


def brief(res):
    lines = ["=" * 72, res["level"]]
    r = res.get("root")
    if not r:
        lines.append("  NO LEVEL-ROOT PARTITION in the dump")
        return "\n".join(lines)
    lines.append("  root %s: %d instances %s" %
                 (r["file"], r.get("instances", 0),
                  json.dumps(r.get("types", {}))[:220]))
    for s in r.get("smgs", []):
        lines.append("    SMG @%d: %d members / %d placed, xf_rows=%d, "
                     "no-xf members=%d, y %s..%s cats=%s"
                     % (s["inst"], s["members"], s["placed"], s["xf_rows"],
                        s["members_without_xf"],
                        None if s["y_range"][0] is None else round(s["y_range"][0], 1),
                        None if s["y_range"][1] is None else round(s["y_range"][1], 1),
                        json.dumps(s["cats"])))
        for l, n in s["top"][:5]:
            lines.append("        x%-4d %s" % (n, l))
        for w in s["water"]:
            lines.append("        WATER %s x%d at %s" % w)
    if r.get("carriers"):
        lines.append("    root carriers: %s" % json.dumps(r["carriers"]))
        for k, v in list(r.get("carrier_targets", {}).items())[:10]:
            lines.append("        x%-3d %s" % (v, k))
    for sw in r.get("subworlds", []):
        lines.append("    subworld %-60s autoload=%s"
                     % (sw["bundle"], sw["autoload"]))
    for l in r.get("layers", []):
        lines.append("    layer-ref %s" % l)
    for a in res.get("layers_world", []):
        lines.append("  _layers_world/%s: %d inst  types=%s"
                     % (a["file"], a.get("instances", 0),
                        json.dumps(a.get("types", {}))[:180]))
        for s in a.get("smgs", []):
            lines.append("    SMG @%d: %d members / %d placed, xf_rows=%d, "
                         "no-xf=%d, y %s..%s cats=%s"
                         % (s["inst"], s["members"], s["placed"], s["xf_rows"],
                            s["members_without_xf"],
                            None if s["y_range"][0] is None else round(s["y_range"][0], 1),
                            None if s["y_range"][1] is None else round(s["y_range"][1], 1),
                            json.dumps(s["cats"])))
            for l, n in s["top"][:4]:
                lines.append("        x%-4d %s" % (n, l))
            for w in s["water"]:
                lines.append("        WATER %s x%d at %s" % w)
        if a.get("carriers"):
            lines.append("    carriers: %s" % json.dumps(a["carriers"]))
            for k, v in list(a.get("carrier_targets", {}).items())[:8]:
                lines.append("        x%-3d %s" % (v, k))
    return "\n".join(lines)


def main():
    args = sys.argv[1:]
    json_out = None
    if args and args[0] == "--json":
        json_out = args[1]
        args = args[2:]
    levels = args or sorted(FLEET)
    all_res = []
    for lvl in levels:
        studio = FLEET.get(lvl, "glaciermp")
        res = survey_level(lvl, studio)
        all_res.append(res)
        print(brief(res))
        sys.stdout.flush()
    if json_out:
        with open(json_out, "w", encoding="utf-8") as fh:
            json.dump(all_res, fh, indent=1, default=str)
        print("\nJSON ->", json_out)


if __name__ == "__main__":
    main()
