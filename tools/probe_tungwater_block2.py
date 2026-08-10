"""The river-water mechanism hunt, main suspect after the parent-transform
dead end: TERRAIN STREAMING-TREE BLOCK 2.

MAP-TUNGSTEN.md calls block 2 "density" (following TERRAIN.md's binder read)
and notes only its root Y range, 64.006..76.523. That band is exactly the
missing river's elevation. This probe decodes block 2's actual u16 payloads out
of the streaming chunks and tests, with numbers, whether block 2 is a WATER
SURFACE HEIGHTFIELD:

  T1  the decoded sample values, scaled y = u16/65536 * WorldSizeY, must land
      inside each node's own stored AABB Y range (heights, not densities);
  T2  water-minus-ground (block 2 minus block 0, same chunk, same grid) must be
      positive over connected channel-shaped regions and nowhere-a-few-metres
      everywhere else;
  T3  the positive-depth raster must reproduce the braided river channels
      (compare the emitted PNG/ASCII against the SDK overhead
      addons/bf_portal/terrain_decal/textures/MP_Tungsten.jpg and the L10
      raster from probe_tung_basefield.py);
  T4  along the flow the water level must be monotone-ish downhill.

Chunk layout MEASURED here (an ORDER correction to the study's decomposition,
which only proved the size multiset, not the order):

  primary chunk = [block-0 payload 149,297]
                  [weight pages x 4,356]
                  [block-2 payload 149,297 if the block-2 node at the same
                   key is External]
                  [0 or 2 x 17,424 colour tiles]

Found by structure: the bytes at +149,297 have 66-byte-stride u8 smoothness
(weight pages are raw 66x66 u8), while the row-major u16 heightfield begins
exactly at 149,297 + pages*4,356. 149,297 % 4,356 = 1,193 != 0, so the payload
count k is unambiguous per chunk size.

READ-ONLY.  Usage:  probe_tungwater_block2.py [level] [--png out.png]
"""
import os
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402
import probe_tung_colormap as CM     # noqa: E402

PAYLOAD = 149297     # xs=265 inline node payload (heights + section + density)
PAGE = 4356
TILE = 17424


def hf_nodes(d, off, size, h):
    nodes, kinds, slack, sizes = T.hf_walk(d, off, size, h)
    return {n[0]: n for n in nodes}, nodes


def grid_of(payload, xs):
    """u16 height grid xs*xs from an inline/external node payload."""
    return struct.unpack_from("<%dH" % (xs * xs), payload, 0)


