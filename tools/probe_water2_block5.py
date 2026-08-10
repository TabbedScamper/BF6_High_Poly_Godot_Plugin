"""BLOCK 5: is it the water-coverage mask for block 2?

MAP-TUNGSTEN.md U5 measured that streaming-tree block 5 co-occurs with the
water-surface heightfield (block 2) on exactly mp_tungsten / mp_eastwood /
mp_isolated, and left "block 5 is the water-coverage mask" as an untested
HYPOTHESIS. TERRAIN.md 6 gives blocks 4/5 a shared format (57-byte header +
4 bytes per node, no per-texel payload) but leaves the semantics open, and
flags (14 item 1) that the child-quadrant convention was never validated for
these trees because they store no bounds.

This probe tests the hypothesis three ways, with numbers:

  A  header + size arithmetic: blockSize == 57 + 4*TotalNodeCount, the world
     bbox, and the flag-byte census (every node byte must be 0/1);
  B  TREE-SHAPE JOIN: walk blocks 2, 4 and 5 in parallel by quadtree key and
     ask, per key, whether block-5 coverage predicts the block-2 node kind
     (External = has water data / Empty = none);
  C  RASTER JOIN: paint block-5 leaf coverage onto the same 512x512 world
     raster the block-2 probe uses for its wet mask (water > ground + 2 cm),
     under BOTH child conventions (traversal order 0,+x,+x+z,+z vs binary),
     and score precision/recall of "covered" against "wet" - and against
     "block-2 surface above the dry fill", which is what the plugin's
     mode-based clip actually meshes.

READ-ONLY.  Usage:  probe_water2_block5.py [level]     (default mp_tungsten)
"""
import os
import struct
import sys

sys.setrecursionlimit(200000)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as CM     # noqa: E402

# Per-node payload size, from the block header (the same identity
# bf6_terrain.gd::read_block_header computes: xs^2*2 + minmax/occluder stacks
# + density page). 265 -> 149,297; 137 (mp_isolated block 2) -> 39,919.
def data_size(h):
    return (h["xs"] * h["xs"] * 2 + T._stack(h["MinMaxStackDepth"], False) * 2
            + T._stack(h["OccluderGridStackDepth"], True) * 2
            + h["DensityMapNodeSamplesPerSide"] ** 2)

# Distance from the block-2 payload END to the chunk end. MEASURED per level
# (probe run 2026-08-10): tungsten/eastwood chunks end [b2][0..n tiles] with the
# tungsten tail set; mp_isolated ends [b2][8,712 = 2 x 4,356] on leaf chunks and
# one extra 17,424 colour tile on non-leaf chunks.
TAILS_BY_LEVEL = {"mp_isolated": (8712, 26136)}
TAILS = (0, 17424, 34848, 85024)
PAGE_BY_LEVEL = {"mp_eastwood": 2592, "mp_tungsten": 4356, "mp_granite": 4356}
RES = 512

# TERRAIN.md 2.4 traversal order, and the binary alternative it was measured
# against (children 2 and 3 transposed).
CONV = {
    "traversal": ((0, 0), (1, 0), (1, 1), (0, 1)),
    "binary":    ((0, 0), (1, 0), (0, 1), (1, 1)),
}


def mask_header(d, base):
    f = lambda k: struct.unpack_from("<i", d, base + k)[0]
    return {
        "Dim": f(0x00), "TilesPerNodeSide": f(0x04),
        "AtlasX": f(0x08), "AtlasY": f(0x0C), "Unknown16": f(0x10),
        "bbox": struct.unpack_from("<4f", d, base + 0x14),
        "SubTag": f(0x24), "Unknown40": f(0x28), "Unknown44": f(0x2C),
        "Flag48": d[base + 0x30],
        "TotalNodeCount": struct.unpack_from("<i", d, base + 0x31)[0],
        "Unknown53": struct.unpack_from("<i", d, base + 0x35)[0],
    }


