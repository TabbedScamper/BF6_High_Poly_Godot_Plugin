"""MP_Battery: the chunk decomposition table + the detect_layout verification row.

Mirrors the REWRITTEN bf6_splat.gd::detect_layout (fewest-distinct-residuals
page pick, then every residual must decompose as prefix + k x tile) against the
real per-node page counts from block 1, then reports:

  * the residual classes for the winning page size (the decomposition table);
  * BC7 mode histograms of the first vs last trailer tile (a colour tile is
    ~98% modes 4-7 -- MAP-TUNGSTEN.md C2);
  * paired-chunk trailer decomposition (children's tiles grouped first,
    reversed child order, per MAP-TUNGSTEN.md / bf6_colormap.py).

Usage:  probe_battery_decomp.py [level]      (default mp_battery)
"""
import collections
import itertools
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PAGE_CANDIDATES = [2592, 4356, 5184]
TILE_CANDIDATES = [4624, 17424, 67600]
BASE_PREFIX = [0, 39919, 149297, 189216]
PREFIXES = sorted({a + b for a, b in
                   itertools.combinations_with_replacement(BASE_PREFIX, 2)}
                  | set(BASE_PREFIX))


def splat_pages_per_node(d, base, size):
    """block-1 walk capturing per-node key -> stored page count (records
    WITHOUT the base bit 0x0100; those are the ones that ship a weight page)."""
    end = base + size
    pages = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        np = 0
        for _ in range(rc):
            flags = struct.unpack_from("<H", d, o + 20)[0]
            if not (flags & 0x0100):
                np += 1
            o += 33
        pages[key] = np
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


def tiles_in(residual, tb):
    best = None
    for p in PREFIXES:
        rem = residual - p
        if rem < 0 or rem % tb:
            continue
        k = rem // tb
        if k > 8:
            continue
        if best is None or k < best[0]:
            best = (k, p)
    return best  # (k, prefix) or None


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_battery"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _end = M.chunk_dir(d, after)
    pages = {}
    for t, off, size in blocks:
        if t == 1:
            pages = splat_pages_per_node(d, off, size)
    print("%s: %d directory nodes, %d splat nodes with page counts"
          % (level, len(nodes), len(pages)))

    # gather chunks
    prim = []       # (key, size, path, pagecount)
    paired = []
    missing = 0
    for n in nodes:
        for which, g, declared, store in (("primary", n["g0"], n["size0"], prim),
                                          ("paired", n["g1"], n["size1"], paired)):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                missing += 1
                continue
            real = os.path.getsize(p)
            assert real == declared, (n["key"], which, real, declared)
            if which == "primary":
                pc = pages.get(n["key"], 0)
            else:
                # paired chunk carries the FOUR children's pages
                pc = sum(pages.get((n["key"] << 4) | i, 0) for i in range(4))
            store.append((n["key"], real, p, pc))
    print("%d primary + %d paired chunks on disk (%d missing)"
          % (len(prim), len(paired), missing))

    # --- page-size pick, exactly as the rewritten detect_layout does --------
    print("\n== page size by fewest distinct residuals (primary chunks, pages > 0)")
    best = None
    for ps in PAGE_CANDIDATES:
        resid = set()
        ok = True
        for key, sz, _p, pc in prim:
            if pc <= 0:
                continue
            r = sz - pc * ps
            if r < 0:
                ok = False
                break
            resid.add(r)
        state = "ok, %d distinct residuals" % len(resid) if ok else "NEGATIVE residual"
        print("   page %5d  %s" % (ps, state))
        if ok and resid and (best is None or len(resid) < len(best[1])):
            best = (ps, resid)
    ps, resid = best
    print("   -> winner: page %d" % ps)

    # --- residual decomposition ----------------------------------------------
    print("\n== residual decomposition (page %d)" % ps)
    for tb in TILE_CANDIDATES:
        fits = {r: tiles_in(r, tb) for r in sorted(resid)}
        n_ok = sum(1 for v in fits.values() if v is not None)
        print("   tile %6d: %d/%d residuals decompose" % (tb, n_ok, len(resid)))
        if n_ok == len(resid):
            for r, (k, pre) in sorted(fits.items()):
                print("        residual %8d = prefix %6d + %d x %d" % (r, pre, k, tb))

    # --- full chunk-size table (including no-page nodes and paired) ----------
    print("\n== distinct chunk sizes")
    for lbl, rows in (("primary", prim), ("paired", paired)):
        seen = collections.Counter()
        for key, sz, _p, pc in rows:
            seen[(sz, pc)] += 1
        for (sz, pc), cnt in sorted(seen.items()):
            r = sz - pc * ps
            t = tiles_in(r, 17424) if r >= 0 else None
            t2 = tiles_in(r, 67600) if r >= 0 else None
            d17 = ("%dx17424+pre%d" % (t[0], t[1])) if t else "-"
            d67 = ("%dx67600+pre%d" % (t2[0], t2[1])) if t2 else "-"
            print("   x%-3d %-8s size %9d  pages %3d  residual %8d   [%s | %s]"
                  % (cnt, lbl, sz, pc, r, d17, d67))

    # --- BC7 mode histograms -------------------------------------------------
    print("\n== BC7 modes of trailer tiles")
    for tb in TILE_CANDIDATES:
        fits = {r: tiles_in(r, tb) for r in resid}
        if not all(fits.values() is not None for _ in [0]) or \
           any(v is None for v in fits.values()):
            continue
        agg_first = collections.Counter()
        agg_last = collections.Counter()
        kcnt = collections.Counter()
        for key, sz, p, pc in prim:
            r = sz - pc * ps
            f = tiles_in(r, tb)
            if f is None:
                continue
            k, pre = f
            kcnt[k] += 1
            if k == 0:
                continue
            buf = C.read(p)
            tr = buf[len(buf) - k * tb:]
            agg_first.update(M.bc7_modes(tr[:tb]))
            if k > 1:
                agg_last.update(M.bc7_modes(tr[-tb:]))
        print("   tile %6d  tiles-per-primary %s" % (tb, dict(kcnt)))
        for lbl, h in (("first", agg_first), ("last", agg_last)):
            tot = sum(h.values())
            if not tot:
                print("      %-5s (no data)" % lbl)
                continue
            hi = sum(c for m2, c in h.items() if isinstance(m2, int) and m2 >= 4)
            print("      %-5s tile  %8d blocks  modes4-7 %5.1f%%   %s"
                  % (lbl, tot, 100.0 * hi / tot,
                     ", ".join("m%s:%d" % kv for kv in
                               sorted(h.items(), key=lambda kv: -kv[1])[:6])))

    # --- paired trailer check ------------------------------------------------
    print("\n== paired chunks: trailer = 4 child tiles?")
    okc = collections.Counter()
    for key, sz, p, pc in paired:
        r = sz - pc * ps
        f = tiles_in(r, 17424)
        f2 = tiles_in(r, 67600)
        okc[("17424", f[0] if f else None)] += 1
        okc[("67600", f2[0] if f2 else None)] += 1
    for (tb, k), cnt in sorted(okc.items()):
        print("   tile %s  k=%s  x%d" % (tb, k, cnt))


if __name__ == "__main__":
    main()
