"""MP_Plaza chunk decomposition — the verification row for the detect_layout fix.

MP_Plaza is the ONLY map whose derived splat page size is 5184 (72x72 raw), so
this table is the sole cross-check of that branch of the page-size table in
MAP-TUNGSTEN.md / impl/pipeline/bf6_splat.py.

Method (same as MAP-TUNGSTEN.md C1, but with the page count KNOWN per node):
block 1's per-node records name exactly which layers store a weight page at
that node, so `pages` is not a free variable — the residual
`primary_size - pages * 5184` is fully determined per node.

Usage:  probe_plaza_decomp.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

PS = 5184                            # 72x72 raw weight page
HEIGHT = 149297                      # xs=265 external height payload (block 0)
TILE = 67600                         # 65x65 BC7 blocks = 260x260 texels


def per_node_pages(d, blocks):
    """block 1 walk -> {node_key: stored (painted) page count}."""
    b1 = [b for b in blocks if b[0] == 1][0]
    base, size = b1[1], b1[2]
    endb = base + size
    pages = {}

    def node(o, key):
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        cnt = 0
        for _ in range(rc):
            flags = struct.unpack_from("<H", d, o + 20)[0]
            if not (flags & 0x0100):
                cnt += 1
            o += 33
        pages[key] = cnt
        if rc == 0:
            return o + 1
        o += 1
        hc = d[o]
        o += 1
        if o < endb:
            o += 1
        if hc:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    node(base + 0x3D, 3)
    return pages


def bc7_modes(buf):
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


def pct47(h):
    t = sum(h.values())
    return 100.0 * sum(c for m, c in h.items()
                       if isinstance(m, int) and m >= 4) / t if t else 0.0


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_plaza"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = M.chunk_dir(d, after)
    pages = per_node_pages(d, blocks)
    print("%s: %d chunk-dir nodes (header NodeCount %d), directory byte-exact: %s"
          % (level, len(nodes), hdr["NodeCount"], end == len(d)))

    # ---- primary chunks --------------------------------------------------
    resid = collections.Counter()
    bad = []
    first_h = collections.Counter()
    last_h = collections.Counter()
    n_trailer = 0
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            bad.append((n["key"], "missing"))
            continue
        s = os.path.getsize(p)
        pg = pages.get(n["key"])
        if pg is None:
            bad.append((n["key"], "no block-1 node"))
            continue
        r = s - pg * PS
        resid[r] += 1
        if r == HEIGHT + TILE:
            buf = C.read(p)
            tail = buf[-TILE:]
            half = (TILE // 2 // 16) * 16
            first_h.update(bc7_modes(tail[:half]))
            last_h.update(bc7_modes(tail[-half:]))
            n_trailer += 1
        elif r != 0:
            bad.append((n["key"], "residual %d" % r))
    print("\nPRIMARY: size - pages*%d residuals:" % PS)
    for r, c in sorted(resid.items()):
        note = ""
        if r == 0:
            note = "  (pages only — packed-height node, no trailer)"
        elif r == HEIGHT + TILE:
            note = "  = %d height + 1 x %d tile" % (HEIGHT, TILE)
        print("   %7d  x%-3d%s" % (r, c, note))
    if bad:
        print("   UNEXPLAINED:", bad)
    print("\nBC7 mode histogram of the single %d-byte trailer tile "
          "(%d chunks):" % (TILE, n_trailer))
    print("   first half  modes4-7 %6.2f%%   %s"
          % (pct47(first_h), dict(sorted(first_h.items(),
                                         key=lambda kv: -kv[1])[:6])))
    print("   last half   modes4-7 %6.2f%%   %s"
          % (pct47(last_h), dict(sorted(last_h.items(),
                                        key=lambda kv: -kv[1])[:6])))

    # ---- paired chunks ---------------------------------------------------
    # On plaza a paired chunk is EXACTLY the weight pages of every block-1
    # node in the sub-tree below the chunk-dir node (the splat tree is deeper
    # than the chunk directory: 297 vs 77 nodes). No heights, no colour tiles
    # — 67600 mod 5184 = 200, so no tile count can hide in a 5184-multiple.
    print("\nPAIRED: size mod %d and descendant-page check:" % PS)

    def descendants_pages(key):
        tot = 0
        for k, c in pages.items():
            kk = k
            while kk > key:
                kk >>= 4
            if kk == key and k != key:
                tot += c
        return tot

    ok = mismatch = 0
    notmult = []
    for n in nodes:
        if n["g1"] is None:
            continue
        p = M.chunk_path(n["g1"])
        if not os.path.isfile(p):
            continue
        s = os.path.getsize(p)
        if s % PS:
            notmult.append((n["key"], s))
            continue
        dp = descendants_pages(n["key"])
        if s // PS == dp:
            ok += 1
        else:
            mismatch += 1
            if mismatch <= 6:
                print("   key 0x%X  paired %d = %d pages, descendants have %d"
                      % (n["key"], s, s // PS, dp))
    print("   multiples of %d: all=%s;  == sum(block-1 DESCENDANT pages): %d ok, %d mismatch"
          % (PS, not notmult, ok, mismatch))
    if notmult:
        print("   NOT multiples:", notmult)


if __name__ == "__main__":
    main()
