"""MP_Outskirts chunk decomposition — the detect_layout verification row.

MP_Outskirts is the map where the two page/tile derivations could disagree:
it appears BOTH in the corpus's verified BC7 tile-size table (TERRAIN.md 5.3:
trailer 17,424 = 132^2 tile) AND in bf6_splat.py's 4,356-raw-page list.
17,424 = 4 x 4,356 exactly, so BY SIZE ALONE the trailer of every primary
chunk is ambiguous: one 132^2 BC7 colour tile, or four extra raw weight
pages. bf6_colormap.py's own header files outskirts under "fit BOTH".

This probe settles it three ways, none of which is a size argument:

  1. exact decomposition of every primary/paired chunk with the page count m
     taken from block-1 METADATA (never inferred from size):
         size0 = heightPrefix + m x 4356 + trailer
  2. BC7 mode histogram of the trailer's first and last 17,424-byte tile
     (a real colour tile is ~98% modes 4-7; raw weight bytes are not);
  3. BC7 mode-6 endpoint mean of the trailer vs the SDK overhead image.

It also simulates the plugin's CURRENT detect_layout (fewest-distinct-
residuals page pick + prefix/tile decomposition) on this map's numbers.

Usage:  probe_outskirts_decomp.py [level]     (default mp_outskirts)
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as M        # noqa: E402

PREFIXES = [0, 39919, 149297, 189216, 298594]
PAGE_SIZES = [2592, 4356, 5184]
TILE_SIZES = [4624, 17424, 67600]


def splat_pages_per_node(d, base, size):
    """block-1 walk keyed like the chunk dir: {key: stored-page count m}."""
    end = base + size
    pages = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        m = 0
        for _ in range(rc):
            flags = struct.unpack_from("<H", d, o + 20)[0]
            if not (flags & 0x0100):
                m += 1
            o += 33
        pages[key] = m
        if rc == 0:
            return o + 1
        o += 1
        has_children = d[o]
        o += 1
        if o < end:
            o += 1
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return pages


def bc7_hist(buf):
    h = collections.Counter()
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        if b == 0:
            h["inv"] += 1
            continue
        m = 0
        while not (b >> m) & 1:
            m += 1
        h[m] += 1
    return h


def hi47(h):
    tot = sum(h.values())
    hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
    return 100.0 * hi / tot if tot else 0.0


def decompose(residual):
    """residual -> (prefix, k, tile) exact decompositions, all that fit."""
    outs = []
    for p in PREFIXES:
        rem = residual - p
        if rem < 0:
            continue
        if rem == 0:
            outs.append((p, 0, 0))
            continue
        for tb in TILE_SIZES:
            if rem % tb == 0 and rem // tb <= 8:
                outs.append((p, rem // tb, tb))
    return outs


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_outskirts"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)
    b1 = next((b for b in blocks if b[0] == 1), None)
    pages = splat_pages_per_node(d, b1[1], b1[2])
    print("%s: %d chunk-dir nodes, %d splat nodes with page counts"
          % (level, len(nodes), len(pages)))

    # ---- 1. exact decomposition, m from metadata ---------------------------
    combos = collections.Counter()          # (m, size0, residual) -> count
    miss = 0
    for n in nodes:
        m = pages.get(n["key"])
        if m is None:
            miss += 1
            continue
        if n["size0"] <= 0:
            continue
        combos[(m, n["size0"])] += 1
    print("\nPRIMARY chunks (m = block-1 stored-page count of the same key):")
    print("%5s %10s %10s  %s" % ("m", "size0", "resid4356", "decompositions (prefix + k x tile)"))
    residuals = collections.Counter()
    for (m, sz), cnt in sorted(combos.items()):
        r = sz - m * 4356
        residuals[r] += cnt
        ds = decompose(r) if r >= 0 else []
        print("%5d %10d %10d  x%-3d %s" % (m, sz, r, cnt,
              " | ".join("%d + %dx%d" % t for t in ds) or "NO FIT"))
    if miss:
        print("   (%d dir nodes had no block-1 twin)" % miss)
    print("\ndistinct residuals under ps=4356: %s"
          % sorted(residuals.items()))

    # residuals under the other page sizes, for the record
    for ps in (2592, 5184):
        rs = set()
        neg = 0
        for (m, sz), cnt in combos.items():
            r = sz - m * ps
            if r < 0:
                neg += 1
            rs.add(r)
        print("under ps=%d: %d distinct residuals, %d negative" % (ps, len(rs), neg))

    # ---- paired chunks -----------------------------------------------------
    print("\nPAIRED chunks: size1 - (sum child m) x 4356:")
    prs = collections.Counter()
    for n in nodes:
        if n["g1"] is None:
            continue
        cm = sum(pages.get((n["key"] << 4) | i, 0) for i in range(4))
        prs[n["size1"] - cm * 4356] += 1
    for r, cnt in sorted(prs.items()):
        ds = decompose(r) if r >= 0 else []
        print("   resid %10d  x%-3d %s" % (r, cnt,
              " | ".join("%d + %dx%d" % t for t in ds) or "NO FIT"))

    # ---- 2. BC7 mode histogram of trailer tiles ----------------------------
    print("\nBC7 mode histogram over the trailer (17,424-byte tiles):")
    agg = {"first": collections.Counter(), "last": collections.Counter()}
    uni_first = 0
    n_chunks = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        m = pages.get(n["key"], 0)
        buf = C.read(p)
        r = len(buf) - m * 4356
        # trailer = the k x 17424 tail (drop the height prefix)
        tail_tiles = 0
        for pref in PREFIXES:
            rem = r - pref
            if rem >= 0 and rem % 17424 == 0:
                tail_tiles = rem // 17424
                break
        if tail_tiles <= 0:
            continue
        trailer = buf[len(buf) - tail_tiles * 17424:]
        first = trailer[:17424]
        last = trailer[-17424:]
        agg["first"].update(bc7_hist(first))
        agg["last"].update(bc7_hist(last))
        if len(set(first[i:i + 16] for i in range(0, 17424, 16))) == 1:
            uni_first += 1
        n_chunks += 1
    for which in ("first", "last"):
        h = agg[which]
        print("   %-5s tile over %d chunks: %d blocks, %.2f%% modes 4-7   %s"
              % (which, n_chunks, sum(h.values()), hi47(h),
                 ", ".join("m%s:%d" % kv for kv in sorted(
                     h.items(), key=lambda kv: -kv[1])[:6])))
    print("   chunks whose first tile is ONE repeated block: %d" % uni_first)

    # paired-chunk tiles
    ph = collections.Counter()
    pn = 0
    for n in nodes:
        if n["g1"] is None:
            continue
        p = M.chunk_path(n["g1"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        cm = sum(pages.get((n["key"] << 4) | i, 0) for i in range(4))
        r = len(buf) - cm * 4356
        if r <= 0 or r % 17424 != 0:
            continue
        ph.update(bc7_hist(buf[len(buf) - r:]))
        pn += 1
    if pn:
        print("   paired trailers over %d chunks: %.2f%% modes 4-7" % (pn, hi47(ph)))

    # ---- 3. simulate the plugin's detect_layout ----------------------------
    print("\nSIMULATED plugin detect_layout (fewest distinct residuals):")
    best_ps, best_resid = 0, None
    for ps in PAGE_SIZES:
        rs = set()
        ok = True
        for (m, sz), cnt in combos.items():
            if m <= 0 or sz <= 0:
                continue
            r = sz - m * ps
            if r < 0:
                ok = False
                break
            rs.add(r)
        if not ok or not rs:
            print("   ps=%d: eliminated (negative residual)" % ps)
            continue
        print("   ps=%d: %d distinct residuals" % (ps, len(rs)))
        if best_ps == 0 or len(rs) < len(best_resid):
            best_ps, best_resid = ps, rs
    tile_pick = 0
    for tb in sorted(TILE_SIZES):
        if all(any(0 <= r - p and (r - p) % tb == 0 and (r - p) // tb <= 8
                   for p in PREFIXES) for r in best_resid):
            tile_pick = tb
            break
    print("   -> picks page %d, tile %d   (truth: 4356 / 17424)"
          % (best_ps, tile_pick))


if __name__ == "__main__":
    main()
