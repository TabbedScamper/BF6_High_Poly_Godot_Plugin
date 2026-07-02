"""Full scene audit: for every deployed scene prop, verify the matched game mesh's
dimensions against the SDK proxy AABB. For poor fits, search ALL family variants —
including UNEXTRACTED MeshSets in the dump (extracting them on demand) — score by
dimensions, auto-pin conclusive winners, and emit an ambiguous list for visual review.
Usage: audit_scene.py
Writes data/scene_audit.json
"""
import os, re, sys, io, json, glob, math, contextlib
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rebuild_one_noshadow import DUMP, OUT, main as rebuild

GP = os.path.join(os.environ.get("PORTAL_GODOT_PROJECT", ""), "highpoly")
DATA = os.environ.get("PIPELINE_DATA", os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "data"))

PREF = re.compile(r'^(ba_|bd_|br_|bs_|com_|cas_|ind_|mil_|naf_|seu_|euu_|wuu_|wud_|wuc_|wum_|meshp_|lf_|dc_|de_|fed_|ms_|tr_|ob_|em32_|prj_|gad_|me_)+')

def core(n):
    s = PREF.sub('', n.lower())
    s = re.sub(r'(_\d.*)$', '', s)
    return s

def obj_dims(name, cache={}):
    if name in cache: return cache[name]
    p = os.path.join(OUT, name, name + ".obj")
    if not os.path.exists(p):
        cache[name] = None; return None
    vs = []
    for l in open(p):
        if l.startswith("v "):
            vs.append([float(x) for x in l.split()[1:4]])
    if not vs:
        cache[name] = None; return None
    a = np.array(vs)
    d = np.sort(a.max(axis=0) - a.min(axis=0))[::-1]
    cache[name] = d
    return d

def fit(pd, hd):
    """(spread, mean) over usable dims, orientation-free (sorted)."""
    r = []
    for i in range(3):
        if pd[i] > 0.05 and hd[i] > 0.05:
            r.append(pd[i] / hd[i])
    if not r: return (1.0, 1.0)
    return (max(r) / min(r), sum(r) / len(r))

def badness(pd, hd):
    s, m = fit(pd, hd)
    return (s - 1.0) + abs(math.log(m)) * 0.6

def main():
    prox_aabb = {}
    for ln in open(os.path.join(DATA, "proxy_aabb.tsv")):
        p = ln.rstrip("\n").split("\t")
        if p[0] != "proxy":
            prox_aabb[p[0]] = np.sort([float(p[1]), float(p[2]), float(p[3])])[::-1]
    match = {}
    for ln in open(os.path.join(DATA, "matches.tsv"), encoding="utf-8"):
        p = ln.rstrip("\n").split("\t")
        if len(p) >= 4 and p[0] != "godot_proxy":
            match[p[0]] = (p[1], p[3])

    # meshset index (name -> path), once
    print("indexing meshsets...", flush=True)
    msidx = {}
    for m in glob.glob(os.path.join(DUMP, "bundles", "**", "*.MeshSet"), recursive=True):
        b = os.path.basename(m)[:-8]
        nm = b[:-5] if b.endswith("_mesh") else b
        msidx.setdefault(nm, m)

    scene = sorted(d for d in os.listdir(GP) if os.path.isdir(os.path.join(GP, d)))
    report = {"good": [], "pinned": [], "ambiguous": [], "no_proxy_aabb": [], "unfixable": []}
    for prox in scene:
        if prox not in match: continue
        cur, tier = match[prox]
        pd = prox_aabb.get(prox)
        if pd is None:
            report["no_proxy_aabb"].append(prox); continue
        cd = obj_dims(cur)
        cur_bad = badness(pd, cd) if cd is not None else 9e9
        if cur_bad < 0.18 and tier != "none":
            report["good"].append({"proxy": prox, "match": cur, "badness": round(cur_bad, 3)})
            continue
        # ---- flagged: build candidate set ----
        stem = core(prox) or core(cur)
        if len(stem) < 4:
            report["unfixable"].append({"proxy": prox, "why": "stem too short", "match": cur})
            continue
        # destruction-variant candidates only when the PROXY itself is a wreck/debris
        # piece (a dc_-matched intact proxy is usually the bug we're hunting)
        want_dc = bool(re.search(r'debris|wreck|destro|broken|collaps|burn', prox, re.I))
        cands = set(n for n in os.listdir(OUT) if stem in n.lower() and n.startswith("dc_") == want_dc)
        # unextracted meshsets in the dump matching the stem: extract (cap 12)
        fresh = [n for n in msidx if stem in n.lower() and n not in cands
                 and not os.path.exists(os.path.join(OUT, n, n + ".obj"))
                 and n.startswith("dc_") == want_dc][:12]
        for n in fresh:
            try:
                with contextlib.redirect_stdout(io.StringIO()):
                    rebuild(n, msidx[n])
                cands.add(n)
            except Exception:
                pass
        cands.add(cur)
        scored = []
        for n in sorted(cands):
            hd = obj_dims(n)
            if hd is None: continue
            scored.append((badness(pd, hd), n, [round(float(x), 2) for x in hd]))
        scored.sort()
        if not scored:
            report["unfixable"].append({"proxy": prox, "why": "no candidates", "match": cur})
            continue
        best = scored[0]
        entry = {"proxy": prox, "old": cur, "old_badness": round(cur_bad, 3),
                 "proxy_dims": [round(float(x), 2) for x in pd],
                 "candidates": [{"name": n, "badness": round(b, 3), "dims": d} for b, n, d in scored[:6]]}
        if best[0] < 0.10 and (cur_bad - best[0]) > 0.08:
            entry["new"] = best[1]
            report["pinned"].append(entry)
        elif best[0] < cur_bad - 0.05:
            report["ambiguous"].append(entry)
        else:
            report["unfixable"].append({"proxy": prox, "why": "no better candidate",
                                        "match": cur, "badness": round(cur_bad, 3),
                                        "best_alt": best[1], "alt_badness": round(best[0], 3)})
    json.dump(report, open(os.path.join(DATA, "scene_audit.json"), "w"), indent=1)
    print(f"good={len(report['good'])} pinned={len(report['pinned'])} "
          f"ambiguous={len(report['ambiguous'])} unfixable={len(report['unfixable'])} "
          f"no_aabb={len(report['no_proxy_aabb'])}", flush=True)
    for e in report["pinned"]:
        print(f"  PIN {e['proxy']}: {e['old']} -> {e['new']}", flush=True)
    for e in report["ambiguous"]:
        print(f"  AMBIG {e['proxy']}: {e['old']} (bad {e['old_badness']}) alts: "
              + ", ".join(f"{c['name']}({c['badness']})" for c in e["candidates"][:3]), flush=True)

if __name__ == "__main__":
    main()
