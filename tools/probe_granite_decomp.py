"""THE DECOMPOSITION TABLE for the eight Granite levels, plus the chunk-GUID
overlap between them (the cache-sharing question).

For every level: page size (residue-class method + exact decomposition),
height prefixes, trailer tile decomposition, BC7 mode histogram of the first
vs last tile.  Then: |chunk GUID set| per level and pairwise intersections.

Usage:  probe_granite_decomp.py [slug ...]        default: all eight
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_granite_common as G     # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

C = G.C
PAGE_CANDS = [2592, 4356, 5184]
TILE_CANDS = [4624, 17424]
# height prefixes seen on other maps plus 0; sums of two occur (tungsten).
PREFIX_BASE = [0, 39919, 149297, 189216]


def level_chunks(slug):
    td = G.terr_dir(slug)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = M.chunk_dir(d, after)
    return d, hdr, blocks, nodes


def bc7_hist(buf):
    h = collections.Counter()
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        if b == 0:
            h[-1] += 1
            continue
        m = 0
        while not (b >> m) & 1:
            m += 1
        h[m] += 1
    return h


def pct47(h):
    t = sum(h.values())
    return 100.0 * sum(c for m, c in h.items() if m >= 4) / t if t else 0.0


def decompose(size, prefixes, ps, tiles):
    """all (prefix, npages, ktiles, tile) with exact zero residual, k<=8."""
    out = []
    for p in prefixes:
        if p > size:
            continue
        for tile in tiles:
            for k in range(0, 9):
                rest = size - p - k * tile
                if rest < 0:
                    break
                if rest % ps == 0:
                    out.append((p, rest // ps, k, tile))
    return out


def main():
    slugs = [a for a in sys.argv[1:] if not a.startswith("-")] or \
        (["base"] + G.SLUGS)
    # prefix set incl. sums of two
    prefixes = sorted(set(a + b for a in PREFIX_BASE for b in PREFIX_BASE))

    guid_sets = {}
    for slug in slugs:
        d, hdr, blocks, nodes = level_chunks(slug)
        print("=" * 78)
        print("%s  tree %d B  NodeCount=%d  dirNodes=%d  blocks: %s"
              % (G.LEVEL_NAMES[slug], len(d), hdr["NodeCount"], len(nodes),
                 ", ".join("t%d(%d)" % (t, s) for t, _o, s in blocks)))

        prim = [(n["key"], n["depth"], n["g0"], n["size0"]) for n in nodes]
        guid_sets[slug] = set(n["g0"] for n in nodes) | \
            set(n["g1"] for n in nodes if n["g1"])

        # residue-class scan -> page size
        for ps in PAGE_CANDS:
            res = collections.Counter(sz % ps for _k, _d, _g, sz in prim if sz)
            print("   ps %4d -> %2d residue classes  %s"
                  % (ps, len(res), sorted(res.items(),
                                          key=lambda kv: -kv[1])[:6]))

        # exact decomposition with the winning page size = fewest classes
        best_ps = min(PAGE_CANDS, key=lambda ps: len(
            set(sz % ps for _k, _d, _g, sz in prim if sz)))
        shapes = collections.Counter()
        undec = 0
        for _k, _dep, _g, sz in prim:
            if not sz:
                continue
            cands = decompose(sz, prefixes, best_ps, TILE_CANDS)
            if not cands:
                undec += 1
                continue
            # prefer: fewest prefix bytes unexplained -> largest prefix, then
            # smallest k (trailer tiles), consistent reporting only
            p, npg, k, tile = sorted(cands, key=lambda c: (-c[0], c[2]))[0]
            shapes[(p, k, tile)] += 1
        print("   page %d: shapes (prefix, ktiles, tile) -> count   undecomposed=%d"
              % (best_ps, undec))
        for (p, k, tile), n in sorted(shapes.items(), key=lambda kv: -kv[1]):
            print("      prefix %6d + pages x %d + %d x %d   x%d"
                  % (p, best_ps, k, tile, n))

        # BC7 mode test on the dominant trailer shape
        if shapes:
            (p, k, tile), _n = max(shapes.items(), key=lambda kv: kv[1])
            if k > 0:
                firsts = collections.Counter()
                lasts = collections.Counter()
                seen = 0
                for _kk, _dep, g, sz in prim:
                    if not sz:
                        continue
                    if not decompose(sz, [p], best_ps, [tile]):
                        continue
                    pa = M.chunk_path(g)
                    if not os.path.isfile(pa):
                        continue
                    buf = C.read(pa)
                    trailer = buf[len(buf) - k * tile:]
                    firsts.update(bc7_hist(trailer[:tile]))
                    lasts.update(bc7_hist(trailer[-tile:]))
                    seen += 1
                    if seen >= 60:
                        break
                print("   BC7 over %d chunks: first tile modes4-7 %.1f%%  %s"
                      % (seen, pct47(firsts),
                         sorted(firsts.items(), key=lambda kv: -kv[1])[:4]))
                print("                       last  tile modes4-7 %.1f%%  %s"
                      % (pct47(lasts),
                         sorted(lasts.items(), key=lambda kv: -kv[1])[:4]))

    if len(slugs) > 1:
        print("=" * 78)
        print("chunk-GUID overlap (terrain streaming chunks)")
        for s in slugs:
            print("   %-16s %5d guids" % (s, len(guid_sets[s])))
        for i, a in enumerate(slugs):
            for b in slugs[i + 1:]:
                inter = len(guid_sets[a] & guid_sets[b])
                print("   %-16s & %-16s  shared %5d  (%.1f%% of smaller)"
                      % (a, b, inter,
                         100.0 * inter / min(len(guid_sets[a]),
                                             len(guid_sets[b]))))


if __name__ == "__main__":
    main()
