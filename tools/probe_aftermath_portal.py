"""MP_Aftermath vs MP_Aftermath_Portal -- what the Portal variant actually is.

The Portal variant does NOT live beside the MP level: it is a full level of its
own under `game/glacierportal/levels/mp_aftermath_portal` (studio directory
GLACIERPORTAL, not GLACIERMP). Anything that builds paths or indexes from
"game/glaciermp/levels/<level>" finds nothing for it -- which is the shape of
the missing-GUID-index problem, not anything malformed inside the variant.

This probe:
  1. diffs the two level directories (file sets, per-top-dir counts);
  2. runs the terrain container/block walk on the variant's own
     mp_aftermath_portal_terrain and prints it beside mp_aftermath's;
  3. compares the two decals.TerrainDecals and the two streaming trees
     byte-for-byte;
  4. checks the water layer and the populated ECS prefab on the variant.

Usage:  probe_aftermath_portal.py [--full]
"""
import collections
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402

MP = os.path.join(C.LEVELS, "mp_aftermath")
PORTAL = os.path.join(C.BUNDLES, "game", "glacierportal", "levels",
                      "mp_aftermath_portal")


def tree_files(root):
    out = {}
    for dirpath, _d, files in os.walk(root):
        rel = os.path.relpath(dirpath, root)
        for f in files:
            key = (f if rel == "." else rel.replace(os.sep, "/") + "/" + f).lower()
            out[key] = os.path.join(dirpath, f)
    return out


def sha1(p, limit=None):
    h = hashlib.sha1()
    with open(p, "rb") as fh:
        while True:
            b = fh.read(1 << 20)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def summarize(names):
    c = collections.Counter()
    for n in names:
        c[n.split("/")[0] if "/" in n else "(root)"] += 1
    return c.most_common(12)


def terrain_summary(level_dir, label):
    td = None
    for d in sorted(os.listdir(level_dir)):
        p = os.path.join(level_dir, d)
        if os.path.isdir(p) and "terrain" in d.lower() and \
                any(f.endswith(".TerrainStreamingTree") for f in os.listdir(p)):
            td = p
            break
    if td is None:
        print("%s: NO terrain dir" % label)
        return None
    st = T._res(td, ".TerrainStreamingTree")
    d = C.read(st)
    hdr, blocks, after = T.container(d)
    print("%s terrain: %s  %d bytes  NodeCount=%d  blocks=%s"
          % (label, os.path.basename(td), len(d), hdr["NodeCount"],
             [(t, s) for t, _o, s in blocks]))
    for t, off, size in blocks:
        if t == 0:
            h = T.hf_header(d, off)
            nodes, kinds, slack, _ = T.hf_walk(d, off, size, h)
            r = nodes[0]
            print("   block0 xs=%d WorldSizeY=%.1f root AABB y %.3f..%.3f, %d nodes %s"
                  % (h["xs"], h["WorldSizeY"], r[2][1], r[3][1], len(nodes), dict(kinds)))
        elif t == 7:
            n, entries, bg = T.raster_footer(d, off, size)
            print("   block7 pairCount=%s bg=0x%08X" % (n, bg))
    return st


def main():
    print("MP     =", MP)
    print("PORTAL =", PORTAL)
    a = tree_files(MP)
    b = tree_files(PORTAL)
    # normalise the level-name difference out of the comparison
    def norm(k):
        return k.replace("mp_aftermath_portal", "@LVL@").replace("mp_aftermath", "@LVL@")
    na = {norm(k): k for k in a}
    nb = {norm(k): k for k in b}
    only_a = sorted(set(na) - set(nb))
    only_b = sorted(set(nb) - set(na))
    both = sorted(set(na) & set(nb))
    print("\nfiles: mp %d, portal %d, shared-by-name %d, only-mp %d, only-portal %d"
          % (len(a), len(b), len(both), len(only_a), len(only_b)))
    print("\nonly in MP (top dirs):     ", summarize(only_a))
    print("only in PORTAL (top dirs): ", summarize(only_b))
    if "--full" in sys.argv:
        for k in only_b:
            print("   PORTAL-only:", nb[k])

    # identical content?
    same = diff = 0
    diffs = []
    for k in both:
        pa, pb = a[na[k]], b[nb[k]]
        if os.path.getsize(pa) == os.path.getsize(pb) and sha1(pa) == sha1(pb):
            same += 1
        else:
            diff += 1
            diffs.append((k, os.path.getsize(pa), os.path.getsize(pb)))
    print("\nshared-by-name files: %d byte-identical, %d differ" % (same, diff))
    big = sorted(diffs, key=lambda x: -abs(x[1] - x[2]))[:15]
    for k, sa, sb in big:
        print("   differs %-70s mp=%d portal=%d" % (k, sa, sb))

    print()
    terrain_summary(MP, "MP  ")
    terrain_summary(PORTAL, "PORT")

    # water on the variant
    w = os.path.join(PORTAL, "_layers_content", "water.ebx")
    print("\nportal _layers_content/water.ebx:",
          "%d bytes" % os.path.getsize(w) if os.path.isfile(w) else "MISSING")
    if os.path.isfile(w):
        D, f = C.open_ebx(w)
        for i, gs, tn in C.instances(D):
            if tn == "WaterSurfaceEntityData":
                rec = C.named(D.read_instance(i))
                tr = rec["Transform"]
                trans = [v for kk, v in tr.items() if isinstance(v, dict)
                         and kk not in ("__type",)][-1]
                print("   WaterSurfaceEntityData trans=%s  QueryBoxHalfExtent=%s  Visible=%s"
                      % (trans, rec.get("QueryBoxHalfExtent"), rec.get("Visible")))

    # ECS prefab census on the variant
    shapes = collections.Counter()
    for dirpath, _d, files in os.walk(PORTAL):
        for fn in files:
            if not fn.endswith("_ecsprefab.ebx"):
                continue
            D, f = C.open_ebx(os.path.join(dirpath, fn))
            ent = arch = seg = edits = 0
            comps = []
            for i, gs, tn in C.instances(D):
                rec = None
                if tn == "EcsRuntimePrefabAsset":
                    rec = C.named(D.read_instance(i))
                    ent = len(rec.get("EntityTable") or [])
                    arch = len(rec.get("ArchetypeTable") or [])
                    seg = len(rec.get("Segments") or [])
                    for ar in (rec.get("ArchetypeTable") or []):
                        comps += ar.get("ExplicitComponents") or []
                elif tn == "EcsComponentSegment":
                    rec = C.named(D.read_instance(i))
                    edits += len(rec.get("StaticEdits") or []) + \
                        len(rec.get("DynamicEdits") or [])
            shapes[(ent, arch, seg, edits, tuple(sorted(set(comps))))] += 1
    print("\nportal ECS prefab shapes:")
    for shape, ccount in shapes.most_common():
        print("   x%-3d ent=%d arch=%d seg=%d edits=%d comps=%s"
              % (ccount, shape[0], shape[1], shape[2], shape[3], list(shape[4])))


if __name__ == "__main__":
    main()
