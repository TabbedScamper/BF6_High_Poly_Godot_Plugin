"""MP_Tungsten's terrain, read straight out of the shipped resources.

Implements the parts of `formats/TERRAIN.md` needed to answer four questions
without guessing:

  * where the ground actually is in Y (block 0 node AABBs) -- which decides
    whether the level's single water plane at y = 0 is buried or is the river;
  * how many ground layers there are, how many carry a weight page and how many
    are base (no-page) layers (block 1 metadata, TERRAIN.md 5.1);
  * what the block-7 material-pair footer holds (TERRAIN.md 7.4 / 8);
  * the layer table and the layer-combination record (TERRAIN.md 9.1 / 9.2).

Usage:  probe_tung_terrain.py [level] [--nodes]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402


def terr_dir(level):
    """The terrain sub-directory is NOT named consistently: mp_tungsten uses
    `terrain_mp_tungsten`, mp_dumbo uses `mp_dumbo_terrain`. Find it."""
    root = os.path.join(C.LEVELS, level)
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d)
        if os.path.isdir(p) and "terrain" in d.lower():
            if any(f.endswith(".TerrainStreamingTree") for f in os.listdir(p)):
                return p
    return os.path.join(root, "terrain_%s" % level)


def _res(td, suffix):
    for f in sorted(os.listdir(td)):
        if f.endswith(suffix):
            return os.path.join(td, f)
    return None


def _u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def _i32(d, o):
    return struct.unpack_from("<i", d, o)[0]


def _f32(d, o):
    return struct.unpack_from("<f", d, o)[0]


# --- 2.1 container + 2.2 typed block loop ------------------------------------
def container(d):
    hdr = {
        "UnblurredSamplesPerNodeSidePot": _i32(d, 0x00),
        "ResourceBlurriness": _i32(d, 0x0D),
        "Unknown0x11": _i32(d, 0x11),
        "NodeCount": _i32(d, 0x19),
        "PersistentNodeCount": _i32(d, 0x1E),
    }
    blocks = []
    o = 0x22
    while o < len(d):
        t = d[o]
        if t == 0xFF:
            o += 1
            break
        sz = _i32(d, o + 1)
        blocks.append((t, o + 5, sz))
        o += 5 + sz
    return hdr, blocks, o


# --- 4.1/4.3 heightfield tree -------------------------------------------------
def hf_header(d, base):
    f = lambda k: _i32(d, base + k)
    return {
        "xs": f(0x00), "atlasX": f(0x04), "atlasY": f(0x08), "blurriness": f(0x0C),
        "WorldSizeY": _f32(d, base + 0x10),
        "PhysicsMetersPerSample": _f32(d, base + 0x14),
        "MinMaxStackDepth": f(0x1C), "OccluderGridStackDepth": f(0x20),
        "DensityMapNodeSamplesPerSide": f(0x24),
        "NodeCount": f(0x34), "PersistentNodeCount": f(0x38),
        "NodeBorderWidth": f(0x44),
    }


def _stack(depth, occluder):
    if depth <= 0:
        return 0
    b0 = 1 << (depth - 1)
    tot = 0
    for c in range(depth):
        b = b0 >> c
        tot += (b + 1) ** 2 if occluder else 2 * b * b
    return tot


def hf_walk(d, base, size, h):
    """Pre-order DFS. Returns (nodes, kinds) where nodes carry world AABBs."""
    packed = _stack(h["MinMaxStackDepth"], False) * 2
    section = packed + _stack(h["OccluderGridStackDepth"], True) * 2
    density = h["DensityMapNodeSamplesPerSide"] ** 2
    inline = h["xs"] ** 2 * 2 + section + density
    end = base + size
    nodes = []
    kinds = collections.Counter()

    def node(o, key, depth):
        mn = struct.unpack_from("<3f", d, o)
        mx = struct.unpack_from("<3f", d, o + 12)
        o += 28
        kind = d[o]
        o += 1
        if kind == 1:
            kinds["Empty"] += 1
            nodes.append((key, depth, mn, mx, "Empty"))
            return o
        skip_packed = d[o]
        inline_values = d[o + 3]
        o += 4
        if skip_packed:
            kinds["Packed"] += 1
            k = "Packed"
            o += packed
        elif inline_values:
            kinds["Inline"] += 1
            k = "Inline"
            o += inline
        else:
            kinds["External"] += 1
            k = "External"
        nodes.append((key, depth, mn, mx, k))
        has_children = d[o]
        o += 1
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i, depth + 1)
        return o

    o = node(base + 0x48, 3, 0)
    return nodes, kinds, o - end, dict(packed=packed, section=section,
                                       density=density, inline=inline)


# --- 5.1 splat metadata -------------------------------------------------------
def splat_walk(d, base, size):
    hdr = {
        "ValidTexelHint": _u32(d, base + 0x00),
        "Version": _u32(d, base + 0x04),
        "bounds": struct.unpack_from("<4f", d, base + 0x18),
        "LayerSlotCount": _u32(d, base + 0x28),
        "NodeCount": _u32(d, base + 0x2C),
        "RecordCount": _u32(d, base + 0x30),
    }
    end = base + size
    painted = collections.Counter()
    basec = collections.Counter()
    nnode = 0
    nrec = 0

    def node(o, key):
        nonlocal nnode, nrec
        nnode += 1
        rc = struct.unpack_from("<H", d, o)[0]
        o += 6
        for _ in range(rc):
            li = struct.unpack_from("<H", d, o)[0]
            # record: u16 LayerIndex, u16 LayerId, f32x4 bounds, u16 Flags, 11 B
            flags = struct.unpack_from("<H", d, o + 20)[0]
            if flags & 0x0100:
                basec[li] += 1
            else:
                painted[li] += 1
            nrec += 1
            o += 33
        if rc == 0:
            return o + 1
        o += 1                      # t0
        has_children = d[o]
        o += 1
        if o < end:
            o += 1                  # t1 (omitted at exact block end)
        if has_children:
            for i in range(4):
                o = node(o, (key << 4) | i)
        return o

    o = node(base + 0x3D, 3)
    return hdr, painted, basec, nnode, nrec, o - end


# --- 7.4 block-7 footer -------------------------------------------------------
def raster_footer(d, base, size):
    """TERRAIN.md 7.4, read backwards from the block end:

        u32 pairCount
        pairCount x u32   materialPairIndices  (0x06YYXX80, or 0 = unused slot)
        u32               backgroundMaterialIndex     <- LAST u32 of the block

    pairCount is found by the only k for which the u32 k*4+8 bytes from the end
    equals k -- self-locating, no scan heuristics."""
    end = base + size
    bg = _u32(d, end - 4)
    for k in range(1, 129):
        o = end - 4 - k * 4 - 4
        if o < base:
            break
        if _u32(d, o) == k:
            entries = [_u32(d, o + 4 + i * 4) for i in range(k)]
            return k, entries, bg
    return None, [], bg


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    td = terr_dir(level)
    st = _res(td, ".TerrainStreamingTree")
    if not st or not os.path.isfile(st):
        print("no streaming tree at", st)
        return
    d = C.read(st)
    hdr, blocks, after = container(d)
    print("=" * 78)
    print("%s streaming tree  %d bytes" % (level, len(d)))
    for k, v in hdr.items():
        print("   %-32s %s" % (k, v))
    print("   blocks: %s" % ", ".join("type %d (%d B)" % (t, s) for t, _o, s in blocks))
    print("   chunk directory starts at 0x%X" % after)

    for t, off, size in blocks:
        if t in (0, 2):
            h = hf_header(d, off)
            nodes, kinds, slack, sizes = hf_walk(d, off, size, h)
            ys = [(n[2][1], n[3][1]) for n in nodes if n[4] != "Empty"]
            print("-" * 78)
            print("block %d (heightfield)  xs=%d  WorldSizeY=%.3f  NodeCount=%d"
                  % (t, h["xs"], h["WorldSizeY"], h["NodeCount"]))
            print("   sizes packed=%d section=%d density=%d inline=%d" % (
                sizes["packed"], sizes["section"], sizes["density"], sizes["inline"]))
            print("   walked %d nodes %s  slack=%d (0 == byte-exact)"
                  % (len(nodes), dict(kinds), slack))
            root = nodes[0]
            print("   root AABB  min (%.2f, %.2f, %.2f)  max (%.2f, %.2f, %.2f)"
                  % (root[2] + root[3]))
            if ys:
                print("   non-empty node Y range  %.3f .. %.3f"
                      % (min(a for a, _b in ys), max(b for _a, b in ys)))
                leaves = [n for n in nodes if n[4] != "Empty"]
                lo = min(leaves, key=lambda n: n[2][1])
                print("   lowest node: key 0x%X depth %d  minY %.3f  at x %.0f..%.0f z %.0f..%.0f"
                      % (lo[0], lo[1], lo[2][1], lo[2][0], lo[3][0], lo[2][2], lo[3][2]))
        elif t == 1:
            sh, painted, basec, nnode, nrec, slack = splat_walk(d, off, size)
            print("-" * 78)
            print("block 1 (splat)  LayerSlotCount=%d  NodeCount=%d  RecordCount=%d"
                  % (sh["LayerSlotCount"], sh["NodeCount"], sh["RecordCount"]))
            print("   bounds minX %.1f minZ %.1f maxX %.1f maxZ %.1f" % sh["bounds"])
            print("   walked %d nodes, %d records, slack=%d" % (nnode, nrec, slack))
            allly = sorted(set(painted) | set(basec))
            print("   %d distinct layer indices: %s" % (len(allly), allly))
            print("   painted (has weight page): %s"
                  % sorted(painted.items(), key=lambda kv: -kv[1]))
            print("   base (no page, bit8 set):  %s"
                  % sorted(basec.items(), key=lambda kv: -kv[1]))
        elif t == 7:
            n, entries, bg = raster_footer(d, off, size)
            dim = _u32(d, off)
            print("-" * 78)
            print("block 7 (material raster)  %d bytes  dim=%d  nodeCount=%d  levelMax=%d"
                  % (size, dim, _u32(d, off + 0x18), _u32(d, off + 0x20)))
            print("   coverage minX %.1f minZ %.1f maxX %.1f maxZ %.1f"
                  % struct.unpack_from("<4f", d, off + 8))
            print("   pairCount=%s   BackgroundMaterialIndex=0x%08X" % (n, bg))
            for i, e in enumerate(entries):
                X = (e >> 8) & 0xFF
                Y = (e >> 16) & 0xFF
                print("   pair %2d  0x%08X  X=0x%02X (lo %2d hi %2d)  Y=0x%02X (list %d, lvl %d)"
                      % (i, e, X, X & 0xF, X >> 4, Y, Y & 0xF, Y >> 4))
        elif t == 8:
            print("-" * 78)
            print("block 8 (mask raster)  %d bytes  dim=%d  nodeCount=%d  levelMax=%d  maskUnknown0=%d"
                  % (size, _u32(d, off), _u32(d, off + 0x18), _u32(d, off + 0x20),
                     _u32(d, off + 0x24)))

    # --- 9.1 layer graph table + 9.2 layer combinations ---------------------
    lg = _res(td, ".DE540C59")
    if lg and os.path.isfile(lg):
        g = C.read(lg)
        n = _u32(g, 8)
        print("-" * 78)
        print("LayerGraphs (0xDE540C59)  %d bytes  recordCount=%d" % (len(g), n))
        for start in range(12, len(g) - n * 32 + 1, 4):
            keys = [struct.unpack_from("<Q", g, start + i * 32 + 20)[0] for i in range(n)]
            if all(k != 0 for k in keys) and len(set(keys)) == n:
                print("   record table @ %d (%d records, all keys distinct)" % (start, n))
                for i in range(n):
                    b = start + i * 32
                    print("      L%02d  A=%08X B=%08X C=%08X  hash=%016X  key=%016X  D=%08X"
                          % (i, _u32(g, b), _u32(g, b + 4), _u32(g, b + 8),
                             struct.unpack_from("<Q", g, b + 12)[0],
                             struct.unpack_from("<Q", g, b + 20)[0], _u32(g, b + 28)))
                break

    vt = _res(td, ".VisualTerrain")
    if vt and os.path.isfile(vt):
        v = C.read(vt)
        print("-" * 78)
        print("VisualTerrain (0x1CA38E06)  %d bytes" % len(v))
        # locate the string region: first printable run >= 16 chars containing '/'
        i = 0
        strs = []
        while i < len(v):
            if 32 <= v[i] < 127:
                j = i
                while j < len(v) and 32 <= v[j] < 127:
                    j += 1
                s = v[i:j].decode("ascii")
                if len(s) >= 16 and "/" in s:
                    p = i
                    while p < len(v):
                        e = v.find(b"\0", p)
                        if e < 0:
                            break
                        t = v[p:e]
                        if not t or not all(32 <= c < 127 for c in t):
                            break
                        strs.append(t.decode("ascii"))
                        p = e + 1
                    tail = p
                    break
                i = j
            else:
                i += 1
        for s in strs:
            print("   shader  %s" % s)
        key = struct.unpack_from("<Q", v, tail)[0]
        cnt = _u32(v, tail + 8)
        print("   SurfaceShaderBlockKey 0x%016X   layerCount %d" % (key, cnt))
        p = tail + 12
        types = collections.Counter()
        for i in range(cnt):
            fl = v[p]
            lt = _u32(v, p + 1)
            types[fl] += 1
            if lt != 0xFFFFFFFF:
                print("      L%02d flag %d -> LINKS to L%02d" % (i, fl, lt))
            p += 5
        print("   layer flags: %s   record ends at %d of %d" % (dict(types), p, len(v)))


if __name__ == "__main__":
    main()
