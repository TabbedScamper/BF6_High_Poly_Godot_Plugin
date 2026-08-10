"""Census of the user One-Off scene MP_Abbasid_Supremacy_details_lights.tscn.

Reported: "loads with very few high-poly assets".  This reads the scene file
and reports what it is actually made of, so the report can be explained from
content rather than guessed at.  Read-only.

Usage:  probe_abbasid_supremacy.py [tscn-path]
"""
import collections
import re
import sys

DEFAULT = (r"C:\PortalSDK\GodotProject\User_Created\levels\User_Maps\One-Offs"
           r"\MP_Abbasid_Supremacy_details_lights.tscn")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT
    txt = open(path, encoding="utf-8").read()
    root = re.search(r'\[node name="([^"]+)"', txt).group(1)
    ext = dict(re.findall(
        r'\[ext_resource type="PackedScene"[^\]]*?path="res://([^"]+)" id="([^"]+)"',
        txt))
    id2p = {v: k for k, v in ext.items()}
    inst = re.findall(r'instance=ExtResource\("([^"]+)"\)', txt)
    cnt = collections.Counter(id2p.get(i, "?" + i) for i in inst)
    print("root node: %r  (map_of() -> %r)"
          % (root, root if root.startswith("MP_") else ""))
    print("nodes: %d   instanced: %d   distinct scenes: %d"
          % (txt.count("\n[node"), len(inst), len(cnt)))
    cat = collections.Counter()
    for p, c in cnt.items():
        cat["/".join(p.split("/")[:2])] += c
    print("\nby category:")
    for k, c in cat.most_common():
        print("   %5d  %s" % (c, k))
    print("\ntop 25 scenes:")
    for p, c in cnt.most_common(25):
        print("   %5d  %s" % (c, p))
    # scenes whose names tie them to OTHER maps' asset families
    foreign = [p for p in cnt if re.search(
        r"FiringRange|BR_|Outskirts|_Plaza|Granite", p)]
    print("\nscenes from other maps' families (%d distinct, %d instances):"
          % (len(foreign), sum(cnt[p] for p in foreign)))
    for p in sorted(foreign):
        print("   %4d  %s" % (cnt[p], p))


if __name__ == "__main__":
    main()
