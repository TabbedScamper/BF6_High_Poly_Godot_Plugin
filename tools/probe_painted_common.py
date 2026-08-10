"""Shared plumbing for the PAINTED-LAYER research probes (probe_painted_*.py).

READ-ONLY on game data. Reads the extracted 2026-08-01 pull whose root is owned
by BF6_Frostbite_Research/impl/pipeline/bf6_paths.py (the one source of truth),
plus the whole-dump guid cache built by probe_tung_guidscan.py (subtree ".").

Scope: task #94 -- the plugin is about to composite terrain textures for
PAINTED layers, not just base ones. These probes build the evidence:

    probe_painted_table.py     Q1  per-map textured-layer table (slots, tiling)
    probe_painted_coverage.py  Q2  per-layer texel coverage + slice budget
    probe_painted_slots.py     Q3  slot-hash -> meaning census across maps
    probe_painted_tint.py      Q4  0x4FDCF6B1 tint vs colour-map correlation
    probe_painted_dedupe.py    Q5  cross-map depot content sharing

Per-level results are cached as JSON under %TEMP%/bf6_painted so the census
probes and the write-up can re-read them without re-parsing the dump.
"""
import json
import os
import struct
import sys

# --- locate the research checkout and its pipeline modules -------------------
_CANDIDATE_RESEARCH = [
    r"C:\PortalSDK\BF6_Frostbite_Research",
    os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__)))), "BF6_Frostbite_Research"),
]
RESEARCH = None
for _c in _CANDIDATE_RESEARCH:
    if os.path.isdir(os.path.join(_c, "impl", "pipeline")):
        RESEARCH = _c
        break
if RESEARCH is None:
    raise SystemExit("BF6_Frostbite_Research checkout not found")
PIPELINE = os.path.join(RESEARCH, "impl", "pipeline")
sys.path.insert(0, PIPELINE)

import bf6_paths as P            # noqa: E402  -- THE source of truth for paths
import shaderblock as sb         # noqa: E402

BUNDLES = P.BUNDLES
GLACIERMP = os.path.join(BUNDLES, "game", "glaciermp", "levels")
GLACIERPORTAL = os.path.join(BUNDLES, "game", "glacierportal", "levels")
GLACIERGRANITE = os.path.join(BUNDLES, "game", "glaciergranite", "levels")

# The 17 fleet levels (one per MAP-*.md study). Granite's seven Portal slices
# share the base level's authored world; they are available as extras.
LEVELS = {}
for _n in ("mp_abbasid", "mp_aftermath", "mp_badlands", "mp_battery",
           "mp_capstone", "mp_contaminated", "mp_dumbo", "mp_eastwood",
           "mp_firestorm", "mp_golmudrailway", "mp_limestone", "mp_outskirts",
           "mp_plaza", "mp_subsurface", "mp_tungsten"):
    LEVELS[_n] = os.path.join(GLACIERMP, _n)
LEVELS["mp_portal_sand"] = os.path.join(GLACIERPORTAL, "mp_portal_sand")
LEVELS["mp_granite"] = os.path.join(GLACIERGRANITE, "mp_granite")

GRANITE_SLICES = {
    "mp_granite_%s_portal" % s: os.path.join(GLACIERPORTAL,
                                             "mp_granite_%s_portal" % s)
    for s in ("clubhouse", "mainstreet", "marina", "militaryrnd",
              "militarystorage", "techcampus", "underground")}

CACHE = os.path.join(os.environ.get("TEMP", "."), "bf6_painted")
GUIDSCAN_CACHE = os.path.join(os.environ.get("TEMP", "."), "bf6_tung_guidscan")