def png_gray(path, w, hgt, rows):
    """rows: list of bytes() length w, top to bottom. 8-bit grayscale PNG."""
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    hdr = struct.pack(">IIBBBBB", w, hgt, 8, 0, 0, 0, 0)
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", hdr))
        fh.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        fh.write(chunk(b"IEND", b""))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 and not sys.argv[1].startswith("-") \
        else "mp_tungsten"
    png = None
    if "--png" in sys.argv:
        png = sys.argv[sys.argv.index("--png") + 1]

    td = T.terr_dir(level)
    d = C.read(T._res(td, ".TerrainStreamingTree"))
    hdr, blocks, after = T.container(d)
    bl = {t: (o, s) for t, o, s in blocks}
    if 2 not in bl:
        print("%s: NO block 2 in the streaming tree - nothing to decode" % level)
        return
    h0 = T.hf_header(d, bl[0][0])
    h2 = T.hf_header(d, bl[2][0])
    xs = h0["xs"]
    wy0, wy2 = h0["WorldSizeY"], h2["WorldSizeY"]
    print("%s  xs=%d  WorldSizeY block0=%.1f block2=%.1f" % (level, xs, wy0, wy2))

    n0, _ = hf_nodes(d, bl[0][0], bl[0][1], h0)
    n2, l2 = hf_nodes(d, bl[2][0], bl[2][1], h2)
    ext2 = [n for n in l2 if n[4] == "External"]
    print("block2 nodes: %d  External %d  Empty %d  Packed %d"
          % (len(l2), len(ext2), sum(1 for n in l2 if n[4] == "Empty"),
             sum(1 for n in l2 if n[4] == "Packed")))

    dirnodes, _end = CM.chunk_dir(d, after)
    bykey = {n["key"]: n for n in dirnodes}

    # census: how many chunks carry k=2 payloads (expected ~= External block-2)
    k2chunks = 0
    for n in dirnodes:
        if n["g0"] is None:
            continue
        p = CM.chunk_path(n["g0"])
        if not os.path.isfile(p):
            continue
        sz = os.path.getsize(p)
        for k in (0, 1, 2):
            r = sz - k * PAYLOAD
            if r >= 0 and r % PAGE in (0, (2 * TILE) % PAGE):
                # 2*TILE = 34848 = 8*PAGE, so tiles fold into pages: r % PAGE == 0
                pass
        if sz >= 2 * PAYLOAD and (sz - 2 * PAYLOAD) % PAGE == 0:
            k2chunks += 1
    print("chunks whose size decomposes with TWO height payloads: %d" % k2chunks)

    # decode every External block-2 node
    world = 4096.0
    res = 512                       # depth raster resolution over the world
    depth_img = [[0] * res for _ in range(res)]
    wl_img = [[0] * res for _ in range(res)]
    stats = []
    t1_ok = t1_bad = 0
    for key, dep, mn, mx, kind in ext2:
        dn = bykey.get(key)
        if dn is None or dn["g0"] is None:
            continue
        p = CM.chunk_path(dn["g0"])
        if not os.path.isfile(p):
            continue
        buf = C.read(p)
        if len(buf) < 2 * PAYLOAD or (len(buf) - 2 * PAYLOAD) % PAGE:
            print("  key 0x%X: chunk has no second payload (size %d)" % (key, len(buf)))
            continue
        # tiles, when present, are the LAST 2*17,424; block-2 sits before them.
        # 2*TILE == 8*PAGE so size alone cannot distinguish "2 tiles" from
        # "8 more pages": pick the candidate whose interior u16s scale into the
        # node's own stored AABB Y band (dry texels hold the band floor, so a
        # correct slice is ~100% in-band; tiles/pages are not).
        lo16 = int((mn[1] - 0.5) / wy2 * 65536)
        hi16 = int((mx[1] + 0.5) / wy2 * 65536)

        def inband(off):
            g = struct.unpack_from("<%dH" % (xs * xs), buf, off)
            pick = [g[(j + 4) * xs + (i + 4)]
                    for j in range(0, xs - 8, 13) for i in range(0, xs - 8, 13)]
            return sum(1 for v in pick if lo16 <= v <= hi16) / float(len(pick))
        cands = [len(buf) - PAYLOAD]
        if len(buf) >= 2 * PAYLOAD + 2 * TILE:
            cands.append(len(buf) - 2 * TILE - PAYLOAD)
        off2 = max(cands, key=inband)
        g0 = grid_of(buf[0:PAYLOAD], xs)
        g2 = grid_of(buf[off2:off2 + PAYLOAD], xs)
        # interior samples (4-pad border), xs-8 = 257 samples across node
        n = xs - 8
        vals = []
        b0n = n0.get(key)
        step = (mx[0] - mn[0]) / (n - 1)
        submerged = 0
        tot = 0
        dmax = 0.0
        for j in range(n):
            for i in range(n):
                v2 = g2[(j + 4) * xs + (i + 4)] / 65536.0 * wy2
                v0 = g0[(j + 4) * xs + (i + 4)] / 65536.0 * wy0
                vals.append(v2)
                dd = v2 - v0
                tot += 1
                if dd > 0.02:
                    submerged += 1
                    if dd > dmax:
                        dmax = dd
                    wx = mn[0] + i * step
                    wz = mn[2] + j * step
                    px = int((wx + world / 2) / world * (res - 1))
                    pz = int((wz + world / 2) / world * (res - 1))
                    depth_img[pz][px] = max(depth_img[pz][px],
                                            min(255, int(dd * 40) + 40))
                    wl_img[pz][px] = max(wl_img[pz][px],
                                         min(255, int((v2 - 60.0) * 12)))
        vmin, vmax = min(vals), max(vals)
        pad = 0.05
        ok = (vmin >= mn[1] - pad) and (vmax <= mx[1] + pad)
        t1_ok += ok
        t1_bad += not ok
        stats.append((key, dep, mn, mx, vmin, vmax, submerged, tot, dmax))

    print("\nT1  decoded-value range inside stored node AABB-Y: %d ok / %d bad"
          % (t1_ok, t1_bad))
    print("\nper-node (External):")
    print("  key           d  x..            z..            aabbY          "
          "decoded Y      wet%%   maxDepth")
    for key, dep, mn, mx, vmin, vmax, sub, tot, dmax in sorted(
            stats, key=lambda s: (s[2][2], s[2][0])):
        print("  0x%-10X %d  %6.0f..%-6.0f %6.0f..%-6.0f %6.2f..%-7.2f"
              " %6.2f..%-7.2f %5.1f  %6.2f"
              % (key, dep, mn[0], mx[0], mn[2], mx[2], mn[1], mx[1],
                 vmin, vmax, 100.0 * sub / tot, dmax))

    allsub = sum(s[6] for s in stats)
    alltot = sum(s[7] for s in stats)
    print("\nT2  samples with water above ground (>2 cm): %d of %d = %.2f%%"
          % (allsub, alltot, 100.0 * allsub / alltot if alltot else 0))

    if png:
        rows = [bytes(r) for r in depth_img]
        png_gray(png, res, res, rows)
        print("depth raster written  %s  (white = deep water)" % png)
        wl = png.replace(".png", "_level.png")
        png_gray(wl, res, res, [bytes(r) for r in wl_img])
        print("water-level raster    %s  (brightness = surface Y above 60 m)" % wl)

    # T3 quick ASCII: 96x96 downsample of the wet mask
    a = 96
    print("\nT3  wet-mask ASCII (%dx%d, '#'=water above ground):" % (a, a))
    for zz in range(a):
        row = []
        for xx in range(a):
            s = 0
            for dz in range(res // a):
                for dx in range(res // a):
                    if depth_img[zz * (res // a) + dz][xx * (res // a) + dx]:
                        s += 1
            row.append("#" if s > 0 else ".")
        print("   " + "".join(row))


if __name__ == "__main__":
    main()
