"""MP_Subsurface: exact chunk decomposition table (the detect_layout verification row).

For every streaming chunk (primary and paired) find the exact decomposition

    size = heightPrefix + pages * PAGE + k * TILE

over heightPrefix in {0, 39919, 149297, 189216} plus sums of two (MAP-TUNGSTEN.md
C1), candidate PAGE in {2592, 4356, 5184} and TILE in {4624, 17424}. A chunk
"decomposes" under (PAGE, TILE) if some (prefix, pages >= 0, k >= 0) hits the
size exactly. The true layout is the (PAGE, TILE) that decomposes every chunk;
the brief's derived table says MP_Subsurface should be page 2592.

Then, for the winning layout, print the distinct (prefix, pages, k) residual
classes and the BC7 mode histogram of the first vs last tile of the trailer.

Usage: probe_subsurface_decomp.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402

PREFIX1 = [0, 39919, 149297, 189216]
PREFIXES = sorted(set(a + b for a in PREFIX1 for b in PREFIX1))
PAGES = [2592, 4356, 5184]
TILES = [4624, 17424]


def decompose(size, page, tile, max_k=8):
    """-> (prefix, pages, k) or None. Prefer the largest prefix, then largest k
    (a trailer exists iff k>0; ambiguity is reported, not hidden)."""
    hits = []
    for pre in PREFIXES:
        rest = size - pre
        if rest < 0:
            continue
        for k in range(0, max_k + 1):
            r2 = rest - k * tile
            if r2 < 0:
                break
            if r2 % page == 0:
                hits.append((pre, r2 // page, k))
    return hits


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_subsurface"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = CM.chunk_dir(d, after)

    chunks = []          # (key, depth, which, size, path)
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = CM.chunk_path(g)
            if not os.path.isfile(p):
                continue
            chunks.append((n["key"], n["depth"], which, os.path.getsize(p), p))
    print("%s: %d chunks on disk (%d primary, %d paired)"
          % (level, len(chunks),
             sum(1 for c in chunks if c[2] == "primary"),
             sum(1 for c in chunks if c[2] == "paired")))

    # 1. which (page, tile) decomposes every chunk
    print("\n-- layout candidates (chunks decomposed exactly / total) --")
    for page in PAGES:
        for tile in TILES:
            ok = sum(1 for _, _, _, s, _ in chunks if decompose(s, page, tile))
            print("   page %4d tile %5d : %3d / %d" % (page, tile, ok, len(chunks)))

    # 2. residual classes under the winning layout (overridable)
    page = int(sys.argv[sys.argv.index("--page") + 1]) if "--page" in sys.argv else 2592
    tile = int(sys.argv[sys.argv.index("--tile") + 1]) if "--tile" in sys.argv else 4624
    print("\n-- decompositions under page %d, tile %d --" % (page, tile))
    classes = collections.Counter()
    ambiguous = 0
    for key, depth, which, s, p in chunks:
        hits = decompose(s, page, tile)
        if not hits:
            print("   NO DECOMPOSITION key 0x%X %s size %d" % (key, which, s))
            continue
        # canonical: largest prefix, then largest k
        best = sorted(hits, key=lambda h: (-h[0], -h[2]))[0]
        if len(set((h[0], h[2]) for h in hits)) > 1:
            ambiguous += 1
        classes[(which, depth, best)] += 1
    for (which, depth, (pre, pages, k)), n in sorted(classes.items()):
        print("   %-7s depth %d  prefix %6d + %3d x %d + %d x %d   x%d"
              % (which, depth, pre, pages, page, k, tile, n))
    print("   (%d chunks had multiple algebraic decompositions; canonical shown)"
          % ambiguous)

    # 3. BC7 mode histogram, first vs last tile of the trailer
    print("\n-- BC7 modes: first vs last trailer tile (canonical decomposition) --")
    agg = {"first": collections.Counter(), "last": collections.Counter()}
    for key, depth, which, s, p in chunks:
        hits = decompose(s, page, tile)
        if not hits:
            continue
        pre, pages, k = sorted(hits, key=lambda h: (-h[0], -h[2]))[0]
        if k == 0:
            continue
        buf = C.read(p)
        trailer = buf[len(buf) - k * tile:]
        agg["first"].update(CM.bc7_modes(trailer[:tile]))
        agg["last"].update(CM.bc7_modes(trailer[-tile:]))
    for tag in ("first", "last"):
        h = agg[tag]
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        print("   %-5s tile  %7d blocks  modes4-7 %5.1f%%  %s"
              % (tag, tot, 100.0 * hi / tot if tot else 0,
                 ", ".join("m%s:%d" % (m, c) for m, c in
                           sorted(h.items(), key=lambda kv: -kv[1])[:6])))


if __name__ == "__main__":
    main()
