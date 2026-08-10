"""Shared plumbing for the MP_Tungsten probes (probe_tung_*.py).

READ-ONLY. Nothing here writes to the game install, the dump, or any user cache.

Where the bytes come from
-------------------------
The plugin itself reads the player's live install through its GDScript reader.
These probes read the SAME data out of the already-extracted 2026-08-01 pull,
whose root is owned by `impl/pipeline/bf6_paths.py` in the BF6_Frostbite_Research
checkout -- that module is the one source of truth for the dump root and is
imported here rather than re-stated. Reading the extracted tree keeps the probes
targeted (one named EBX at a time) instead of mounting the whole SuperBundle.

The extracted tree mirrors the game's own asset paths, so a level's partitions
sit at:

    <DUMP>/bundles/game/glaciermp/levels/mp_tungsten/...

and a partition GUID can be turned into an asset *leaf name* through the dump's
`_af/<first-three-guid-groups>/` directory, which is a flat guid-keyed store.

Type and field names come from the research databank's tables
(`data/sdk_type_guids.tsv`, `data/sdk_field_names.tsv`,
`data/engine_only_field_names.tsv`) -- never guessed.
"""
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

import bf6_paths as P          # noqa: E402  -- THE source of truth for paths
import ebx as ebxmod           # noqa: E402
import ebx_deser               # noqa: E402
import typesdk                 # noqa: E402

DATA = os.path.join(RESEARCH, "data")
BUNDLES = P.BUNDLES
AF = os.path.join(BUNDLES, "_af")

LEVELS = os.path.join(BUNDLES, "game", "glaciermp", "levels")
TUNG = os.path.join(LEVELS, "mp_tungsten")

# The retail MP executable. typesdk.EXE defaults to the SP build; type LAYOUTS
# (field offsets) are what we use it for and both builds agree on every field
# checked here, but MP level data is read against the MP exe on principle.
EXE_MP = r"C:\Program Files (x86)\Steam\steamapps\common\Battlefield 6\bf6.exe"
EXE_SP = typesdk.EXE

_pe = None


def pe(mp=True):
    global _pe
    if _pe is None:
        path = EXE_MP if (mp and os.path.isfile(EXE_MP)) else EXE_SP
        _pe = typesdk.PE(path)
        _pe._path = path
    return _pe


# --- name tables -------------------------------------------------------------
_type_names = None
_field_names = None


def type_names():
    global _type_names
    if _type_names is None:
        m = {}
        with open(os.path.join(DATA, "sdk_type_guids.tsv"), encoding="utf-8",
                  errors="replace") as fh:
            next(fh)
            for ln in fh:
                q = ln.rstrip("\n").split("\t")
                if len(q) >= 2:
                    m.setdefault(q[0].strip().lower(), q[1].strip())
        _type_names = m
    return _type_names


def field_names():
    global _field_names
    if _field_names is None:
        m = {}
        for fn in ("sdk_field_names.tsv", "engine_only_field_names.tsv"):
            p = os.path.join(DATA, fn)
            if not os.path.isfile(p):
                continue
            with open(p, encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    if ln.startswith("#") or ln.startswith("field_hash"):
                        continue
                    q = ln.rstrip("\n").split("\t")
                    if len(q) >= 2 and q[0].strip():
                        try:
                            h = int(q[0].strip(), 16)
                        except ValueError:
                            continue
                        m.setdefault(h, q[1].strip())
        _field_names = m
    return _field_names


def fname(h):
    return field_names().get(h, "0x%08X" % h)


def tname(guid_str):
    return type_names().get(str(guid_str).lower(), guid_str)


# --- the guid-keyed flat store ----------------------------------------------
def af_leaf(guid_str):
    """partition GUID -> the leaf asset name(s) the dump stored it under."""
    d = os.path.join(AF, str(guid_str)[:23])
    if not os.path.isdir(d):
        return []
    try:
        return sorted(os.listdir(d))
    except OSError:
        return []


# --- EBX ---------------------------------------------------------------------
def open_ebx(path):
    """Deserialize an EBX partition. Returns (Deser, EFIX)."""
    D = ebx_deser.Deser(pe(), path)
    return D, D.f


def instances(D):
    """[(index, type_guid_str, type_name)] for every exported+internal instance."""
    out = []
    for i in range(len(D.f.instance_offsets)):
        g = D.inst_type[i]
        gs = ebxmod._guid_str(g) if g else None
        out.append((i, gs, tname(gs) if gs else "?"))
    return out


def named(rec):
    """Re-key a decoded struct dict from field hashes to names."""
    if not isinstance(rec, dict):
        return rec
    out = {}
    for k, v in rec.items():
        if k == "__type":
            out["__type"] = tname(v)
            continue
        kk = fname(k) if isinstance(k, int) else k
        if isinstance(v, dict):
            v = named(v)
        elif isinstance(v, list):
            v = [named(x) for x in v]
        out[kk] = v
    return out


def imports_of(f):
    """[(partition_guid, instance_guid, leaf-names-from-_af)]"""
    out = []
    for pg, ig, pgs, igs in f.imports:
        out.append((pgs, igs, af_leaf(pgs)))
    return out


# --- raw RIFF helpers (for RES payloads, which are not EBX) -------------------
def read(path):
    with open(path, "rb") as fh:
        return fh.read()


def u8(d, o):
    return d[o]


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


def u64(d, o):
    return struct.unpack_from("<Q", d, o)[0]


def f32(d, o):
    return struct.unpack_from("<f", d, o)[0]


def hexdump(d, off, n=64):
    lines = []
    for i in range(0, n, 16):
        chunk = d[off + i:off + i + 16]
        if not chunk:
            break
        lines.append("%08x  %-47s  %s" % (
            off + i, " ".join("%02x" % b for b in chunk),
            "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)))
    return "\n".join(lines)


if __name__ == "__main__":
    print("dump      ", P.DUMP)
    print("tungsten  ", TUNG, "exists" if os.path.isdir(TUNG) else "MISSING")
    print("exe       ", pe()._path)
    print("type names", len(type_names()))
    print("field names", len(field_names()))
