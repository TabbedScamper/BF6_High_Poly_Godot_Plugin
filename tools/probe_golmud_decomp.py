"""MP_GolmudRailway: the decomposition table for detect_layout's cross-map fix.

Answers, with exact arithmetic and no scoring heuristics:
  * the map's true splat page size (candidates 2592 / 4356 / 5184);
  * the distinct chunk residuals (primary_size - pages*ps) and each residual's
    [height prefix] + [k x colour tile] decomposition;
  * the trailer's tile size and count, verified by the BC7 mode test
    (a real colour tile is ~98% modes 4-7; a degenerate one is not);
  * the same for paired chunks.

Method is MAP-TUNGSTEN.md C1: require size = prefix + pages*ps + k*tile to hold
EXACTLY (zero residual) for every chunk, where prefix is a small non-negative
combination of the heightfield payload sizes and tile is 17424 or 4624.

Usage:  probe_golmud_decomp.py [level]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402

TILES = (17424, 8712, 4624)   # 8712 = 132^2 BC1, golmud's tile (see bc1color)
PAGE_SIZES = (2592, 4356, 5184)


def bc7_hi(buf):
    """fraction of 16-byte blocks in BC7 modes 4-7."""
    tot = hi = 0
    for i in range(0, len(buf) - 15, 16):
        b = buf[i]
        tot += 1
        if b and (b & 0x0F) == 0:
            hi += 1
    return (100.0 * hi / tot) if tot else 0.0, tot


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_golmudrailway"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    # heightfield payload sizes present on this map (block 0 walk sizes)
    hf_sizes = set()
    for t, off, size_b in blocks:
        if t in (0, 2):
            h = T.hf_header(d, off)
            _n, _k, _s, sz = T.hf_walk(d, off, size_b, h)
            hf_sizes.add(sz["inline"])
            hf_sizes.add(sz["density"])
    print("%s: %d directory nodes; heightfield payload sizes %s"
          % (level, len(nodes), sorted(hf_sizes)))

    # prefix set: 0..3 of each payload size (sums of two occur on tungsten)
    payloads = sorted(hf_sizes)
    prefixes = {0: "0"}
    for a in range(0, 4):
        for b in range(0, 4):
            v = a * payloads[-1] + b * (payloads[0] if len(payloads) > 1 else 0)
            if v and v not in prefixes:
                tag = []
                if a:
                    tag.append("%dx%d" % (a, payloads[-1]))
                if b and len(payloads) > 1:
                    tag.append("%dx%d" % (b, payloads[0]))
            if v and v not in prefixes:
                prefixes[v] = "+".join(tag)
    # plus the tungsten-documented values, in case golmud reuses them verbatim
    for v in (39919, 149297, 189216):
        prefixes.setdefault(v, "doc:%d" % v)

    sizes = collections.Counter()
    for n in nodes:
        for which, g in (("primary", n["g0"]), ("paired", n["g1"])):
            if g is None:
                continue
            p = M.chunk_path(g)
            if os.path.isfile(p):
                sizes[(which, os.path.getsize(p))] += 1

    for ps in PAGE_SIZES:
        ok = bad = 0
        residuals = collections.Counter()
        for (which, s), cnt in sizes.items():
            found = None
            # smallest k, then smallest prefix, canonical
            for tile in TILES:
                for k in range(0, 7):
                    for pv in sorted(prefixes):
                        rem = s - pv - k * tile
                        if rem >= 0 and rem % ps == 0:
                            found = (pv, k, tile, rem // ps)
                            break
                    if found:
                        break
                if found:
                    break
            if found:
                ok += cnt
                residuals[(which, found[0], found[1], found[2])] += cnt
            else:
                bad += cnt
        print("-" * 76)
        print("page size %d: %d chunks decompose exactly, %d do NOT" % (ps, ok, bad))
        if bad == 0:
            for (which, pv, k, tile), cnt in sorted(residuals.items(),
                                                    key=lambda kv: -kv[1])[:12]:
                print("   x%-5d %-7s prefix %-8d (%s) + %d x %d tile"
                      % (cnt, which, pv, prefixes.get(pv, "?"), k, tile))

    # ---- trailer truth: BC7 mode test on candidate tile positions -----------
    print("=" * 76)
    agg = collections.defaultdict(lambda: [0, 0])   # tag -> [hi-blocks, tot]
    uniq = collections.Counter()
    tested = 0
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        for tag, seg in (
                ("last 4624", buf[-4624:]),
                ("prev 4624", buf[-9248:-4624]),
                ("last 17424", buf[-17424:]),
                ("prev 17424", buf[-34848:-17424]),
        ):
            if len(seg) < 4624:
                continue
            pct, tot = bc7_hi(seg)
            agg[tag][0] += int(round(pct * tot / 100.0))
            agg[tag][1] += tot
            if tag in ("last 4624", "prev 4624"):
                uniq[(tag, len(set(seg[i:i + 16]
                                   for i in range(0, len(seg) - 15, 16))))] += 1
        tested += 1
    print("BC7 mode test over %d primary chunks:" % tested)
    for tag in ("last 4624", "prev 4624", "last 17424", "prev 17424"):
        hi, tot = agg[tag]
        print("   %-11s  %8d blocks  modes4-7 %5.1f%%"
              % (tag, tot, 100.0 * hi / tot if tot else 0))
    dis = collections.Counter()
    for (tag, ndis), cnt in uniq.items():
        dis[tag] += cnt * ndis
    for tag in ("last 4624", "prev 4624"):
        tot = sum(cnt for (t, _n), cnt in uniq.items() if t == tag)
        s = sum(nd * cnt for (t, nd), cnt in uniq.items() if t == tag)
        print("   %-11s  mean distinct blocks per tile %.0f (of 289)"
              % (tag, s / tot if tot else 0))


if __name__ == "__main__":
    main()
