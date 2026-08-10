"""What _apply_game_look actually binds, measured per map - and whether any of
it CAN make water invisible.

Context: highpoly_water.gd::_apply_game_look maps the water depot record onto
water.gdshader uniforms. Commit 2e32a5a blamed it for making tungsten's block-2
river invisible and swapped in the river preset. This probe decodes the depot
records for every water-shipping study map and pushes the mined numbers through
the same arithmetic the GDScript does, to name the uniform that could kill the
surface - or to show none can.

The shader's reachable output range (water.gdshader, read-only):
    ALPHA  = clamp(mix(min_alpha 0.45, max_alpha 0.94, df) + fresnel*0.25
             + foam*0.4)          ->  in [0.45, 1.0] whatever the look binds
    ALBEDO = mix(game_shallow, game_deep, df) (+foam, +fresnel)
_apply_game_look touches ONLY use_game_color/game_shallow/game_deep,
ripple_scale/speed/strength (ocean variant), and the foam/detail textures.
It cannot reach min_alpha/max_alpha.

READ-ONLY.  Usage:  probe_water2_gamelook.py
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, r"C:\PortalSDK\BF6_Frostbite_Research\impl\pipeline")
import shaderblock as sb             # noqa: E402
import bf6_paths as P                # noqa: E402

GL = os.path.join(P.BUNDLES, "game", "glaciermp", "levels")

# Water-surface StateKeys. tungsten/eastwood/isolated/aftermath were found by
# scanning _layers_content/water.ebx's aligned u64s against every depot under
# the level (one hit each); dumbo's is the MAP-DUMBO.md documented key.
KEYS = {
    "mp_tungsten": 0x109c22da5f67cf7a,
    "mp_eastwood": 0x532df991f61dc281,
    "mp_isolated": 0x42914acb1555cfd8,
    "mp_aftermath": 0xeb5c36f3d86ed23d,
    "mp_dumbo": 0x42f38eeaac4aa54e,
}

# highpoly_gamesource.gd's slot ids
WSLOT_FOAM_RGB = 0x3faa6a0b
WSLOT_WATER_A = 0x50b54e74
WSLOT_WATER_B = 0xdfcb439c
WSLOT_FOAM_NSH = 0x60181bbf
WSLOT_DETAIL_NSH = 0x635b5631
WSLOT_OCEAN_COLOR = 0xeaca953a

RIVER_PRESET = ((0.16, 0.34, 0.30), (0.030, 0.095, 0.105))   # known-visible


def srgb(v):
    return tuple(round(1.055 * c ** (1 / 2.4) - 0.055 if c > 0.0031308
                       else 12.92 * c, 3) for c in v)


def find_record(level, key):
    lvl = os.path.join(GL, level)
    for root, dirs, files in os.walk(lvl):
        for f in files:
            if not f.endswith(".ShaderBlockDepotResource"):
                continue
            try:
                dep = sb.parse_depot(os.path.join(root, f))
            except Exception:
                continue
            if key in dep.key_to_record:
                return os.path.join(root, f), dep.records[dep.key_to_record[key]]
    return None, None


def main():
    for level, key in KEYS.items():
        dp, rec = find_record(level, key)
        print("=" * 72)
        print("%s  key %016x  %s" % (level, key,
                                     "record FOUND" if rec else "NOT FOUND"))
        if rec is None or rec.params is None:
            continue
        color = {}
        tex = []
        n_scalar = 0
        for p in rec.params:
            if p.is_texture:
                tex.append(p.name_hash)
            elif p.type_hash == 0x25f81af1:
                color[p.name_hash] = p.value()
            else:
                n_scalar += 1
        variant = "ocean" if (WSLOT_DETAIL_NSH in tex or WSLOT_FOAM_NSH in tex) \
            else "foam"
        print("  variant %s   %d textures %s   %d float3 colours   %d other "
              "constants" % (variant, len(tex),
                             ["%08x" % t for t in tex], len(color), n_scalar))
        # what _apply_game_look computes
        if variant == "ocean":
            sh = color.get(WSLOT_OCEAN_COLOR)
            dpc = tuple(c * 0.28 for c in sh) if sh else None
        else:
            sh = color.get(WSLOT_WATER_A)
            dpc = color.get(WSLOT_WATER_B)
        if sh is None:
            print("  -> no colour bound; use_game_color stays false")
            continue
        print("  game_shallow (linear) %s  ~sRGB %s"
              % (tuple(round(c, 4) for c in sh), srgb(sh)))
        print("  game_deep    (linear) %s  ~sRGB %s%s"
              % (tuple(round(c, 4) for c in dpc), srgb(dpc),
                 "   (= shallow x 0.28, ocean variant ships one colour)"
                 if variant == "ocean" else ""))
        rp_s, rp_d = RIVER_PRESET
        print("  vs the KNOWN-VISIBLE river preset: shallow %s deep %s"
              % (rp_s, rp_d))
        lum = 0.2126 * sh[0] + 0.7152 * sh[1] + 0.0722 * sh[2]
        lum_p = 0.2126 * rp_s[0] + 0.7152 * rp_s[1] + 0.0722 * rp_s[2]
        print("  shallow luminance %.3f (preset %.3f) -> %s"
              % (lum, lum_p,
                 "BRIGHTER than the preset that renders" if lum > lum_p
                 else "darker than the preset, but alpha floor still 0.45"))
    print("=" * 72)
    print("""
VERDICT (see RESEARCH-WATER2.md 3 for the full argument):
  * ALPHA: _apply_game_look never touches min_alpha/max_alpha; the shader's
    alpha is >= 0.45 for every reachable uniform state.  Alpha CANNOT go
    near zero from the mapping.
  * COLOUR: measured above - tungsten binds (0.309, 0.495, 0.498), BRIGHTER
    than the river preset that renders; dumbo's (0.068 grey) and aftermath's
    (0, 0.076, 0.082) are DARKER and those maps rendered on screen.  "colours
    ~0" is false for the map that failed and true for the maps that worked.
  * TEXTURES: the only remaining look-dependent binds (foam_mode=2 +
    detail_nsh, gs != null).  Worst case measured range of the foam term is a
    BRIGHT sheet (foam -> foam_col ~0.6..1.2), never invisibility.
  * The "invisible" observation predates c4f7048 (stale Water node shown
    through every toggle) and 330e80f (water mined empty early in the session
    and never re-asked).  Both are exactly "renders nothing" mechanisms that
    were live during the game-look attempt and fixed before the plain-material
    test - the experiment that convicted _apply_game_look changed three
    variables, not one.
""")


if __name__ == "__main__":
    main()
