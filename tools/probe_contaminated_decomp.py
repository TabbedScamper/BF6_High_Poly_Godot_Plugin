"""MP_Contaminated chunk decomposition — the detect_layout verification row.

For every streaming chunk of the level, decompose

    size = heightPrefix + storedPages * page_size + k * tile_bytes

over prefix set {0, 39919, 149297, 189216, and small sums thereof}, candidate
page sizes {2592, 4356, 5184} and candidate tile sizes {4624, 17424}, and report
which decomposition is exact.  Then run the BC7 mode histogram over the first
and last tile of the trailer (MAP-TUNGSTEN.md C2's test: a real colour tile is
~98%% modes 4-7).

READ-ONLY.  Usage:  probe_contaminated_decomp.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402
import probe_tung_terrain as T         # noqa: E402
import probe_tung_colormap as CM       # noqa: E402

PREFIX_BASE = [0, 39919, 149297, 189216]
PREFIXES = sorted({a + b for a in PREFIX_BASE for b in PREFIX_BASE} |
                  {a + b + c for a in PREFIX_BASE for b in PREFIX_BASE
                   for c in PREFIX_BASE})
PAGES = [2592, 4356, 5184]
TILES = [4624, 17424]


def decompose(size):
    """All exact decompositions of one chunk size."""
    out = []
    for ps in PAGES:
        for tb in TILES:
            for pre in PREFIXES:
                rest = size - pre
                if rest < 0:
                    continue
                # trailer = k*tb, pages*ps: enumerate k small
                for k in range(0, 9):
                    body = rest - k * tb
                    if body < 0:
                        break
                    if body % ps == 0:
                        out.append((ps, tb, pre, body // ps, k))
    return out


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_contaminated"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = CM.chunk_dir(d, after)
    print("%s: %d directory nodes" % (level, len(nodes)))

    sizes = collections.Counter()
    missing = 0
    for n in nodes:
        for which, g, declared in (("primary", n["g0"], n["size0"]),
                                   ("paired", n["g1"], n["size1"])):
            if g is None:
                continue
            p = CM.chunk_path(g)
            if not os.path.isfile(p):
                missing += 1
                continue
            real = os.path.getsize(p)
            if real != declared:
                print("  SIZE MISMATCH node 0x%X %s decl %d real %d"
                      % (n["key"], which, declared, real))
            sizes[(which, real)] += 1
    print("chunks on disk: %d primary-size-classes / %d paired, %d missing"
          % (len([k for k in sizes if k[0] == "primary"]),
             len([k for k in sizes if k[0] == "paired"]), missing))

    # ---- decompose each distinct size --------------------------------------
    for which in ("primary", "paired"):
        print("\n== %s chunk sizes ==" % which)
        for (w, size), cnt in sorted(sizes.items()):
            if w != which:
                continue
            decs = decompose(size)
            # prefer the minimal-prefix-count exact reading per (ps, tb)
            by = {}
            for ps, tb, pre, pages, k in decs:
                key = (ps, tb)
                cur = by.get(key)
                if cur is None or (k, pre) < (cur[3], cur[2]):
                    by[key] = (ps, tb, pre, pages, k)
            tags = []
            for (ps, tb), (ps_, tb_, pre, pages, k) in sorted(by.items()):
                tags.append("ps%d/tile%d: pre=%d pages=%d k=%d"
                            % (ps, tb, pre, pages, k))
            print("  size %9d  x%-3d  %s" % (size, cnt,
                                             " | ".join(tags) or "NO EXACT"))

    # ---- BC7 mode test on the trailer of primary chunks --------------------
    # for the winning hypothesis (2592-set map: single trailer tile 4624 like
    # dumbo, or two tiles) test both tile sizes.
    print("\n== BC7 mode census over primary trailers ==")
    for tb in TILES:
        agg_first = collections.Counter()
        agg_last = collections.Counter()
        tiles_per = collections.Counter()
        for n in nodes:
            g = n["g0"]
            if g is None:
                continue
            p = CM.chunk_path(g)
            if not os.path.isfile(p):
                continue
            size = os.path.getsize(p)
            decs = [x for x in decompose(size) if x[0] == 2592 and x[1] == tb]
            if not decs:
                continue
            decs.sort(key=lambda x: (x[4], x[2]))
            ps, tb_, pre, pages, k = decs[0]
            if k == 0:
                tiles_per[0] += 1
                continue
            tiles_per[k] += 1
            buf = C.read(p)
            trailer = buf[len(buf) - k * tb:]
            agg_first.update(CM.bc7_modes(trailer[:tb]))
            agg_last.update(CM.bc7_modes(trailer[-tb:]))
        def pct47(h):
            tot = sum(h.values())
            hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
            return 100.0 * hi / tot if tot else 0.0
        print("  tile %5d  k-histogram %s" % (tb, dict(tiles_per)))
        print("     first tile: %7d blocks  modes4-7 %5.1f%%  top %s"
              % (sum(agg_first.values()), pct47(agg_first),
                 sorted(agg_first.items(), key=lambda kv: -kv[1])[:4]))
        print("     last  tile: %7d blocks  modes4-7 %5.1f%%  top %s"
              % (sum(agg_last.values()), pct47(agg_last),
                 sorted(agg_last.items(), key=lambda kv: -kv[1])[:4]))

    # ---- simulate the plugin's detect_layout scoring -----------------------
    print("\n== detect_layout simulation (bf6_splat.gd scoring) ==")
    prim = [(sz, cnt) for (w, sz), cnt in sizes.items() if w == "primary"]
    best = None
    scores = []
    for ps in PAGES:
        for tb in TILES:
            score = sum(cnt for sz, cnt in prim
                        if sz - tb >= 0 and (sz - tb) % 1 == 0
                        and (sz - tb) >= 0)
            # the real scoring: rest = size - tile; pages = rest // ps; ok if >= 0
            score = sum(cnt for sz, cnt in prim if sz - tb >= 0)
            scores.append(((ps, tb), score))
    for k, s in sorted(scores, key=lambda kv: -kv[1]):
        print("   (page %d, tile %5d)  score %d" % (k[0], k[1], s))


if __name__ == "__main__":
    main()
