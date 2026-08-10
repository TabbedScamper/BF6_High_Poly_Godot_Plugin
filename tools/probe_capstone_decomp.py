"""MP_Capstone's chunk decomposition table -- the verification row for the
detect_layout fix (MAP-TUNGSTEN.md G1).

For every streaming chunk (primary and paired) of a level, decompose

    size = heightPrefix + N x 4356 + trailer

where heightPrefix is drawn from the established set {0, 39919, 149297, 189216}
plus sums of two (MAP-TUNGSTEN.md C1), identified by the size's residue class
mod 4356 (all prefix candidates have distinct residues; pages and BC7 tiles are
both multiples of 4356, since 17424 = 4 x 4356 and 4624 is handled separately).

The trailer's tile count is then established empirically per chunk with the BC7
mode test (MAP-TUNGSTEN.md C2): walking 17,424-byte windows backwards from the
chunk end, a window is a colour tile iff >= 90% of its 16-byte blocks parse as
BC7 modes 4-7. Weight pages (BC4) and degenerate rasters fail that test.

Usage:  probe_capstone_decomp.py [level] [--page 4356] [--tile 17424]
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
# sums of two (tungsten ships 2x149297)
PREFIX_SET = {}
for a in PREFIXES:
    PREFIX_SET.setdefault(a % 4356, []).append((a, "%d" % a if a else "0"))
for a in PREFIXES[1:]:
    for b in PREFIXES[1:]:
        if a <= b:
            s = a + b
            PREFIX_SET.setdefault(s % 4356, []).append((s, "%d+%d" % (a, b)))


def mode_frac(buf):
    """fraction of 16-byte blocks in BC7 modes 4-7, and total blocks."""
    h = M.bc7_modes(buf)
    tot = sum(h.values())
    hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
    return (hi / tot if tot else 0.0), tot, h


def trailing_tiles(buf, tile):
    """count contiguous image-like tiles at the END of buf, walking backwards,
    and report each window's modes4-7 fraction (last window first)."""
    fr = []
    o = len(buf)
    while o - tile >= 0 and len(fr) < 8:
        f, _t, _h = mode_frac(buf[o - tile:o])
        fr.append(f)
        o -= tile
    return fr


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_capstone"
    page = int(sys.argv[sys.argv.index("--page") + 1]) if "--page" in sys.argv else 4356
    tile = int(sys.argv[sys.argv.index("--tile") + 1]) if "--tile" in sys.argv else 17424
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)
    print("%s: %d directory nodes, page=%d, tile=%d" % (level, len(nodes), page, tile))

    residues = collections.Counter()
    trailer_hist = collections.Counter()
    examples = {}
    missing = 0
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                missing += 1
                continue
            size = os.path.getsize(p)
            r = size % page
            cands = PREFIX_SET.get(r, [])
            label = cands[0][1] if cands else "UNMATCHED r=%d" % r
            residues[(which, size == declared, label)] += 1
            if (which, label) not in examples:
                examples[(which, label)] = (n["key"], size, p)

    print("-" * 74)
    print("residue classes (which, on-disk==declared, prefix decomposition):")
    for k, c in sorted(residues.items(), key=lambda kv: -kv[1]):
        print("   x%-4d %-8s sizeOK=%-5s prefix=%s" % (c, k[0], k[1], k[2]))
    print("   chunks missing on disk: %d" % missing)

    # full decomposition + BC7 trailer walk on every primary chunk
    print("-" * 74)
    print("trailer tile count by BC7 mode test over all primary chunks:")
    per_first = collections.Counter()
    agg_first = collections.Counter()
    agg_last = collections.Counter()
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        fr = trailing_tiles(buf, tile)
        k = 0
        for f in fr:
            if f >= 0.90:
                k += 1
            else:
                break
        trailer_hist[k] += 1
        if k:
            # first tile of the trailer = the deepest image-like window
            s = len(buf) - k * tile
            _f, _t, h = mode_frac(buf[s:s + tile])
            for m, c in h.items():
                agg_first[m] += c
            _f, _t, h = mode_frac(buf[len(buf) - tile:])
            for m, c in h.items():
                agg_last[m] += c
            per_first[len(buf) - s] += 1
    for k, c in sorted(trailer_hist.items()):
        print("   %d image-like trailing tile(s): x%d chunks" % (k, c))

    def fmt(h):
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        top = ", ".join("m%s:%d" % (m, c) for m, c in
                        sorted(h.items(), key=lambda kv: -kv[1])[:6])
        return "%d blocks, modes4-7 %.2f%%  %s" % (tot, 100.0 * hi / tot if tot else 0, top)

    print("   FIRST trailer tile pooled: %s" % fmt(agg_first))
    print("   LAST  trailer tile pooled: %s" % fmt(agg_last))

    # sample decomposition lines for the doc
    print("-" * 74)
    print("sample decompositions (primary):")
    shown = 0
    seen = set()
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        size = os.path.getsize(p)
        r = size % page
        cands = PREFIX_SET.get(r, [])
        pref = cands[0][0] if cands else None
        if pref is None:
            continue
        fr = trailing_tiles(C.read(p), tile)
        k = 0
        for f in fr:
            if f >= 0.90:
                k += 1
            else:
                break
        pages = (size - pref - k * tile) // page
        sig = (pref, k)
        if sig in seen and shown >= 12:
            continue
        seen.add(sig)
        shown += 1
        print("   node 0x%-8X depth %d  %8d = %6d + %3d x %d + %d x %d   frac=%s"
              % (n["key"], n["depth"], size, pref, pages, page, k, tile,
                 ["%.2f" % f for f in fr[:4]]))
        if shown > 24:
            break


if __name__ == "__main__":
    main()
