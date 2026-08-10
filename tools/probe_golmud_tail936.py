"""What the 936-byte chunk tail on MP_GolmudRailway actually is.

Golmud's primary chunks fall in exactly three residue classes mod 2592:
0, 936, and 2489 (= 149297 height prefix + 936). TERRAIN.md 5.2 mentions a
"(opt. +936 tail)" once and never decodes it. This probe looks at the bytes.

For a sample of chunks in each class it prints: the tail's byte histogram
entropy, distinct 8/16-byte block counts, BC7/BC4 plausibility, first/last
hexdump rows, and whether the SAME 936 bytes repeat across nodes.

Usage: probe_golmud_tail936.py [level]
"""
import collections
import hashlib
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as M      # noqa: E402


def entropy(b):
    h = collections.Counter(b)
    n = len(b)
    return -sum(c / n * math.log2(c / n) for c in h.values())


def describe(tag, seg):
    d8 = len(set(seg[i:i + 8] for i in range(0, len(seg) - 7, 8)))
    d16 = len(set(seg[i:i + 16] for i in range(0, len(seg) - 15, 16)))
    bc7 = M.bc7_modes(seg)
    tot = sum(bc7.values())
    hi = sum(c for m, c in bc7.items() if isinstance(m, int) and m >= 4)
    print("  %-18s ent %.2f  d8 %d/%d  d16 %d/%d  bc7modes47 %4.1f%%  sha1 %s"
          % (tag, entropy(seg), d8, len(seg) // 8, d16, len(seg) // 16,
             100.0 * hi / tot if tot else 0,
             hashlib.sha1(seg).hexdigest()[:12]))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_golmudrailway"
    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    nodes, _e = M.chunk_dir(d, after)

    by_class = collections.defaultdict(list)
    for n in nodes:
        if n["g0"] is None:
            continue
        p = M.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        s = os.path.getsize(p)
        by_class[s % 2592].append((n, p, s))

    print("classes: %s" % {k: len(v) for k, v in sorted(by_class.items())})

    tail_hashes = collections.Counter()
    seen = 0
    for n, p, s in by_class.get(936, []):
        buf = C.read(p)
        tail_hashes[hashlib.sha1(buf[-936:]).hexdigest()[:12]] += 1
        seen += 1
    print("distinct 936-tails across %d class-936 chunks: %d"
          % (seen, len(tail_hashes)))
    print("most common:", tail_hashes.most_common(3))

    # also: the tail could be a PREFIX instead. compare first 936 after height
    # prefix vs last 936 for a few chunks
    for cls, samples in ((936, by_class.get(936, [])[:3]),
                         (2489, by_class.get(2489, [])[:3]),
                         (0, by_class.get(0, [])[:2])):
        for n, p, s in samples:
            buf = C.read(p)
            print("-" * 76)
            print("chunk %s  size %d  class %d  node key 0x%X depth %d"
                  % (os.path.basename(p)[:12], s, cls, n["key"], n["depth"]))
            pre = 149297 if cls == 2489 else 0
            describe("head936(post-hf)", buf[pre:pre + 936])
            describe("tail936", buf[-936:])
            describe("tail-1 page2592", buf[-936 - 2592:-936])
            describe("head page2592", buf[pre + 936:pre + 936 + 2592]
                     if cls != 0 else buf[:2592])
            print("  tail first 48:  %s" % buf[-936:-936 + 48].hex())
            print("  tail last  48:  %s" % buf[-48:].hex())


if __name__ == "__main__":
    main()
