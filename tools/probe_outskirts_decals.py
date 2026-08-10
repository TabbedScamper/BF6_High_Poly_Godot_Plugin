"""MP_Outskirts' TerrainDecals -- which does NOT use the dumbo record layout.

probe_tung_decals.py (TERRAIN.md 10.2's dumbo-verified layout: [u32 propSize]
[props][pad][0x90 tail]) parses 0 of outskirts' 484 records: the first record
starts not with a propSize but with a 16-byte identifier. Observed layout of
the outskirts variant (record boundaries confirmed by the repeating identifier
+ 16-zero-byte signature; NOT fully reverse-engineered):

    +0x00  16 B   record identifier (12 significant bytes + 4 zero); repeats
                  across records sharing a material
    +0x10  16 B   zeros
    +0x20  u32s   counts (varies)
    +0x28  f32    ~tiling (0.0099 on rec 0)
    +0x40  f32x3  AabbMin        +0x50  f32x3  AabbMax
    ...    geometry fields, then a property stream carrying the SAME u64 slot
           hashes (0x3810287D4CE70B49 _op, ...) and typeId 0xCC84D53D texture
           refs as TERRAIN.md 10.3 -- the props moved to the record's END.

A record-start signature scan was tried and is UNRELIABLE (the id+zero-pad
pattern also occurs inside records, and not every record matches it), so this
probe reports only what is solid: the slot table, the per-slot-hash property
occurrence counts (which match the declared record count exactly), and an
annotated dump of the first record. Full record layout: unknown.

Usage:  probe_outskirts_decals.py [level]
"""
import collections
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C        # noqa: E402
import probe_tung_terrain as T       # noqa: E402


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_outskirts"
    td = T.terr_dir(level)
    dec = None
    for dirpath, _d, files in os.walk(td):
        for fn in files:
            if fn.endswith(".TerrainDecals"):
                dec = os.path.join(dirpath, fn)
    d = C.read(dec)
    slot_count = struct.unpack_from("<I", d, 0x10)[0]
    o = 0x14
    slots = []
    for i in range(slot_count):
        slots.append(d[o:o + 16])
        o += 16
    rec_count = struct.unpack_from("<I", d, o)[0]
    o += 4
    print("%s: slotCount %d (%d with GUID), declared recordCount %d"
          % (level, slot_count, sum(1 for s in slots if s != b"\0" * 16), rec_count))
    for i, s in enumerate(slots):
        if s != b"\0" * 16:
            g = "%08x-%04x-%04x-%s-%s" % (struct.unpack_from("<IHH", s, 0)
                                          + (s[4+2+2:10].hex(), s[10:16].hex()))
            print("   slot %2d  guid %s  -> %s" % (i, g, C.af_leaf(g)))

    # first record, annotated (record boundaries beyond the first two are
    # not reliably recoverable without the real layout)
    print("\nfirst record @ 0x%X:" % o)
    print(C.hexdump(d, o, 0x60))
    mn = struct.unpack_from("<3f", d, o + 0x40)
    mx = struct.unpack_from("<3f", d, o + 0x50)
    print("   +0x40 AabbMin (%.2f, %.2f, %.2f)   +0x50 AabbMax (%.2f, %.2f, %.2f)"
          % (mn + mx))

    # property-stream texture hashes present anywhere in the record region.
    # each record carries exactly one _op prop, so the _op count is an
    # independent record count.
    for name, h in (("_cv", 0x399AC0336ACFE03C), ("_nhs", 0x567A9BC35CCBB1B2),
                    ("_ao", 0x3A411B3E209FC9E2), ("_op", 0x3810287D4CE70B49)):
        needle = struct.pack("<Q", h)
        cnt = d.count(needle)
        print("   prop hash %-4s occurs %d times" % (name, cnt))


if __name__ == "__main__":
    main()
