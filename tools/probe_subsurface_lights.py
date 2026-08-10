"""MP_Subsurface: light / volume / occluder census, expanded to world space.

The map is mostly indoors, which makes it the stress test for the plugin's
prop-light system (task: lights vanish when the camera nears several). This
probe answers, with numbers:

  * how many Pbr*LightEntityData instances the level authors, of which types;
  * where they live (lighting prefabs `pf_*_lightingprops*` vs layer partitions);
  * the EXPANDED world-space census: prefab placements resolved recursively,
    so 'one corridor prefab x N placements' counts N times, like the game;
  * density: the worst-case number of lights within the plugin's 150 m cull
    radius, and within small radii (the Forward+ cluster question);
  * the same expansion for LightProbeVolumeData, OccluderPlaneEntityData,
    ParticipatingMediaVolumeEntityData, PbrBoxReflectionVolumeEntityData,
    ExclusionVolumeData, EnvironmentDecalVolumeData.

Method: pass A opens every partition under the level, decoding only instances
whose type is a light/volume/occluder type or a reference type (discovered
dynamically: any decoded instance carrying Blueprint + BlueprintTransform).
Pass B expands: roots = partitions never referenced from inside the level;
each reference composes its LinearTransform onto the target partition's
contents.

READ-ONLY against the dump. Usage: probe_subsurface_lights.py [level]
"""
import collections
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import probe_tung_common as C          # noqa: E402

LIGHT_TYPES = {
    "PbrSpotLightEntityData", "PbrSphereLightEntityData",
    "PbrRectangularLightEntityData", "PbrTubeLightEntityData",
    "PbrDiscLightEntityData", "LocalLightEntityData",
}
VOLUME_TYPES = {
    "LightProbeVolumeData", "OccluderPlaneEntityData",
    "ParticipatingMediaVolumeEntityData", "PbrBoxReflectionVolumeEntityData",
    "ExclusionVolumeData", "EnvironmentDecalVolumeData",
}
# reference types: instances with Blueprint + BlueprintTransform. The named one
# plus whatever unnamed type-guids behave the same (discovered on the fly).
REF_NAME_HINT = "ReferenceObjectData"


def _vec(d, key_hex, name=None):
    v = d.get(name) if name and name in d else d.get(key_hex)
    if isinstance(v, dict):
        return (v.get("X", 0.0), v.get("Y", 0.0), v.get("Z", 0.0))
    return None


def lt_parse(t):
    """LinearTransform dict -> (3x3 rows right,up,fwd, trans)."""
    if not isinstance(t, dict):
        return None
    r = _vec(t, "0xC478CC3B")
    u = _vec(t, "0xBF151EF9")
    f = _vec(t, "Forward", "Forward")
    p = _vec(t, "0xBC4B07B4")
    if r is None or u is None or f is None or p is None:
        return None
    return (r, u, f, p)


def lt_mul(a, b):
    """compose: world = a o b  (b local into frame a)."""
    (ar, au, af, ap) = a
    (br, bu, bf, bp) = b
    def row(v):
        return tuple(v[0] * ar[i] + v[1] * au[i] + v[2] * af[i] for i in range(3))
    return (row(br), row(bu), row(bf),
            tuple(row(bp)[i] + ap[i] for i in range(3)))


IDENT = ((1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 0, 0))


