"""MP_Eastwood's chunk decomposition table -- the detect_layout verification row.

For every streaming chunk (primary and paired) of a level, find the exact
decomposition

    size = heightPrefix + storedPages * PAGE + k * TILE

with heightPrefix a sum of 0..2 elements of {39919, 149297, 189216} (the known
height-payload sizes, MAP-TUNGSTEN.md C1), PAGE in {2592, 4356, 5184} and TILE
in {4624, 17424}. A candidate (PAGE, TILE) survives only if EVERY chunk of the
level decomposes exactly (residual 0); the table of distinct
(size -> prefix + pages*PAGE + k*TILE) rows is printed for the winner.

Then the BC7 mode-byte histogram (probe_tung_colormap.bc7_modes) of the FIRST
and LAST tile of each primary trailer, pooled over all primary chunks -- the
mode test that identifies which tile is the colour raster (a real colour tile
is dominated by modes 4-7).

READ-ONLY.  Usage:  probe_eastwood_decomp.py [level]
"""
import collections
import itertools
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

HEIGHT_PAYLOADS = [39919, 149297, 189216]
PAGES = [2592, 4356, 5184]
# 4624 = 68^2 BC7, 17424 = 132^2, 67600 = 260^2, 85024 = 260^2 + 132^2 mip pair
# (bf6_colormap.TILE_SIZES). On eastwood the depth<=4 interior chunks carry the
# 85,024-byte mip-pair trailer -- found empirically by the BC7 mode scan of
# chunk 0x302, whose clean modes-4-7 region spans exactly [-85024, -16112).
TILES = [4624, 17424, 85024]
MAX_K = 8


def prefixes():
    """0, each payload, and every sum of two (with repetition)."""
    out = {0}
    for a in HEIGHT_PAYLOADS:
        out.add(a)
        for b in HEIGHT_PAYLOADS:
            out.add(a + b)
    return sorted(out)


PREFIXES = prefixes()


def decompose(size, page, tile):
    """All exact (prefix, pages, k) for this size; [] when none."""
    outs = []
    for pre in PREFIXES:
        rest0 = size - pre
        if rest0 < 0:
            continue
        for k in range(0, MAX_K + 1):
            rest = rest0 - k * tile
            if rest < 0:
                break
            if rest % page == 0:
                outs.append((pre, rest // page, k))
    return outs


def decompose_any(size, page):
    """All exact (prefix, pages, k, tile) across the tile-size catalogue."""
    outs = []
    for tile in TILES:
        for pre, pages, k in decompose(size, page, tile):
            if k == 0 and tile != TILES[0]:
                continue            # k=0 rows are tile-independent; keep one
            outs.append((pre, pages, k, tile))
    return outs


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_eastwood"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)

    chunks = []                     # (which, key, depth, size, path)
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                continue
            real = os.path.getsize(p)
            chunks.append((which, n["key"], n["depth"], real, p,
                           real == declared))
    print("%s: %d chunks on disk (%d primary, %d paired), sizes match dir: %s"
          % (level, len(chunks),
             sum(1 for c in chunks if c[0] == "primary"),
             sum(1 for c in chunks if c[0] == "paired"),
             all(c[5] for c in chunks)))

    # --- which page size decomposes EVERY chunk exactly (any tile size) ------
    print("\ncandidate page -> chunks decomposed exactly / total "
          "(trailer = k x tile, tile in %s)" % TILES)
    winners = []
    for page in PAGES:
        ok = sum(1 for _w, _k, _d2, size, _p, _m in chunks
                 if decompose_any(size, page))
        flag = ""
        if ok == len(chunks):
            winners.append(page)
            flag = "   <- exact on ALL"
        print("   page %4d   %4d / %d%s" % (page, ok, len(chunks), flag))
    if not winners:
        print("\nNO page size decomposes every chunk -- decomposition failed")
        return

    # --- the distinct-size table for each winning page size ------------------
    for page in winners:
        print("\ndecomposition table for page=%d "
              "(distinct sizes; prefix + pages*page + k*tile):" % page)
        rows = collections.Counter()
        multi = 0
        for which, _key, depth, size, _p, _m in chunks:
            decs = decompose_any(size, page)
            if len(decs) > 1:
                multi += 1
            rows[(which, size, tuple(sorted(decs)))] += 1
        for (which, size, decs), cnt in sorted(rows.items(),
                                               key=lambda kv: (kv[0][0], -kv[1])):
            ds = ";  ".join("pre=%d pages=%d k=%d tile=%d" % t for t in decs)
            print("   %-7s size %8d  x%3d   %s" % (which, size, cnt, ds))
        print("   chunks with more than one exact decomposition: %d" % multi)

    # --- BC7 mode histogram, first vs last tile of the primary trailer -------
    page = winners[0]
    first_h = collections.Counter()
    last_h = collections.Counter()
    ks = collections.Counter()
    for which, _key, depth, size, p, _m in chunks:
        if which != "primary":
            continue
        decs = decompose_any(size, page)
        if not decs:
            continue
        # prefer the largest trailer (k*tile), i.e. the maximal colour region
        pre, pages, k, tile = max(decs, key=lambda t: t[2] * t[3])
        ks[(k, tile)] += 1
        if k == 0:
            continue
        buf = C.read(p)
        toff = len(buf) - k * tile
        first_h.update(M.bc7_modes(buf[toff:toff + tile]))
        last_h.update(M.bc7_modes(buf[len(buf) - tile:]))
    print("\nprimary trailer (k, tile) histogram: %s" % dict(sorted(ks.items())))
    for tag, h in (("first", first_h), ("last", last_h)):
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        print("   %-5s tile pooled: %7d blocks  modes4-7 %5.1f%%   %s"
              % (tag, tot, 100.0 * hi / tot if tot else 0,
                 ", ".join("m%s:%d" % (m, c) for m, c in
                           sorted(h.items(), key=lambda kv: -kv[1])[:6])))


if __name__ == "__main__":
    main()
