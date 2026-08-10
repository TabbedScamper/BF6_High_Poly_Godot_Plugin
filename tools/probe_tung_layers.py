"""Every ground layer of a level: its layer-graph record, its ShaderBlockDepot
record, the textures it binds and the constants it carries.

This is the join TERRAIN.md 9.1 describes, run end to end:

    <terrain>.VisualTerrain                 layerCount + link targets
    <terrain>.layergraphslayergraphs        record table -> per-layer ShaderBlockKey
    <terrain>.layergraphs_shaderblockdepot  key -> textures + constants

Texture partition GUIDs are resolved to asset paths through the guid index
built by probe_tung_guidscan.py (pass --index <subtree> to widen it).

Usage:  probe_tung_layers.py [level] [--index <subtree>]
"""
import collections
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_guidscan as G      # noqa: E402
import shaderblock                   # noqa: E402


def load_index(subtrees):
    gi = {}
    for s in subtrees:
        key = s.replace("/", "_").replace("\\", "_")
        p = os.path.join(G.CACHE, key + ".json")
        if os.path.isfile(p):
            with open(p, encoding="utf-8") as fh:
                gi.update(json.load(fh))
    return gi


def layer_table(td, dep):
    """TERRAIN.md 9.1: the record table's start offset is found by requiring
    that EVERY record's ShaderBlockKey resolves in the paired depot.

    A weaker rule -- "the 33 u64s at +20 are all non-zero and distinct" -- also
    fires, at a DIFFERENT offset, and produces a plausible-looking table whose
    keys resolve nowhere. The 100%-resolve requirement is what makes the fit
    unambiguous, and it is not optional."""
    lg = T._res(td, ".DE540C59")
    g = C.read(lg)
    n = struct.unpack_from("<I", g, 8)[0]
    ks = set(dep.key_to_record)
    best = None
    for start in range(0, len(g) - n * 32 + 1, 4):
        keys = [struct.unpack_from("<Q", g, start + i * 32 + 20)[0] for i in range(n)]
        hit = sum(1 for k in keys if k in ks)
        if best is None or hit > best[0]:
            best = (hit, start, keys)
        if hit == n:
            break
    hit, start, keys = best
    hashes = [struct.unpack_from("<Q", g, start + i * 32 + 12)[0] for i in range(n)]
    extra = [(struct.unpack_from("<I", g, start + i * 32)[0],
              struct.unpack_from("<I", g, start + i * 32 + 4)[0],
              struct.unpack_from("<I", g, start + i * 32 + 8)[0],
              struct.unpack_from("<I", g, start + i * 32 + 28)[0]) for i in range(n)]
    print("layer-graph record table @ %d, %d/%d keys resolve in the depot"
          % (start, hit, n))
    return n, keys, hashes, extra


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    subtrees = ["."]
    if "--index" in sys.argv:
        subtrees = [sys.argv[sys.argv.index("--index") + 1]]
    gi = load_index(subtrees)
    # the index maps partition guid -> relative EBX path; the pixels live in the
    # RES at the same path with the .ebx suffix dropped (terrain-layer-slot-hashes)
    gi = {k: v[:-4] if v.endswith(".ebx") else v for k, v in gi.items()}

    td = T.terr_dir(level)
    dep_path = T._res(td, "layergraphs_shaderblockdepot.ShaderBlockDepotResource")
    if dep_path is None:
        dep_path = T._res(td, ".ShaderBlockDepotResource")
    dep = shaderblock.parse_depot(dep_path)
    n, keys, hashes, extra = layer_table(td, dep)
    print("%s: %d layers, depot %s" % (level, n, os.path.basename(dep_path)))
    print("depot: %s" % dep.stats())
    if not gi:
        print("(no guid index cached -- run probe_tung_guidscan.py first; "
              "texture GUIDs will print raw)")

    # splat side: which layers are painted vs base
    st = T._res(td, ".TerrainStreamingTree")
    d = C.read(st)
    _h, blocks, _a = T.container(d)
    painted = basec = None
    pairs = []
    for t, off, size in blocks:
        if t == 1:
            _sh, painted, basec, _nn, _nr, _sl = T.splat_walk(d, off, size)
        if t == 7:
            _k, pairs, bg = T.raster_footer(d, off, size)
            pairs = pairs + [bg]

    resolved = 0
    per_tex = collections.Counter()
    for i in range(n):
        k = keys[i] if i < len(keys) else 0
        ri = dep.key_to_record.get(k)
        side = []
        if painted is not None:
            if painted.get(i):
                side.append("painted x%d" % painted[i])
            if basec.get(i):
                side.append("BASE x%d" % basec[i])
        print("-" * 76)
        print("L%02d  key=%016X  contentHash=%016X  A=%08X B=%08X C=%08X D=%08X  %s"
              % ((i, k, hashes[i]) + extra[i] + (", ".join(side) or "unused",)))
        if ri is None:
            print("     <key not in this depot>")
            continue
        resolved += 1
        rec = dep.records[ri]
        r = shaderblock.resolve_record(rec, gi)
        if r is None:
            print("     <blob failed to parse>")
            continue
        for lbl, path in sorted(r["textures"].items()):
            print("     tex   %-14s %s" % (lbl, path))
            per_tex[path] += 1
        for lbl, (ty, val) in sorted(r["params"].items()):
            print("     const %-14s %-10s %s" % (lbl, ty, val))
    print("=" * 76)
    print("%d/%d layer keys resolved in the depot" % (resolved, n))
    ntex = sum(1 for i in range(n))
    print("distinct textures bound across all layers: %d" % len(per_tex))
    for p, c in per_tex.most_common():
        print("   x%d  %s" % (c, p))


if __name__ == "__main__":
    main()
