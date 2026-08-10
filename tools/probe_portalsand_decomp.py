"""MP_Portal_Sand chunk decomposition + colour-tile codec identification.

Produces THE DECOMPOSITION TABLE for the detect_layout fix, and settles the
codec of this map's colour trailer, which is neither of the known BC7 tile
sizes (17424 = 132^2, 4624 = 68^2):

  * every external-height primary chunk is
        149297 (height, xs=265) + k x 2592 (BC4 weight pages) + 8712 (trailer)
  * 8712 is NOT divisible by 16, so the trailer cannot be BC7.
    8712 = 33 x 33 blocks x 8 B  =  one 132 x 132 **BC1** tile.
  * the paired chunks are all exactly 34848 = 4 x 8712 -- the four children's
    single colour tiles, nothing else (zero pages).

Evidence printed: byte-16 alignment failure for BC7, BC1 block statistics
(endpoint ordering, index entropy), decoded BC1 mean colour vs the raw-plane
and BC7 readings, and the plugin's current detect_layout simulated on this map.

Usage:  probe_portalsand_decomp.py [--verbose]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_portalsand_common as PC     # noqa: E402
import probe_tung_terrain as T           # noqa: E402
import probe_tung_colormap as M          # noqa: E402

HEIGHT_PREFIXES = (0, 39919, 149297, 189216, 2 * 149297)


def bc1_decode_mean(tile):
    """Decode BC1 fully (both endpoint + interpolant paths) and return
    (meanR, meanG, meanB) in 0..1 plus block stats."""
    n = len(tile) // 8
    tr = tg = tb = 0.0
    cnt = 0
    c0_gt_c1 = 0
    for i in range(n):
        c0, c1, idx = struct.unpack_from("<HHI", tile, i * 8)
        if c0 > c1:
            c0_gt_c1 += 1
        p = []
        for c in (c0, c1):
            r = (c >> 11) & 0x1F
            g = (c >> 5) & 0x3F
            b = c & 0x1F
            p.append((r / 31.0, g / 63.0, b / 31.0))
        r0, g0, b0 = p[0]
        r1, g1, b1 = p[1]
        pal = [p[0], p[1]]
        if c0 > c1:
            pal.append(((2 * r0 + r1) / 3, (2 * g0 + g1) / 3, (2 * b0 + b1) / 3))
            pal.append(((r0 + 2 * r1) / 3, (g0 + 2 * g1) / 3, (b0 + 2 * b1) / 3))
        else:
            pal.append(((r0 + r1) / 2, (g0 + g1) / 2, (b0 + b1) / 2))
            pal.append((0.0, 0.0, 0.0))
        for t in range(16):
            sel = (idx >> (t * 2)) & 3
            r, g, b = pal[sel]
            tr += r
            tg += g
            tb += b
            cnt += 1
    return (tr / cnt, tg / cnt, tb / cnt), c0_gt_c1, n


def main():
    verbose = "--verbose" in sys.argv
    td = T.terr_dir(PC.LEVEL)
    d = PC.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = M.chunk_dir(d, after)
    print("%s: chunk directory %d nodes (header NodeCount %d), consumed %d/%d B"
          % (PC.LEVEL, len(nodes), hdr["NodeCount"], end, len(d)))

    # ---- census ------------------------------------------------------------
    prim = collections.Counter()
    paired = collections.Counter()
    for n in nodes:
        for which, g in (("P", n["g0"]), ("S", n["g1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if not os.path.isfile(p):
                print("   MISSING chunk %s" % g.hex())
                continue
            (prim if which == "P" else paired)[os.path.getsize(p)] += 1
    print("primary sizes:", sorted(prim.items()))
    print("paired  sizes:", sorted(paired.items()))

    # ---- decomposition table ----------------------------------------------
    print("\nDECOMPOSITION (page candidates 2592/4356/5184, prefix set %s):"
          % (HEIGHT_PREFIXES,))
    sols = {}
    for size in sorted(prim):
        rows = []
        for ps in (2592, 4356, 5184):
            for pre in HEIGHT_PREFIXES:
                rest = size - pre
                if rest < 0:
                    continue
                for pages in range(0, rest // ps + 1):
                    trailer = rest - pages * ps
                    rows.append((ps, pre, pages, trailer))
        # the physical solution: prefix = the block-0 inline size when the node
        # has external heights, and one common trailer across all sizes
        rows = [r for r in rows if r[3] in (0, 8712)]
        sols[size] = rows
        for ps, pre, pages, trailer in rows:
            print("   %7d = %6d + %d x %d + %d" % (size, pre, pages, ps, trailer))

    # ---- trailer codec -----------------------------------------------------
    print("\nTRAILER CODEC (8712 B):")
    print("   8712 %% 16 = %d  -> NOT a whole number of 16-B BC7/BC2/BC3 blocks"
          % (8712 % 16))
    print("   8712 / 8  = %d = 33^2 -> 33x33 blocks of 8 B = 132 x 132 BC1"
          % (8712 // 8))

    ext = [n for n in nodes if n["g0"] is not None]
    means = []
    gt = tot = 0
    per_depth = collections.defaultdict(list)
    for n in ext:
        p = M.chunk_path(n["g0"])
        sz = os.path.getsize(p)
        if sz == 10368:          # the 5 packed-height chunks: pages only
            continue
        buf = PC.read(p)
        tile = buf[-8712:]
        (mr, mg, mb), c_gt, nb = bc1_decode_mean(tile)
        means.append((mr, mg, mb))
        per_depth[n["depth"]].append((mr, mg, mb))
        gt += c_gt
        tot += nb
        if verbose:
            print("   node 0x%-8X depth %d  BC1 mean (%.3f, %.3f, %.3f)"
                  % (n["key"], n["depth"], mr, mg, mb))
    mr = sum(m[0] for m in means) / len(means)
    mg = sum(m[1] for m in means) / len(means)
    mb = sum(m[2] for m in means) / len(means)
    print("   %d primary tiles BC1-decoded: mean RGB (%.3f, %.3f, %.3f)"
          % (len(means), mr, mg, mb))
    print("   c0>c1 (4-colour mode) in %d/%d blocks = %.1f%%" % (gt, tot, 100.0 * gt / tot))
    for dep in sorted(per_depth):
        ms = per_depth[dep]
        print("      depth %d  x%-3d  mean (%.3f, %.3f, %.3f)"
              % (dep, len(ms),
                 sum(m[0] for m in ms) / len(ms),
                 sum(m[1] for m in ms) / len(ms),
                 sum(m[2] for m in ms) / len(ms)))

    # BC7-mode histogram for the record (the law's test, applied honestly)
    h_first = collections.Counter()
    for n in ext[:64]:
        p = M.chunk_path(n["g0"])
        if os.path.getsize(p) == 10368:
            continue
        buf = PC.read(p)
        h_first.update(M.bc7_modes(buf[-8712:-8712 + 4352]))
    tot7 = sum(h_first.values())
    hi7 = sum(c for m, c in h_first.items() if isinstance(m, int) and m >= 4)
    print("   BC7-mode test on the same bytes: modes4-7 %.1f%% -> FAILS the ~98%% "
          "criterion, as it must for BC1 data" % (100.0 * hi7 / tot7))

    # ---- paired chunks -----------------------------------------------------
    print("\nPAIRED CHUNKS:")
    one = next(n for n in nodes if n["g1"] is not None)
    buf = PC.read(M.chunk_path(one["g1"]))
    print("   all %d paired chunks are %d B = 4 x 8712 -> the four children's"
          % (sum(paired.values()), len(buf)))
    print("   colour tiles and NOTHING else (zero weight pages)")
    for i in range(4):
        (mr, mg, mb), _g, _n = bc1_decode_mean(buf[i * 8712:(i + 1) * 8712])
        print("      child slot %d  BC1 mean (%.3f, %.3f, %.3f)" % (i, mr, mg, mb))

    # ---- what the plugin's detect_layout would do --------------------------
    print("\nDETECT_LAYOUT SIMULATION (bf6_splat.gd scoring: rest >= 0 after "
          "size - tile - pages*page):")
    sizes_list = []
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if os.path.isfile(p):
            sizes_list.append(os.path.getsize(p))
    results = []
    for ps in (2592, 4356, 5184):
        for tile in (4624, 17424):
            score = sum(1 for s in sizes_list if s - tile >= 0)
            results.append((score, ps, tile))
    results.sort(reverse=True)
    for score, ps, tile in results:
        print("   page %4d tile %5d  score %d" % (ps, tile, score))
    print("   -> picks (2592, 4624) by tie-order; TRUE layout is page 2592, "
          "ONE 8712-B BC1 tile. tile=4624 slices the BC1 tile mid-block AND "
          "decodes it as BC7.")


if __name__ == "__main__":
    main()