def mask_walk(d, base, count):
    """Pre-order DFS over 4-byte nodes. Returns [(key, depth, hasData,
    coverage, pad, hasChildren)] in stream order; keys use the SAME key
    arithmetic as every other tree (root 3, child i -> (key<<4)|i), which is
    convention-agnostic - the CONVENTION only decides which world quadrant a
    nibble means."""
    nodes = []
    pos = [base]

    def node(key, depth):
        o = pos[0]
        hd, cov, pad, hc = d[o], d[o + 1], d[o + 2], d[o + 3]
        pos[0] = o + 4
        nodes.append((key, depth, hd, cov, pad, hc))
        if hc:
            for i in range(4):
                node((key << 4) | i, depth + 1)

    node(3, 0)
    assert len(nodes) == count, (len(nodes), count)
    return nodes


def leaf_rects(nodes, bbox, conv):
    """[(x0, z0, x1, z1, coverage, hasData)] for every LEAF, bounds derived
    by quadrant subdivision of the header bbox under the given convention."""
    x0w, z0w, x1w, z1w = bbox
    off = CONV[conv]
    bykey = {}
    order = []
    for key, depth, hd, cov, pad, hc in nodes:
        bykey[key] = (hd, cov, hc)
        order.append((key, depth, hd, cov, hc))
    rects = []
    for key, depth, hd, cov, hc in order:
        if hc:
            continue
        # decode the key's nibble path back into a rect
        x, z, size = 0.0, 0.0, 1.0
        nib = []
        k = key
        while k != 3:
            nib.append(k & 0xF)
            k >>= 4
        for q in reversed(nib):
            size *= 0.5
            x += off[q][0] * size
            z += off[q][1] * size
        rects.append((x0w + x * (x1w - x0w), z0w + z * (z1w - z0w),
                      x0w + (x + size) * (x1w - x0w),
                      z0w + (z + size) * (z1w - z0w), cov, hd))
    return rects


def paint(rects, world_bbox, want_cov):
    x0w, z0w, x1w, z1w = world_bbox
    img = bytearray(RES * RES)
    for x0, z0, x1, z1, cov, hd in rects:
        if cov != want_cov:
            continue
        px0 = max(0, int((x0 - x0w) / (x1w - x0w) * RES))
        px1 = min(RES, int((x1 - x0w) / (x1w - x0w) * RES + 0.5))
        pz0 = max(0, int((z0 - z0w) / (z1w - z0w) * RES))
        pz1 = min(RES, int((z1 - z0w) / (z1w - z0w) * RES + 0.5))
        for pz in range(pz0, pz1):
            base = pz * RES
            for px in range(px0, px1):
                img[base + px] = 1
    return img


