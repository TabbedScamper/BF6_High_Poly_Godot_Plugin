"""MP_GolmudRailway chunk-size structure, no assumptions.

Prints the primary/paired chunk size histogram, residues mod the candidate page
sizes, and hexdump-level structure of a few representative chunks, to find the
map's real [prefix][pages][trailer] shape before claiming any decomposition.

Usage: probe_golmud_sizes.py [level] [--paired]
"""
import collections
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_golmudrailway"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    prim = collections.Counter()
    pair = collections.Counter()
    depth_of = {}
    for n in nodes:
        if n["g0"] is not None:
            p = M.chunk_path(n["g0"])
            if os.path.isfile(p):
                s = os.path.getsize(p)
                prim[s] += 1
                depth_of.setdefault(s, collections.Counter())[n["depth"]] += 1
        if n["g1"] is not None:
            p = M.chunk_path(n["g1"])
            if os.path.isfile(p):
                pair[os.path.getsize(p)] += 1

    print("%s: %d primary sizes (%d chunks), %d paired sizes (%d chunks)"
          % (level, len(prim), sum(prim.values()), len(pair), sum(pair.values())))
    print("primary size histogram (top 40 by count):")
    for s, c in sorted(prim.items(), key=lambda kv: -kv[1])[:40]:
        print("   %9d  x%-5d depths %s  mod2592=%-5d mod4356=%-5d mod5184=%d"
              % (s, c, dict(depth_of[s]), s % 2592, s % 4356, s % 5184))
    print("smallest primary sizes:")
    for s in sorted(prim)[:10]:
        print("   %9d x%d" % (s, prim[s]))
    print("paired size histogram (top 20):")
    for s, c in sorted(pair.items(), key=lambda kv: -kv[1])[:20]:
        print("   %9d  x%-5d mod2592=%-5d mod4356=%d" % (s, c, s % 2592, s % 4356))


if __name__ == "__main__":
    main()
