"""MP_Abbasid chunk decomposition — the detect_layout verification row.

For every streaming chunk (primary and paired), decompose

    size = heightPrefix + N x 4356

with heightPrefix drawn from the established set {0, 39919, 149297, 189216}
plus sums of two (MAP-TUNGSTEN.md C1).  4,356 bytes is both the raw 66x66
weight-page size on this map family AND a quarter of the 17,424-byte 132x132
BC7 colour tile (17,424 = 4 x 4,356), so N = storedPages + 4*k tiles.

The trailer's tile count is then pinned two ways:
  * the MINIMUM N per prefix class (a chunk with zero stored pages exposes the
    bare trailer), and
  * the BC7 mode histogram of each candidate 17,424-byte tile from the chunk
    end (a real colour tile decodes ~100%% modes 4-7; a degenerate second
    raster is mode-0-3 dominated -- MAP-TUNGSTEN.md C2).

Usage:  probe_abbasid_decomp.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PS = 4356
TILE = 17424
PREFIXES = [0, 39919, 149297, 189216,
            2 * 39919, 2 * 149297, 2 * 189216,
            39919 + 149297, 39919 + 189216, 149297 + 189216]


def decompose(size):
    """-> (prefix, N) with size == prefix + N*PS, or None."""
    out = []
    for p in PREFIXES:
        if size >= p and (size - p) % PS == 0:
            out.append((p, (size - p) // PS))
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_abbasid"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)
    print("%s: %d directory nodes" % (level, len(nodes)))

    classes = collections.Counter()          # (which, prefix, N)
    ambiguous = 0
    sizes = {}
    for n in nodes:
        for which, g, dec in (("primary", n["g0"], n["size0"]),
                              ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                continue
            size = os.path.getsize(p)
            assert size == dec, (n["key"], which, size, dec)
            ds = decompose(size)
            if not ds:
                classes[(which, "NO-DECOMP size=%d" % size, -1)] += 1
                continue
            if len(ds) > 1:
                ambiguous += 1
            pfx, N = ds[0]                   # smallest prefix wins the report
            classes[(which, pfx, N)] += 1
            sizes.setdefault((which, pfx), []).append(N)

    print("\n-- decomposition size = prefix + N x %d  (%d ambiguous of prefix set)" % (PS, ambiguous))
    for (which, pfx, N), c in sorted(classes.items(), key=lambda kv: (kv[0][0], kv[0][2])):
        print("   %-8s prefix %-8s N=%-4s x%d" % (which, pfx, N, c))
    for (which, pfx), Ns in sorted(sizes.items()):
        print("   %-8s prefix %-8s N min=%d max=%d" % (which, pfx, min(Ns), max(Ns)))

    # BC7 mode test on candidate trailing tiles
    print("\n-- BC7 mode histogram per trailing %d-byte tile (last 3 candidates)" % TILE)
    agg = collections.defaultdict(collections.Counter)
    for n in nodes:
        for which, g in (("primary", n["g0"]), ("paired", n["g1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                continue
            buf = C.read(p)
            for t in range(3):
                a = len(buf) - (t + 1) * TILE
                if a < 0:
                    break
                agg[(which, t)].update(M.bc7_modes(buf[a:a + TILE]))
    for (which, t), h in sorted(agg.items()):
        tot = sum(h.values())
        hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
        print("   %-8s tile[-%d]  %7d blocks  modes4-7 %5.1f%%  %s"
              % (which, t + 1, tot, 100.0 * hi / tot if tot else 0,
                 ", ".join("m%s:%d" % (m, c) for m, c in
                           sorted(h.items(), key=lambda kv: -kv[1])[:5])))


if __name__ == "__main__":
    main()