# --- known slot/constant hashes (from the fleet studies; the probes MEASURE
# their meaning again rather than trusting this table) ------------------------
KNOWN_SLOTS = {
    0x0929399A: "cv_near", 0x09293A41: "ao_near", 0x2E50567A: "nhs_near",
    0x2E5ACDA8: "cv_dist", 0x2E5ACDF3: "ao_dist", 0xF9B44F08: "nhs_dist",
    0x2E5B5189: "cv_set3", 0x2E5B51D2: "ao_set3", 0xF9C55709: "nhs_set3",
    0x304613CC: "ao_alt", 0xF860C3BE: "ao_alt2",
    0x09293810: "op_slot", 0x07A9B250: "ssm",
    0x0B725504: "breakup", 0xEB1B291C: "scatternoise",
    0xB6C7E795: "ncs_detail", 0xAE16A5C0: "crater_hfd",
}
TINT_HASH = 0x4FDCF6B1
TILING_HASHES = (0x5707A992, 0x2F9990B7, 0x37984D1E, 0x37984D1F,
                 0xD46383AC, 0xD46383AD)


def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def terr_dir(level):
    """The terrain sub-directory is not named consistently across levels
    (terrain_mp_tungsten / mp_dumbo_terrain / mp_portal_desert_terrain /
    mp_golmudrailway_terrain8k): find any dir holding a streaming tree."""
    root = LEVELS.get(level) or GRANITE_SLICES.get(level)
    if root is None or not os.path.isdir(root):
        raise SystemExit("no level root for %s" % level)
    for d in sorted(os.listdir(root)):
        p = os.path.join(root, d)
        if os.path.isdir(p) and "terrain" in d.lower():
            if any(f.endswith(".TerrainStreamingTree") for f in os.listdir(p)):
                return p
    raise SystemExit("no terrain dir under %s" % root)


def _res(td, suffix):
    for f in sorted(os.listdir(td)):
        if f.endswith(suffix):
            return os.path.join(td, f)
    return None


def load_guid_index():
    """The whole-dump guid cache written by `probe_tung_guidscan.py .`
    (guid -> bundles-relative .ebx path). 60 MB JSON; loaded once."""
    p = os.path.join(GUIDSCAN_CACHE, "..json")
    if not os.path.isfile(p):
        raise SystemExit("whole-dump guid cache missing -- run "
                         "probe_tung_guidscan.py . first (%s)" % p)
    with open(p, encoding="utf-8") as fh:
        gi = json.load(fh)
    return {k: (v[:-4] if v.endswith(".ebx") else v) for k, v in gi.items()}


def layer_table(td, dep):
    """probe_tung_layers.layer_table: the layergraph record table located by
    requiring EVERY record's ShaderBlockKey to resolve in the paired depot."""
    lg = _res(td, ".DE540C59") or _res(td, ".LayerGraphs")
    g = read(lg)
    n = struct.unpack_from("<I", g, 8)[0]
    ks = set(dep.key_to_record)
    best = None
    for start in range(0, len(g) - n * 32 + 1, 4):
        keys = [struct.unpack_from("<Q", g, start + i * 32 + 20)[0]
                for i in range(n)]
        hit = sum(1 for k in keys if k in ks)
        if best is None or hit > best[0]:
            best = (hit, start, keys)
        if hit == n:
            break
    hit, start, keys = best
    hashes = [struct.unpack_from("<Q", g, start + i * 32 + 12)[0]
              for i in range(n)]
    lods = [struct.unpack_from("<3I", g, start + i * 32)[0:3] +
            (struct.unpack_from("<I", g, start + i * 32 + 28)[0],)
            for i in range(n)]
    return n, keys, hashes, lods, hit


def splat_side_counts(td):
    """{layerIdx: (painted_pages, base_pages)} from streaming-tree block 1."""
    import collections
    st = _res(td, ".TerrainStreamingTree")
    d = read(st)
    pos = 34
    blocks = {}
    while d[pos] != 0xFF:
        t = d[pos]
        size = struct.unpack_from("<I", d, pos + 1)[0]
        blocks[t] = (pos + 5, size)
        pos += 5 + size
    off, size = blocks[1]
    end = off + size
    painted = collections.Counter()
    basec = collections.Counter()

    p = [off + 61]

    def rec():
        n, m, z = struct.unpack_from("<3H", d, p[0])
        p[0] += 6
        for _ in range(n):
            idx, = struct.unpack_from("<H", d, p[0])
            flags, = struct.unpack_from("<H", d, p[0] + 20)
            (basec if flags & 0x100 else painted)[idx] += 1
            p[0] += 33
        if n == 0:
            p[0] += 1
            return
        hc = d[p[0] + 1]
        p[0] += 3
        if hc:
            for _ in range(4):
                rec()

    rec()
    return painted, basec


