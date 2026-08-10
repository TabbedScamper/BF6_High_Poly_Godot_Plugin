"""Q1 -- THE PER-MAP TEXTURED-LAYER TABLE.

For every level: every ground layer that binds a colour (_cv) texture, base or
painted, with the slot hash it binds it at, its tiling constants and its page
counts from the splat metadata tree (block 1).  This is what the plugin's
composite step will be built from.

Usage:  probe_painted_table.py [level|all|all+granite] [--full]

    --full   also print colourless layers (constants-only rows)

Writes %TEMP%/bf6_painted/<level>.json for the census probes.
READ-ONLY on game data.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_painted_common as PC    # noqa: E402


def fmt_tiling(row):
    out = []
    for h in PC.TILING_HASHES:
        key = "%08x" % h
        if key in row["consts"]:
            ty, val = row["consts"][key]
            try:
                out.append("%08X=%g" % (h, val))
            except TypeError:
                out.append("%08X=%s" % (h, val))
    return " ".join(out)


def one(level, gi, full=False):
    doc = PC.level_layers(level, gi)
    PC.save_level(doc)
    n = doc["layer_count"]
    rows = doc["rows"]
    cv_rows = [r for r in rows if PC.albedo_of(r)[0]]
    tex_rows = [r for r in rows if any(not str(p).startswith("(")
                                       for p in r["textures"].values())]
    print("=" * 100)
    print("%s  layers=%d  keys_resolved=%d/%d  cv-bearing=%d  any-texture=%d"
          % (level, n, doc["keys_resolved"], n, len(cv_rows), len(tex_rows)))
    print("  depot %s" % doc["depot"])
    for r in rows:
        slot, cv = PC.albedo_of(r)
        if not full and slot is None and not r["textures"]:
            continue
        side = []
        if r["painted_pages"]:
            side.append("painted x%d" % r["painted_pages"])
        if r["base_pages"]:
            side.append("BASE x%d" % r["base_pages"])
        print("-" * 100)
        print("L%02d  %-24s  %s" % (r["idx"], ", ".join(side) or "unused",
                                    "ALBEDO @%s %s" % (slot, os.path.basename(cv))
                                    if slot else "(no _cv)"))
        for nh, p in sorted(r["textures"].items()):
            name = PC.KNOWN_SLOTS.get(int(nh, 16), "?")
            print("     tex   %s %-12s %s" % (nh, name, p))
        t = fmt_tiling(r)
        if t:
            print("     tiling %s" % t)
        key = "%08x" % PC.TINT_HASH
        if key in r["consts"]:
            print("     tint  4FDCF6B1 = %s" % (r["consts"][key][1],))
    return doc


def main():
    full = "--full" in sys.argv
    levels = PC.roster(sys.argv)
    gi = PC.load_guid_index()
    summary = []
    for lv in levels:
        try:
            doc = one(lv, gi, full)
        except SystemExit as e:
            print("%s: %s" % (lv, e))
            continue
        rows = doc["rows"]
        cv = sum(1 for r in rows if PC.albedo_of(r)[0])
        cvp = sum(1 for r in rows if PC.albedo_of(r)[0] and r["painted_pages"])
        cvb = sum(1 for r in rows if PC.albedo_of(r)[0]
                  and r["base_pages"] and not r["painted_pages"])
        summary.append((lv, doc["layer_count"], cv, cvp, cvb))
    print()
    print("=" * 76)
    print("%-24s %7s %8s %11s %10s" % ("level", "layers", "cv", "cv-painted",
                                       "cv-base"))
    for lv, n, cv, cvp, cvb in summary:
        print("%-24s %7d %8d %11d %10d" % (lv, n, cv, cvp, cvb))


if __name__ == "__main__":
    main()