def block2_rasters(level, d, bl, world_bbox):
    """(wet, abovefill, ext2img): 512x512 masks - water > ground + 2 cm;
    block-2 surface above dryfill + 0.5 m (the plugin's mode-based clip); and
    the External block-2 node footprint.

    Handles xs(block 2) != xs(block 0): mp_isolated ships block 2 at xs=137
    against block 0's 265, so the two grids are sampled by WORLD position
    (border-aware, per bf6_terrain.gd composite: the node AABB spans
    grid[border .. xs-1-border])."""
    h0 = T.hf_header(d, bl[0][0])
    h2 = T.hf_header(d, bl[2][0])
    xs0, xs2 = h0["xs"], h2["xs"]
    p0, p2 = data_size(h0), data_size(h2)
    wy0, wy2 = h0["WorldSizeY"], h2["WorldSizeY"]
    l2 = T.hf_walk(d, bl[2][0], bl[2][1], h2)[0]
    ext2 = [n for n in l2 if n[4] == "External"]
    dirnodes, _ = CM.chunk_dir(d, T.container(d)[2])
    bykey = {n["key"]: n for n in dirnodes}
    tails = TAILS_BY_LEVEL.get(level, TAILS)
    x0w, z0w, x1w, z1w = world_bbox

    wet = bytearray(RES * RES)
    above = bytearray(RES * RES)
    extimg = bytearray(RES * RES)
    fill_tally = {}
    grids = []
    for key, dep, mn, mx, kind in ext2:
        dn = bykey.get(key)
        if dn is None or dn["g0"] is None:
            continue
        p = CM.chunk_path(dn["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < p0 + p2:
            continue
        lo16 = int((mn[1] - 0.5) / wy2 * 65536)
        hi16 = int((mx[1] + 0.5) / wy2 * 65536)

        def inband(off):
            g = struct.unpack_from("<%dH" % (xs2 * xs2), buf, off)
            pick = [g[(j + 4) * xs2 + (i + 4)]
                    for j in range(0, xs2 - 8, 13) for i in range(0, xs2 - 8, 13)]
            return sum(1 for v in pick if lo16 <= v <= hi16) / float(len(pick))
        cands = [len(buf) - t - p2 for t in tails if len(buf) - t - p2 >= p0]
        if not cands:
            continue
        off2 = max(cands, key=inband)
        if inband(off2) < 0.9:
            continue
        g0 = struct.unpack_from("<%dH" % (xs0 * xs0), buf, 0)
        g2 = struct.unpack_from("<%dH" % (xs2 * xs2), buf, off2)
        grids.append((key, mn, mx, g0, g2))
        # dry-fill tally on a stride, like the plugin's
        for s in range(0, xs2 * xs2, 97):
            fill_tally[g2[s]] = fill_tally.get(g2[s], 0) + 1
        # External node footprint
        px0 = max(0, int((mn[0] - x0w) / (x1w - x0w) * RES))
        px1 = min(RES, int((mx[0] - x0w) / (x1w - x0w) * RES + 0.5))
        pz0 = max(0, int((mn[2] - z0w) / (z1w - z0w) * RES))
        pz1 = min(RES, int((mx[2] - z0w) / (z1w - z0w) * RES + 0.5))
        for pz in range(pz0, pz1):
            for px in range(px0, px1):
                extimg[pz * RES + px] = 1

    fill = max(fill_tally, key=fill_tally.get)
    wet_min = fill + int(0.5 / wy2 * 65536.0)
    b = 4                                    # NodeBorderWidth, both blocks
    n2i = xs2 - 1 - 2 * b                    # interior spans of the node AABB
    n0i = xs0 - 1 - 2 * b
    for key, mn, mx, g0, g2 in grids:
        for j in range(n2i + 1):
            for i in range(n2i + 1):
                v2 = g2[(j + b) * xs2 + (i + b)]
                i0 = b + int(round(i * n0i / float(n2i)))
                j0 = b + int(round(j * n0i / float(n2i)))
                v0 = g0[j0 * xs0 + i0]
                wx = mn[0] + i / float(n2i) * (mx[0] - mn[0])
                wz = mn[2] + j / float(n2i) * (mx[2] - mn[2])
                px = int((wx - x0w) / (x1w - x0w) * (RES - 1))
                pz = int((wz - z0w) / (z1w - z0w) * (RES - 1))
                if not (0 <= px < RES and 0 <= pz < RES):
                    continue
                if v2 / 65536.0 * wy2 - v0 / 65536.0 * wy0 > 0.02:
                    wet[pz * RES + px] = 1
                if v2 >= wet_min:
                    above[pz * RES + px] = 1
    return wet, above, extimg, fill / 65536.0 * wy2, ext2, l2


def score(pred, truth):
    tp = sum(1 for a, b in zip(pred, truth) if a and b)
    fp = sum(1 for a, b in zip(pred, truth) if a and not b)
    fn = sum(1 for a, b in zip(pred, truth) if b and not a)
    prec = tp / float(tp + fp) if tp + fp else 0.0
    rec = tp / float(tp + fn) if tp + fn else 0.0
    iou = tp / float(tp + fp + fn) if tp + fp + fn else 0.0
    return prec, rec, iou, tp, fp, fn


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_tungsten"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    bl = {t: (o, s) for t, o, s in blocks}
    print("%s blocks: %s" % (level, sorted(bl)))
    if 5 not in bl or 2 not in bl:
        print("no block 5 and/or 2 - nothing to test")
        return

    # A. headers + size arithmetic + flag census
    for b in (4, 5):
        if b not in bl:
            continue
        off, size = bl[b]
        h = mask_header(d, off)
        fits = size == 57 + 4 * h["TotalNodeCount"]
        print("\nblock %d: %d bytes  header %s" % (b, size, h))
        print("  size == 57 + 4*N: %s" % fits)
        if not fits:
            # mp_eastwood's block 5: Dim=260, Unknown16=0, N=53, 154 payload
            # bytes. MEASURED not to be any 1..4-byte-stride pre-order or BFS
            # quadtree (brute force over header lengths 40..80); undecoded.
            print("  VARIANT FORMAT - node walk skipped (see RESEARCH-WATER2.md)")
            if b == 5:
                return
            continue
        nodes = mask_walk(d, off + 57, h["TotalNodeCount"])
        bad = [n for n in nodes if n[2] not in (0, 1) or n[3] not in (0, 1)
               or n[4] != 0 or n[5] not in (0, 1)]
        leaves = [n for n in nodes if not n[5]]
        cov1 = [n for n in leaves if n[3]]
        hd1 = [n for n in nodes if n[2]]
        int_cov = [n for n in nodes if n[5] and n[3]]
        print("  nodes %d (leaves %d)  bad-flag-bytes %d" %
              (len(nodes), len(leaves), len(bad)))
        print("  leaf coverage=1: %d   hasData=1 anywhere: %d   internal "
              "coverage=1: %d" % (len(cov1), len(hd1), len(int_cov)))

    # world bbox: block 5's own header bbox
    h5 = mask_header(d, bl[5][0])
    bbox5 = h5["bbox"]
    print("\nblock-5 world bbox (MinX MinZ MaxX MaxZ): %s" % (bbox5,))

    # block-2 rasters over that bbox
    wet, above, extimg, fill_y, ext2, l2 = block2_rasters(level, d, bl, bbox5)
    print("block-2: %d External nodes, dry fill %.2f m, wet %.2f%% of raster,"
          " above-fill %.2f%%" %
          (len(ext2), fill_y, 100.0 * sum(wet) / (RES * RES),
           100.0 * sum(above) / (RES * RES)))

    # B. tree-shape join by key
    n5 = mask_walk(d, bl[5][0] + 57, h5["TotalNodeCount"])
    cov5 = {k: (hd, cov, hc) for k, dep, hd, cov, pad, hc in n5}
    kinds2 = {n[0]: n[4] for n in l2}
    joint = {}
    for k, kind in kinds2.items():
        c = cov5.get(k)
        joint[(kind, None if c is None else c[1])] = \
            joint.get((kind, None if c is None else c[1]), 0) + 1
    print("\nB. block-2 node kind x block-5 coverage at the SAME key:")
    for (kind, cov), n in sorted(joint.items(), key=lambda kv: str(kv[0])):
        print("   %-8s cov=%-4s : %d" % (kind, cov, n))
    only5 = [k for k in cov5 if k not in kinds2]
    print("   block-5 keys with no block-2 node: %d" % len(only5))

    # C. raster join, both conventions
    print("\nC. leaf-coverage raster vs block-2 (precision/recall/IoU):")
    for conv in ("traversal", "binary"):
        rects = leaf_rects(n5, bbox5, conv)
        img = paint(rects, bbox5, 1)
        for name, truth in (("wet(>ground)", wet), ("above-fill", above),
                            ("ext-footprint", extimg)):
            p, r, iou, tp, fp, fn = score(img, truth)
            print("   %-9s cov=1 vs %-13s  prec %.3f  rec %.3f  IoU %.3f"
                  "  (tp %d fp %d fn %d)" % (conv, name, p, r, iou, tp, fp, fn))
    # block 4 contrast, traversal only
    if 4 in bl:
        h4 = mask_header(d, bl[4][0])
        n4 = mask_walk(d, bl[4][0] + 57, h4["TotalNodeCount"])
        img4 = paint(leaf_rects(n4, h4["bbox"], "traversal"), h4["bbox"], 1)
        p, r, iou, tp, fp, fn = score(img4, wet)
        print("   block-4  cov=1 vs wet(>ground)   prec %.3f  rec %.3f  "
              "IoU %.3f  (contrast)" % (p, r, iou))
        print("   block-4 cov=1 raster share: %.2f%%   block-5: %.2f%%"
              % (100.0 * sum(img4) / (RES * RES),
                 100.0 * sum(paint(leaf_rects(n5, bbox5, 'traversal'), bbox5, 1))
                 / (RES * RES)))

    # D. since leaf coverage saturates, the information is in the exceptions
    # and in the tree SHAPE. Name every exceptional node, then test whether
    # SUBDIVISION DEPTH follows the water.
    print("\nD. the exceptional nodes (block 5, then block 4):")
    for tag, nn in (("b5", n5), ("b4", n4 if 4 in bl else [])):
        for key, dep, hd, cov, pad, hc in nn:
            if hd or not cov:
                k2 = kinds2.get(key, "-")
                print("   %s key 0x%-10X d%d  hasData=%d cov=%d children=%d"
                      "   block-2 there: %s" % (tag, key, dep, hd, cov, hc, k2))

    # E. tree shape: depth histogram + how the key sets nest
    import collections
    dh5 = collections.Counter(dep for _, dep, _, _, _, hc in n5 if not hc)
    dh4 = collections.Counter(dep for _, dep, _, _, _, hc in n4 if not hc) \
        if 4 in bl else {}
    print("\nE. leaf-depth histogram  b5: %s" % dict(sorted(dh5.items())))
    if dh4:
        print("                         b4: %s" % dict(sorted(dh4.items())))
    keys5 = set(k for k, *_ in n5)
    keys4 = set(k for k, *_ in n4) if 4 in bl else set()
    keys2 = set(kinds2)
    dirnodes, _ = CM.chunk_dir(d, T.container(d)[2])
    keysdir = set(n["key"] for n in dirnodes)
    h0 = T.hf_header(d, bl[0][0])
    keys0 = set(n[0] for n in T.hf_walk(d, bl[0][0], bl[0][1], h0)[0])
    print("   |b5|=%d |b4|=%d |b2|=%d |b0|=%d |dir|=%d" %
          (len(keys5), len(keys4), len(keys2), len(keys0), len(keysdir)))
    print("   b2 subset of b5: %s   b5 subset of b4: %s   b4 == dir: %s   "
          "b4 == b0: %s" % (keys2 <= keys5, keys5 <= keys4,
                            keys4 == keysdir, keys4 == keys0))
    print("   b5 == b0: %s   b5 == dir: %s" % (keys5 == keys0, keys5 == keysdir))

    # F. does DEPTH follow water? paint the deepest-leaf footprint and score
    maxdep = max(dh5)
    deep = [(x0, z0, x1, z1, 1, hd) for (x0, z0, x1, z1, cov, hd)
            in leaf_rects([n for n in n5 if n[1] >= maxdep or not n[5]],
                          bbox5, "traversal")]
    # leaves at max depth only
    deep_rects = []
    for key, dep, hd, cov, pad, hc in n5:
        if hc or dep < maxdep:
            continue
        deep_rects.append((key, dep))
    deepimg = paint([r for r in leaf_rects(n5, bbox5, "traversal")
                     if abs((r[2] - r[0]) - (bbox5[2] - bbox5[0]) / 2 ** maxdep)
                     < 1.0], bbox5, 1)
    for name, truth in (("wet(>ground)", wet), ("above-fill", above)):
        p, r, iou, tp, fp, fn = score(deepimg, truth)
        print("F. b5 max-depth(%d) leaves vs %-13s prec %.3f rec %.3f IoU %.3f"
              % (maxdep, name, p, r, iou))
    if 4 in bl:
        maxdep4 = max(dh4)
        deepimg4 = paint([r for r in leaf_rects(n4, h4["bbox"], "traversal")
                          if abs((r[2] - r[0]) - (h4["bbox"][2] - h4["bbox"][0])
                                 / 2 ** maxdep4) < 1.0], h4["bbox"], 1)
        p, r, iou, tp, fp, fn = score(deepimg4, wet)
        print("   b4 max-depth(%d) leaves vs wet          prec %.3f rec %.3f "
              "IoU %.3f  (contrast)" % (maxdep4, p, r, iou))


if __name__ == "__main__":
    main()