def main():
    level = sys.argv[1] if len(sys.argv) > 1 else "mp_subsurface"
    root = os.path.join(C.LEVELS, level)

    parts = {}          # partition_guid -> dict(rel, lights, vols, refs)
    ref_type_guids = set()
    skipped = []

    files = []
    for dirpath, _d, fns in os.walk(root):
        for fn in fns:
            if fn.endswith(".ebx"):
                files.append(os.path.join(dirpath, fn))
    print("%s: %d ebx partitions" % (level, len(files)))

    for p in files:
        rel = os.path.relpath(p, root).replace(os.sep, "/")
        if os.path.getsize(p) > 4 * 1024 * 1024:
            skipped.append((rel, "size"))
            continue
        try:
            D, f = C.open_ebx(p)
        except Exception as e:
            skipped.append((rel, str(e)))
            continue
        pg = getattr(f, "partition_guid_str", None)
        ent = dict(rel=rel, lights=[], vols=[], refs=[])
        for i, gs, tn in C.instances(D):
            is_light = tn in LIGHT_TYPES
            is_vol = tn in VOLUME_TYPES
            is_ref = (REF_NAME_HINT in tn) or (gs in ref_type_guids)
            maybe_ref = tn == gs          # unnamed type: probe it once
            if not (is_light or is_vol or is_ref or maybe_ref):
                continue
            try:
                rec = C.named(D.read_instance(i))
            except Exception:
                continue
            if is_light:
                lt = lt_parse(rec.get("Transform"))
                cone = None
                for k, v in rec.items():
                    if isinstance(k, str) and ("Angle" in k) and isinstance(v, (int, float)):
                        cone = (k, v) if cone is None else cone
                col = _vec(rec, "Color", "Color") or (1, 1, 1)
                ent["lights"].append(dict(
                    type=tn, xf=lt or IDENT,
                    intensity=rec.get("Intensity"),
                    radius=rec.get("AttenuationRadius"),
                    unit=rec.get("LightUnit"), color=col, cone=cone))
            elif is_vol:
                lt = lt_parse(rec.get("Transform"))
                ent["vols"].append(dict(type=tn, xf=lt or IDENT))
            else:
                bp = rec.get("Blueprint")
                bt = lt_parse(rec.get("BlueprintTransform"))
                if isinstance(bp, dict) and "import" in bp and bt is not None:
                    if maybe_ref and not is_ref:
                        ref_type_guids.add(gs)
                    ent["refs"].append((bp["import"], bt))
        if pg is None:
            pg = rel     # fall back to path key
        parts[pg] = ent

    if skipped:
        print("   skipped %d partitions (decode errors), e.g. %s" % (len(skipped), skipped[:2]))

    n_l = sum(len(e["lights"]) for e in parts.values())
    n_r = sum(len(e["refs"]) for e in parts.values())
    print("pass A: %d authored light instances, %d references, %d ref-type guids"
          % (n_l, n_r, len(ref_type_guids)))

    per_type = collections.Counter()
    for e in parts.values():
        for L in e["lights"]:
            per_type[L["type"]] += 1
    print("   authored (pre-expansion) light instances by type: %s" % dict(per_type))

    # ---- pass B: expansion ------------------------------------------------
    referenced = set()
    for e in parts.values():
        for tgt, _bt in e["refs"]:
            referenced.add(tgt)
    roots = [pg for pg in parts if pg not in referenced]
    print("pass B: %d root partitions (never referenced inside the level)" % len(roots))

    world = dict(lights=[], vols=[])
    hit = collections.Counter()

    def expand(pg, xf, depth):
        e = parts.get(pg)
        if e is None:
            return
        hit[pg] += 1
        if depth > 12:
            return
        for L in e["lights"]:
            w = lt_mul(xf, L["xf"])
            world["lights"].append(dict(L, pos=w[3], src=e["rel"]))
        for V in e["vols"]:
            w = lt_mul(xf, V["xf"])
            world["vols"].append(dict(V, pos=w[3], src=e["rel"]))
        for tgt, bt in e["refs"]:
            expand(tgt, lt_mul(xf, bt), depth + 1)

    cur_root = [None]
    root_lights = collections.Counter()
    for pg in roots:
        cur_root[0] = parts[pg]["rel"]
        before = len(world["lights"])
        expand(pg, IDENT, 0)
        if len(world["lights"]) > before:
            root_lights[cur_root[0]] += len(world["lights"]) - before

    wl = world["lights"]
    print("\n   roots contributing lights (top 20 of %d):" % len(root_lights))
    for rel, n in root_lights.most_common(20):
        print("      %5d  %s" % (n, rel))

    # dedup: same type + same world position (0.1 m) = the same authored fixture
    # reached through more than one root (gamemode layers, hi/low lighting, the
    # _nongroupable_autogen twins)
    seen = set()
    uniq = []
    for L in wl:
        k = (L["type"], round(L["pos"][0], 1), round(L["pos"][1], 1),
             round(L["pos"][2], 1))
        if k in seen:
            continue
        seen.add(k)
        uniq.append(L)
    print("\n   DEDUP by (type, position): %d unique world lights (%d raw)"
          % (len(uniq), len(wl)))
    wl = uniq
    world["lights"] = uniq
    seenv = set()
    uv = []
    for V in world["vols"]:
        k = (V["type"], round(V["pos"][0], 1), round(V["pos"][1], 1),
             round(V["pos"][2], 1))
        if k not in seenv:
            seenv.add(k)
            uv.append(V)
    print("   DEDUP volumes: %d unique (%d raw)" % (len(uv), len(world["vols"])))
    world["vols"] = uv
    print("\n== EXPANDED world census ==")
    wt = collections.Counter(L["type"] for L in wl)
    print("   lights: %d total   %s" % (len(wl), dict(wt)))
    vt = collections.Counter(V["type"] for V in world["vols"])
    print("   volumes/occluders: %s" % dict(vt))

    if wl:
        ys = sorted(L["pos"][1] for L in wl)
        print("   light Y range %.1f .. %.1f   median %.1f"
              % (ys[0], ys[-1], ys[len(ys) // 2]))
        rad = sorted((L["radius"] or 0) for L in wl)
        inten = collections.Counter()
        for L in wl:
            inten[L["unit"]] += 1
        print("   AttenuationRadius min/med/max  %.1f / %.1f / %.1f   LightUnit counts %s"
              % (rad[0], rad[len(rad) // 2], rad[-1], dict(inten)))

        # density: grid-bucket then worst neighbourhoods
        for R in (10.0, 25.0, 150.0):
            grid = collections.defaultdict(list)
            cs = R
            for L in wl:
                x, _y, z = L["pos"]
                grid[(int(x // cs), int(z // cs))].append(L["pos"])
            best, where = 0, None
            for L in wl:
                x, y, z = L["pos"]
                n = 0
                gx, gz = int(x // cs), int(z // cs)
                for dx in (-1, 0, 1):
                    for dz in (-1, 0, 1):
                        for (px, py, pz) in grid[(gx + dx, gz + dz)]:
                            if (px - x) ** 2 + (py - y) ** 2 + (pz - z) ** 2 <= R * R:
                                n += 1
                if n > best:
                    best, where = n, (x, y, z)
            print("   worst-case lights within %5.0f m of a light: %4d  at (%.0f, %.0f, %.0f)"
                  % (R, best, where[0], where[1], where[2]))

    # most-instanced lighting prefabs
    print("\n   most-expanded partitions carrying lights:")
    rows = []
    for pg, n in hit.items():
        e = parts.get(pg)
        if e and e["lights"]:
            rows.append((n * len(e["lights"]), n, len(e["lights"]), e["rel"]))
    for tot, n, nl, rel in sorted(rows, reverse=True)[:15]:
        print("      %5d world lights = %3d placements x %3d lights   %s" % (tot, n, nl, rel))

    # occluder detail
    occ = [V for V in world["vols"] if V["type"] == "OccluderPlaneEntityData"]
    print("\n   OccluderPlaneEntityData world count: %d" % len(occ))


if __name__ == "__main__":
    main()
