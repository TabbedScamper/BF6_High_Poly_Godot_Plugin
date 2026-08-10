"""Targeted partition-GUID -> file index.

A full-dump index is ~250k files on a slow volume; every probe here only needs
to resolve a handful of GUIDs, so this walks ONE subtree and reads only the
first 16 bytes of each partition's EFIX chunk (EBX_RIFF 2.4) -- three seeks per
file, no payload. Results are cached to the scratch dir under a key derived from
the subtree, so a second probe over the same subtree is free.

Usage:
    probe_tung_guidscan.py <subtree-relative-to-bundles> [guid ...]
    probe_tung_guidscan.py game/glaciermp/levels/mp_tungsten 8352268b-f28c-11ee-a41e-b5c87f7c0da9
"""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C   # noqa: E402

CACHE = os.path.join(os.environ.get("TEMP", "."), "bf6_tung_guidscan")


def guid_str(b):
    a, c, d = struct.unpack_from("<IHH", b, 0)
    return "%08x-%04x-%04x-%s-%s" % (a, c, d, b[8:10].hex(), b[10:16].hex())


def partition_guid(path):
    """First 16 bytes of the EFIX chunk. RIFF pads to an EVEN boundary."""
    try:
        sz = os.path.getsize(path)
        if sz < 32:
            return None
        with open(path, "rb") as f:
            if f.read(4) != b"RIFF":
                return None
            pos = 12
            while pos + 8 <= sz:
                f.seek(pos)
                hdr = f.read(8)
                if len(hdr) < 8:
                    return None
                cid, csz = hdr[:4], struct.unpack_from("<I", hdr, 4)[0]
                data = pos + 8
                if cid == b"EFIX":
                    g = f.read(16)
                    return guid_str(g) if len(g) == 16 else None
                if csz <= 0 or data + csz > sz:
                    return None
                pos = (data + csz + 1) & ~1
    except OSError:
        return None
    return None


def index(subtree, use_cache=True):
    root = os.path.join(C.BUNDLES, subtree.replace("/", os.sep))
    key = subtree.replace("/", "_").replace("\\", "_")
    cpath = os.path.join(CACHE, key + ".json")
    if use_cache and os.path.isfile(cpath):
        with open(cpath, encoding="utf-8") as fh:
            return json.load(fh)
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".ebx"):
                continue
            p = os.path.join(dirpath, fn)
            g = partition_guid(p)
            if g:
                out[g] = os.path.relpath(p, C.BUNDLES).replace(os.sep, "/")
    os.makedirs(CACHE, exist_ok=True)
    with open(cpath, "w", encoding="utf-8") as fh:
        json.dump(out, fh)
    return out


def main():
    subtree = sys.argv[1] if len(sys.argv) > 1 else "game/glaciermp/levels/mp_tungsten"
    idx = index(subtree)
    print("%d partitions under %s" % (len(idx), subtree))
    for g in sys.argv[2:]:
        print("  %s -> %s" % (g, idx.get(g.lower(), "<not in this subtree>")))


if __name__ == "__main__":
    main()
