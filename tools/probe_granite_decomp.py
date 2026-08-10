"""Chunk-GUID overlap between the eight Granite levels, plus raw residue-class
scans per candidate page size.

This is the cache-sharing question: the eight levels are eight bakes of ONE
world, so if they shared terrain chunks a plugin could share decoded caches.
MEASURED ANSWER: they share essentially nothing — 0 or 1 chunk GUIDs in common
between any pair (the 1 is a degenerate chunk shared by the six portal city
slices). Placement partitions are likewise re-minted per level (every partition
GUID differs even for byte-similar same-named files).

For the per-node EXACT decomposition (page size, height prefixes, trailer
tiles) use probe_granite_layout.py, which joins block-1 storedPageCount per
node instead of guessing.

Usage:  probe_granite_decomp.py [slug ...]        default: all eight
"""
import collections
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

C = G.C
PAGE_CANDS = [2592, 4356, 5184]


def main():
    slugs = [a for a in sys.argv[1:] if not a.startswith("-")] or \
        (["base"] + G.SLUGS)
    guid_sets = {}
    for slug in slugs:
        td = G.terr_dir(slug)
        d = C.read(T._res(td, ".TerrainStreamingTree"))
        hdr, blocks, after = T.container(d)
        nodes, _end = M.chunk_dir(d, after)
        guid_sets[slug] = set(n["g0"] for n in nodes if n["g0"]) | \
            set(n["g1"] for n in nodes if n["g1"])
        print("=" * 78)
        print("%s  tree %d B  dirNodes=%d  guids=%d"
              % (G.LEVEL_NAMES[slug], len(d), len(nodes), len(guid_sets[slug])))
        prim = [n["size0"] for n in nodes if n["size0"]]
        for ps in PAGE_CANDS:
            res = collections.Counter(sz % ps for sz in prim)
            print("   ps %4d -> %3d residue classes  top: %s"
                  % (ps, len(res),
                     sorted(res.items(), key=lambda kv: -kv[1])[:5]))

    if len(slugs) > 1:
        print("=" * 78)
        print("chunk-GUID overlap (terrain streaming chunks)")
        for i, a in enumerate(slugs):
            for b in slugs[i + 1:]:
                inter = len(guid_sets[a] & guid_sets[b])
                if inter:
                    print("   %-16s & %-16s  shared %d" % (a, b, inter))
        print("   (pairs not listed share zero)")


if __name__ == "__main__":
    main()
