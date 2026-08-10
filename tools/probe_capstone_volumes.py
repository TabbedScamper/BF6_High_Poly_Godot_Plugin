"""MP_Capstone's environment decal volumes and reflection volumes, enumerated
with types and bounds -- real data for the placer (plugin tasks #51/#52).

Scans every EBX partition under the level whose EFIX type table declares any of
the volume types, then decodes each instance and prints its transform / extents
and the fields that identify what it projects or reflects.

Usage:  probe_capstone_volumes.py [level] [--full]
"""
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402
import ebx as ebxmod            # noqa: E402

WANT = re.compile(r"EnvironmentDecalVolume|DecalVolumeEntity|ReflectionVolume", re.I)


def vec(v):
    if isinstance(v, dict) and "X" in v:
        return "(%.2f, %.2f, %.2f)" % (v["X"], v["Y"], v["Z"])
    return v


def show_instance(rel, i, tn, rec, full=False):
    print("  [%s #%d] %s" % (rel, i, tn))
    if not rec:
        print("      <no decode>")
        return
    r = C.named(rec)
    keys = list(r.keys())
    for k in keys:
        if k == "__type":
            continue
        v = r[k]
        if isinstance(v, dict) and v.get("__type", "").endswith("Transform"):
            rows = {kk: vv for kk, vv in v.items() if kk != "__type"}
            print("      %-28s %s" % (k, "  ".join(
                "%s=%s" % (kk, vec(vv)) for kk, vv in rows.items())))
        elif isinstance(v, dict) and "X" in v:
            print("      %-28s %s" % (k, vec(v)))
        elif full or not isinstance(v, (dict, list)):
            s = json.dumps(v, default=str)
            if len(s) > 160:
                s = s[:160] + "..."
            print("      %-28s %s" % (k, s))
        else:
            s = json.dumps(v, default=str)
            if len(s) > 160:
                s = s[:160] + "..."
            print("      %-28s %s" % (k, s))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_capstone"
    full = "--full" in sys.argv
    root = os.path.join(C.LEVELS, level)
    counts = {}
    for dirpath, _d, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            try:
                f = ebxmod.parse(p)
            except Exception:
                continue
            names = [C.tname(ebxmod._guid_str(g)) for g in f.type_guids]
            if not any(WANT.search(t) for t in names):
                continue
            rel = os.path.relpath(p, root).replace(os.sep, "/")
            try:
                D, _f = C.open_ebx(p)
            except Exception as e:
                print("  %s: open failed (%s)" % (rel, e))
                continue
            print("=" * 78)
            print(rel)
            for i, gs, tn in C.instances(D):
                if not WANT.search(tn):
                    continue
                counts[tn] = counts.get(tn, 0) + 1
                try:
                    rec = D.read_instance(i)
                except Exception as e:
                    print("  [%s #%d] %s  <decode failed: %s>" % (rel, i, tn, e))
                    continue
                show_instance(rel, i, tn, rec, full)
    print("=" * 78)
    print("instance totals under %s:" % level)
    for t, c in sorted(counts.items(), key=lambda kv: -kv[1]):
        print("   x%-4d %s" % (c, t))


if __name__ == "__main__":
    main()