def suffix_of(path):
    """Texture role suffix from the basename: t_cas_mudside_01_cv -> cv."""
    if not path or path.startswith("("):
        return "?"
    bn = os.path.basename(path)
    return bn.rsplit("_", 1)[-1].lower() if "_" in bn else "?"


def level_layers(level, gi=None, dep_out=None):
    """The full per-layer join for one level -> list of dicts:
    {idx, key, content_hash, lods, textures:{nh_hex: path}, consts:{nh_hex:
    [type, value]}, painted_pages, base_pages}. Also returns (n, resolved)."""
    if gi is None:
        gi = load_guid_index()
    td = terr_dir(level)
    dp = _res(td, "layergraphs_shaderblockdepot.ShaderBlockDepotResource") \
        or _res(td, ".ShaderBlockDepotResource")
    dep = sb.parse_depot(dp)
    if dep_out is not None:
        dep_out.append(dep)
    n, keys, hashes, lods, hit = layer_table(td, dep)
    painted, basec = splat_side_counts(td)
    rows = []
    for i in range(n):
        k = keys[i]
        ri = dep.key_to_record.get(k)
        row = dict(idx=i, key="%016X" % k, content_hash=None, lods=list(lods[i]),
                   textures={}, consts={},
                   painted_pages=painted.get(i, 0), base_pages=basec.get(i, 0))
        if ri is not None:
            r = dep.records[ri]
            row["content_hash"] = "%016X" % r.content_hash
            row["record_index"] = r.index
            row["record_size"] = r.size
            res = sb.resolve_record(r, gi)
            if res is not None:
                row["textures"] = {lbl[3:]: v for lbl, v in res["textures"].items()}
                row["consts"] = {lbl[3:]: [ty, val]
                                 for lbl, (ty, val) in res["params"].items()}
        rows.append(row)
    return dict(level=level, terr_dir=td, depot=os.path.basename(dp),
                layer_count=n, keys_resolved=hit, rows=rows)


def albedo_of(row):
    """(slot_hex, path) of the texture this layer should composite as albedo:
    the near-set _cv when present, else the distance-set _cv, else any _cv.
    Returns (None, None) for colourless layers.  MEASURED preference order --
    see probe_painted_slots.py output."""
    cvs = {nh: p for nh, p in row["textures"].items()
           if suffix_of(p) == "cv" and not str(p).startswith("(")}
    if not cvs:
        return None, None
    for pref in ("0929399a", "2e5acda8", "2e5b5189"):
        if pref in cvs:
            return pref, cvs[pref]
    nh = sorted(cvs)[0]
    return nh, cvs[nh]


def cache_path(level):
    return os.path.join(CACHE, level + ".json")


def save_level(doc):
    os.makedirs(CACHE, exist_ok=True)
    with open(cache_path(doc["level"]), "w", encoding="utf-8") as fh:
        json.dump(doc, fh)


def load_level(level):
    p = cache_path(level)
    if not os.path.isfile(p):
        return None
    with open(p, encoding="utf-8") as fh:
        return json.load(fh)


def merge_level(level, extra):
    doc = load_level(level)
    if doc is None:
        raise SystemExit("no cached table for %s -- run probe_painted_table.py "
                         "first" % level)
    doc.update(extra)
    save_level(doc)
    return doc


def roster(argv, default="all"):
    """[levels...] from argv: a level name, 'all' (17), or 'all+granite'."""
    arg = default
    for a in argv[1:]:
        if not a.startswith("-"):
            arg = a
            break
    if arg == "all":
        return list(LEVELS)
    if arg == "all+granite":
        return list(LEVELS) + list(GRANITE_SLICES)
    return [arg]
