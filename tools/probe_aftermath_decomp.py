"""MP_Aftermath's chunk decomposition table -- the detect_layout verification row.

Establishes, for every streaming chunk of the level:

    size = heightPrefix + pages x PAGE + trailer

with PAGE the map's true weight-page size and trailer = k x tile_bytes. The
fleet brief's derived table says mp_aftermath is a PAGE=2592 map with a
17,424-byte trailer = one 132^2 BC7 tile (132 x 132 texels at 1 B/texel).
This probe confirms that by exact decomposition (zero residual required) and
by the BC7 mode-byte histogram (a real colour tile decodes ~100% modes 4-7;
weight-page bytes read as BC7 do not).

Height prefixes are whole heightfield node payloads; with xs=265 the inline
payload is 149,297 bytes (see probe_tung_terrain.hf_walk sizes), and a chunk
can carry more than one. 39,919 / 189,216 are the analogous payloads on other
xs values (brief's prefix set) and are tried too.

Usage:  probe_aftermath_decomp.py [level] [--page 2592]
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
TILES = [4624, 17424, 67600, 85024]


def decompose(size, page):
    """All exact decompositions (prefix_terms, pages, tile_bytes, k)."""
    outs = []
    # up to 3 height payloads per chunk (tungsten measured 2x149297)
    pre = set()
    for a in PREFIXES:
        for b in PREFIXES:
            for c in PREFIXES:
                pre.add(a + b + c)
    for h in sorted(pre):
        if h > size:
            continue
        rest = size - h
        for t in TILES:
            for k in range(0, 8):
                r2 = rest - k * t
                if r2 < 0:
                    break
                if r2 % page == 0:
                    outs.append((h, r2 // page, t, k))
    return outs


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
    tot = sum(h.values())
    return 100.0 * sum(c for m, c in h.items() if m >= 4) / tot if tot else 0.0


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_aftermath"
    page = int(sys.argv[sys.argv.index("--page") + 1]) if "--page" in sys.argv else 2592

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = M.chunk_dir(d, after)
    print("%s: %d directory nodes, chunk dir consumed %d/%d bytes"
          % (level, len(nodes), end, len(d)))

    sizes = collections.Counter()
    missing = 0
    for n in nodes:
        for which, g, sz in (("primary", n["g0"], n["size0"]),
                             ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                missing += 1
                continue
            real = os.path.getsize(p)
            sizes[(which, real)] += 1
            if real != sz:
                print("  MISMATCH %s node 0x%X declared %d on-disk %d"
                      % (which, n["key"], sz, real))
    print("%d chunk files missing on disk" % missing)

    print("\ndistinct chunk sizes and their exact decompositions (page=%d):" % page)
    amb = 0
    for (which, sz), cnt in sorted(sizes.items(), key=lambda kv: (kv[0][0], -kv[1])):
        outs = decompose(sz, page)
        # prefer: fewest tiles absorbed as pages -> report all
        txt = "; ".join("h=%d pages=%d tile=%d k=%d" % o for o in outs[:4])
        if len(outs) > 4:
            txt += " (+%d more)" % (len(outs) - 4)
        if len(outs) != 1:
            amb += 1
        print("  %-7s %9d B x%-3d  -> %s" % (which, sz, cnt, txt if outs else "NO DECOMPOSITION"))
    print("(%d sizes with non-unique decomposition)" % amb)

    # BC7 mode histograms over ALL primary chunks: trailing tile vs the bytes
    # immediately before it (should NOT be a colour tile if k == 1).
    tile = 17424
    h_last = collections.Counter()
    h_prev = collections.Counter()
    n_last = n_prev = 0
    uniform_last = 0
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < tile:
            continue
        last = buf[-tile:]
        h_last.update(bc7_hist(last))
        n_last += 1
        blocks_set = {bytes(last[i:i + 16]) for i in range(0, tile, 16)}
        if len(blocks_set) == 1:
            uniform_last += 1
        if len(buf) >= 2 * tile:
            h_prev.update(bc7_hist(buf[-2 * tile:-tile]))
            n_prev += 1
    print("\nBC7 mode histogram, %d primary chunks:" % n_last)
    print("  LAST %d bytes   modes4-7 %5.2f%%  %s  (%d/%d nodes single-block-uniform)"
          % (tile, pct47(h_last),
             dict(sorted(h_last.items(), key=lambda kv: -kv[1])[:6]),
             uniform_last, n_last))
    print("  PREV %d bytes   modes4-7 %5.2f%%  %s   (over %d chunks)"
          % (tile, pct47(h_prev),
             dict(sorted(h_prev.items(), key=lambda kv: -kv[1])[:6]), n_prev))


if __name__ == "__main__":
    main()
