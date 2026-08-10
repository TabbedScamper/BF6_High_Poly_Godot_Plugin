"""Q5 -- CROSS-MAP DEPOT CONTENT SHARING: how much of the fleet's layer-depot
content is duplicated, and what the right GLOBAL cache key for decoded layer
slices is.

Motivating observations (MAP-LIMESTONE.md / MAP-FIRESTORM.md): Limestone
L37/L38 byte-match Tungsten L30/L31, and firestorm L15's ShaderBlockKey equals
tungsten L10's -- the keys look like content hashes. This probe MEASURES that
across all 17 levels:

  * of all TEXTURED-layer depot records bound by the fleet's layer tables, how
    many distinct contents exist vs total rows (the dedupe ratio);
  * whether ShaderBlockKey, record content_hash, resolved texture-set and
    resolved (textures+consts) partition the rows identically;
  * whether equal content_hash across two maps' depots means BYTE-identical
    record payloads (checked exhaustively, not sampled);
  * the same census for textureless rows, and for single textures (the unit the
    plugin actually decodes).

Requires probe_painted_table.py to have cached every level (it has).
READ-ONLY on game data; prints only.

Usage:  probe_painted_dedupe.py [all|all+granite|level]
"""
import collections
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_painted_common as PC     # noqa: E402
import shaderblock as sb              # noqa: E402


def is_textured(row):
    return any(not str(p).startswith("(") for p in row["textures"].values())


def content_sig(row):
    """Canonical resolved content: textures + consts (order-free)."""
    return json.dumps({"t": sorted(row["textures"].items()),
                       "c": sorted((k, v) for k, v in row["consts"].items())},
                      sort_keys=True)


def main():
    levels = PC.roster(sys.argv)
    docs = {}
    for lv in levels:
        d = PC.load_level(lv)
        if d is None:
            print("%s: NO CACHE (run probe_painted_table.py)" % lv)
            continue
        docs[lv] = d

    # --- per-row census over the fleet ------------------------------------
    rows_all = []          # (level, row)
    for lv, d in docs.items():
        for r in d["rows"]:
            if r.get("content_hash") is None:
                continue                       # key unresolved in depot
            rows_all.append((lv, r))
    tex_rows = [(lv, r) for lv, r in rows_all if is_textured(r)]
    notex_rows = [(lv, r) for lv, r in rows_all if not is_textured(r)]

    def census(rows, tag):
        keys = collections.Counter(r["key"] for _, r in rows)
        chash = collections.Counter(r["content_hash"] for _, r in rows)
        tset = collections.Counter(
            json.dumps(sorted(r["textures"].items()), sort_keys=True)
            for _, r in rows)
        sig = collections.Counter(content_sig(r) for _, r in rows)
        n = len(rows)
        print("%s rows %d | distinct ShaderBlockKey %d | content_hash %d | "
              "texture-set %d | textures+consts %d"
              % (tag, n, len(keys), len(chash), len(tset), len(sig)))
        return keys, chash, tset, sig

    print("=" * 100)
    print("fleet census over %d levels (%d layer-table rows resolved in depots)"
          % (len(docs), len(rows_all)))
    k_t, h_t, ts_t, sig_t = census(tex_rows, "  TEXTURED  ")
    census(notex_rows, "  textureless")

    # --- do the partitions agree? -----------------------------------------
    key2 = collections.defaultdict(set)      # key -> content hashes
    h2sig = collections.defaultdict(set)     # content_hash -> resolved sigs
    h2key = collections.defaultdict(set)
    ts2h = collections.defaultdict(set)      # texture-set -> content hashes
    for lv, r in tex_rows:
        key2[r["key"]].add(r["content_hash"])
        h2sig[r["content_hash"]].add(content_sig(r))
        h2key[r["content_hash"]].add(r["key"])
        ts2h[json.dumps(sorted(r["textures"].items()),
                        sort_keys=True)].add(r["content_hash"])
    print()
    print("partition agreement (textured rows):")
    print("  keys mapping to >1 content_hash      : %d"
          % sum(1 for v in key2.values() if len(v) > 1))
    print("  content_hashes with >1 resolved sig  : %d"
          % sum(1 for v in h2sig.values() if len(v) > 1))
    print("  content_hashes reached by >1 key     : %d"
          % sum(1 for v in h2key.values() if len(v) > 1))
    multi_ts = {t: v for t, v in ts2h.items() if len(v) > 1}
    print("  texture-sets built with >1 content   : %d  (same textures, "
          "different consts -> texture-set alone under-keys)" % len(multi_ts))
    for t, v in sorted(multi_ts.items())[:6]:
        first = json.loads(t)
        name = os.path.basename(first[0][1]) if first else "(none)"
        print("      e.g. %-38s x%d contents" % (name, len(v)))

    # --- byte-identity check across depots (exhaustive) -------------------
    # collect the raw record payload for every (level, content_hash) pair
    print()
    print("byte-identity across depots for shared content_hash (textured rows):")
    per_hash = collections.defaultdict(dict)    # chash -> level -> row
    for lv, r in tex_rows:
        per_hash[r["content_hash"]].setdefault(lv, r)
    shared = {h: m for h, m in per_hash.items() if len(m) > 1}
    print("  content_hashes on 2+ levels: %d of %d" % (len(shared), len(per_hash)))
    depot_bytes = {}
    for lv in docs:
        d = docs[lv]
        p = os.path.join(d["terr_dir"], d["depot"])
        depot_bytes[lv] = PC.read(p)
        dep = sb.parse_depot(p)
        docs[lv]["_recs"] = {r.index: (r.data_offset, r.size, r.content_hash)
                             for r in dep.records}
    same = diff = 0
    for h, m in shared.items():
        blobs = set()
        for lv, r in m.items():
            off, size, ch = docs[lv]["_recs"][r["record_index"]]
            blobs.add(depot_bytes[lv][off:off + size])
        if len(blobs) == 1:
            same += 1
        else:
            diff += 1
            print("    MISMATCH %s on %s" % (h, sorted(m)))
    print("  byte-identical: %d   byte-different: %d" % (same, diff))

    # --- how much cross-map reuse is there, concretely? -------------------
    print()
    print("cross-level sharing (textured rows, by content_hash):")
    lvcount = collections.Counter(len(m) for m in per_hash.values())
    for k in sorted(lvcount):
        print("    on %2d level(s): %4d contents" % (k, lvcount[k]))
    top = sorted(per_hash.items(), key=lambda kv: -len(kv[1]))[:10]
    for h, m in top:
        lv0, r0 = next(iter(m.items()))
        slot, cv = PC.albedo_of(r0)
        print("    %s  x%2d levels  %s" % (h, len(m),
              os.path.basename(cv) if cv else "(no cv)"))

    # --- the unit the plugin decodes: single textures ---------------------
    texcount = collections.Counter()
    for lv, r in tex_rows:
        for p in set(r["textures"].values()):
            if not str(p).startswith("("):
                texcount[p] += 1
    binds = sum(texcount.values())
    print()
    print("single-texture level: %d texture bindings across textured rows, "
          "%d distinct texture paths (ratio %.2fx)"
          % (binds, len(texcount), binds / max(1, len(texcount))))

    n = len(tex_rows)
    print()
    print("=== dedupe ratio (textured rows): %d rows -> %d distinct contents "
          "= %.2fx (%.0f%% of rows are re-binds)"
          % (n, len(h_t), n / max(1, len(h_t)),
             100.0 * (n - len(h_t)) / max(1, n)))


if __name__ == "__main__":
    main()
