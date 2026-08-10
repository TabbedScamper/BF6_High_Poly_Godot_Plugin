"""MP_Badlands: exact decomposition of every streaming chunk, and the BC7 mode
census of the trailer -- the verification row for the detect_layout fix.

Laws under test (fleet brief / MAP-TUNGSTEN.md):
  * page size on badlands should be 4,356 (raw 66x66 planes, no BC4);
  * chunk = [height prefix in sums of {0, 39919, 149297, 189216}]
            + pages x 4356 + trailer, zero residual;
  * trailer = k x tile;  tile 17424 = 132^2 BC7 on this size class;
  * colour tile is the FIRST tile of the trailer; a second tile, when present,
    is degenerate;
  * BC7 mode test: image tiles ~100% modes 4-7 (dumbo/tungsten encoders).

Usage:  probe_badlands_decomp.py [level]
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
HB265 = 149297
HB137 = 39919
PREFIXES = sorted({0, HB137, HB265, HB137 + HB265, 2 * HB265,
                   2 * HB137, HB137 + 2 * HB265})


def decompose(size):
    """-> (prefix, n_pages_units) with (size - prefix) a multiple of PS, or None.
    Unambiguous because no two prefixes are congruent mod PS (asserted)."""
    for p in PREFIXES:
        r = size - p
        if r >= 0 and r % PS == 0:
            return p, r // PS
    return None


def modes(buf):
    h = collections.Counter()
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        if b == 0:
            h["z"] += 1
            continue
        m = 0
        while not (b >> m) & 1:
            m += 1
        h[m] += 1
    return h


def hstr(h):
    tot = sum(h.values())
    hi = sum(c for m, c in h.items() if isinstance(m, int) and m >= 4)
    top = ", ".join("m%s:%d" % (m, c) for m, c in
                    sorted(h.items(), key=lambda kv: -kv[1])[:6])
    return "%7d blocks  m4-7 %5.1f%%  zero-byte0 %5.1f%%  [%s]" % (
        tot, 100.0 * hi / tot if tot else 0,
        100.0 * h.get("z", 0) / tot if tot else 0, top)


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_badlands"
    # prefix residues mod PS must be distinct for decompose() to be exact
    res = [p % PS for p in PREFIXES]
    assert len(set(res)) == len(res), "prefixes collide mod %d" % PS

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, end = M.chunk_dir(d, after)
    print("%s: %d directory nodes, directory consumed %d/%d bytes"
          % (level, len(nodes), end, len(d)))

    combos = collections.Counter()
    residual_fail = []
    tail_tile = collections.defaultdict(collections.Counter)   # depth -> modes
    pre_tile = collections.Counter()                           # 17424 B before tail
    tail_distinct = collections.Counter()                      # distinct blocks in tail tile
    prim_found = 0
    for n in nodes:
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        prim_found += 1
        size = os.path.getsize(p)
        dec = decompose(size)
        if dec is None:
            residual_fail.append((n["key"], size, size % PS))
            continue
        pref, units = dec
        combos[("primary", pref, units)] += 1
        if units * PS >= TILE:
            buf = C.read(p)
            t = buf[-TILE:]
            tail_tile[n["depth"]].update(modes(t))
            tail_distinct[len({t[i:i + 16] for i in range(0, TILE, 16)})] += 1
            if units * PS >= 2 * TILE:
                pre_tile.update(modes(buf[-2 * TILE:-TILE]))

    pair_combos = collections.Counter()
    pair_tails = [collections.Counter() for _ in range(4)]
    pair_found = 0
    for n in nodes:
        if n["g1"] is None:
            continue
        p = M.chunk_path(n["g1"])
        if not os.path.isfile(p):
            continue
        pair_found += 1
        size = os.path.getsize(p)
        dec = decompose(size)
        pair_combos[dec if dec else ("FAIL", size % PS)] += 1
        if dec and dec[1] * PS >= 4 * TILE:
            buf = C.read(p)
            for k in range(4):
                lo = len(buf) - (4 - k) * TILE
                pair_tails[k].update(modes(buf[lo:lo + TILE]))

    print("\nprimary chunks on disk: %d / %d directory entries" %
          (prim_found, sum(1 for n in nodes if n["g0"] is not None)))
    print("decomposition (prefix, n x 4356 units):")
    for (which, pref, units), c in sorted(combos.items(), key=lambda kv: -kv[1]):
        print("   %-8s prefix %6d  units %4d   x%d" % (which, pref, units, c))
    if residual_fail:
        print("RESIDUAL FAILURES (size not prefix + k x 4356):")
        for k, s, r in residual_fail[:20]:
            print("   key 0x%X  size %d  mod4356 %d" % (k, s, r))
    else:
        print("   zero residual failures -- every primary chunk is prefix + k x 4356")

    print("\nBC7 modes, LAST 17424 B of primary chunks, by depth:")
    for dep in sorted(tail_tile):
        print("   depth %d  %s" % (dep, hstr(tail_tile[dep])))
    print("BC7 modes, the 17424 B BEFORE that (weight pages, control):")
    print("   %s" % hstr(pre_tile))
    print("distinct 16-B blocks in the tail tile (1089 = all distinct):")
    for k, c in sorted(tail_distinct.items(), key=lambda kv: -kv[1])[:8]:
        print("   %4d distinct  x%d" % (k, c))

    print("\npaired chunks on disk: %d" % pair_found)
    for dec, c in sorted(pair_combos.items(), key=lambda kv: -kv[1])[:10]:
        print("   %s  x%d" % (dec,), ) if False else print("   %s  x%d" % (str(dec), c))
    print("BC7 modes of the last four 17424-B segments of paired chunks:")
    for k in range(4):
        print("   seg[-%d]  %s" % (4 - k, hstr(pair_tails[k])))


if __name__ == "__main__":
    main()
