"""MP_FireStorm chunk decomposition — the verification row for detect_layout.

For every streaming chunk (primary and paired), decompose

    size = heightPrefix + storedPages * PAGE + trailer

with heightPrefix drawn from sums of {0, 39919, 149297, 189216} (MAP-TUNGSTEN.md
C1) and PAGE = 4356 (the derived per-map table; firestorm is in the 4356 set).

The trailer is decided by EVIDENCE, not by size arithmetic: 17,424 = 4 x 4,356,
so any k x 17,424 "tile" also decomposes as 4k raw pages and size alone cannot
tell them apart (bf6_colormap.py's header makes the same point). The rule used
here: if the LAST 67,600 bytes of the chunk pass the BC7 mode test (>= 90%
modes 4-7), the trailer is one 260^2 colour tile; otherwise the chunk is pages
only. MEASURED on firestorm: every depth>=2 primary chunk passes at exactly
100%, every depth 0/1 primary and every paired chunk fails at < 5%, so the rule
has no marginal cases on this map.

Usage:  probe_firestorm_decomp.py [level] [--page N]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PREFIXES = [0, 39919, 149297, 189216]
TILE = 67600                          # 260^2 BC7, firestorm's colour tile


def height_prefixes(max_terms=3):
    """All sums of up to max_terms prefix values (with repetition)."""
    sums = {0}
    for _ in range(max_terms):
        sums |= {s + p for s in sums for p in PREFIXES}
    return sorted(sums)


def frac47(buf):
    """% of 16-byte blocks in BC7 modes 4-7 (byte0 nonzero, low nibble 0)."""
    tot = hi = 0
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        tot += 1
        if b and not (b & 0x0F):
            hi += 1
    return 100.0 * hi / tot if tot else 0.0


def decompose(size, page, tail_is_tile):
    """[(prefix, pages, trailer)] exact decompositions given the tile verdict."""
    out = []
    tr = TILE if tail_is_tile else 0
    for pre in height_prefixes():
        body = size - pre - tr
        if body >= 0 and body % page == 0:
            out.append((pre, body // page, tr))
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_firestorm"
    page = int(sys.argv[sys.argv.index("--page") + 1]) if "--page" in sys.argv \
        else 4356
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)

    by_form = collections.Counter()
    fracs = []
    unsolved = []
    pagestats = collections.Counter()
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                continue
            buf = C.read(p)
            size = len(buf)
            f = frac47(buf[-TILE:]) if size >= TILE else 0.0
            tile = f >= 90.0
            fracs.append((which, n["depth"], f))
            dec = decompose(size, page, tile)
            if len(dec) != 1:
                unsolved.append((which, n["key"], n["depth"], size, len(dec)))
                if not dec:
                    continue
            pre, pages, tr = dec[0]
            by_form[(which, n["depth"], pre, tr)] += 1
            pagestats[pages] += 1

    print("%s: PAGE=%d, %d chunk directory nodes" % (level, page, len(nodes)))
    print("%-8s %-6s %-9s %-8s %s" % ("kind", "depth", "prefix", "trailer", "count"))
    for (which, depth, pre, tr), cnt in sorted(by_form.items()):
        print("%-8s %-6d %-9d %-8d x%d" % (which, depth, pre, tr, cnt))
    print("stored pages per chunk: min %d max %d" % (min(pagestats), max(pagestats)))
    amb = [u for u in unsolved if u[4] > 1]
    fail = [u for u in unsolved if u[4] == 0]
    print("ambiguous decompositions: %d, unsolvable: %d" % (len(amb), len(fail)))
    for u in (amb + fail)[:20]:
        print("   %s key 0x%X depth %d size %d (%d forms)" % u)
    tiles = [f for w, dep, f in fracs if f >= 90]
    non = [f for w, dep, f in fracs if f < 90]
    print("tail-tile verdicts: %d tiles (min %.1f%% m4-7), %d non-tiles (max %.1f%%)"
          % (len(tiles), min(tiles) if tiles else 0,
             len(non), max(non) if non else 0))


if __name__ == "__main__":
    main()
