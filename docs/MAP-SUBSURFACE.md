# MP_Subsurface, end to end

The underground map — the fleet's stress test for prop lights, interiors, and
for what "terrain" and "colour map" even mean when nearly all play space is
inside a mountain. Same method and deliverable shape as `MAP-TUNGSTEN.md`;
every claim is tagged **MEASURED** (with the number and the probe that
reproduces it) or **HYPOTHESIS**; "unknown" is used where the data ran out.

Probes: the parameterised `probe_tung_*.py` suite run with `mp_subsurface`,
plus two new ones beside this document:

```
tools/probe_subsurface_decomp.py       exact chunk decomposition (the detect_layout row)
tools/probe_subsurface_lights.py       light/volume/occluder census, expanded to world space
tools/probe_subsurface_colorrender.py  BC7-mode-6 colour-map renderer for this map's layout
```

All read the 2026-08-01 pull through `impl/pipeline/bf6_paths.py`, read-only.
Rendered colour map:
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Subsurface.png`.

---

## 0. The map in one paragraph

**MEASURED.** MP_Subsurface is a **2,048 x 2,048 m** world (block-0 root AABB
x,z ∈ [-1024, 1024]) whose terrain spans only **y = 55.47 to 68.72 — 13.3 m of
relief** (`WorldSizeY` 1024.0, 61 streaming nodes, 56 persistent). The playable
space is a hand-built underground complex whose lights range **y = -3.9 to
91.5** — rooms sit as much as ~59 m *below* the terrain floor. The terrain
palette is 28 layers (15 painted / 13 base); **98.5% of the block-7 base field
resolves to L16, a default-texture layer** — the outdoor surface is one grey
plain with a small road compound at the centre. There is **no water entity of
any kind** (0 of 1,897 partitions match `water|ocean|river` by type), no
backdrop mesh (`_layers_world/backdrop.ebx` has `Objects = []`), and the colour
map is a **uniform 0.502 grey** — authored neutral. What the map has instead:
**4,883 unique world-space light entities**, 454 occluder planes, 434 light
probe volumes, 315 box reflection volumes, 318 exclusion volumes, 392
participating-media volumes, 1,204 environment decal volumes, 23 per-room VE
presets and 190 FX partitions (142 in the `fx_sub_*` family). It hosts the
`subsurfacegauntlet*` mode content (gauntlet / gauntlet32_extraction / duel /
vendetta / contract) the way Tungsten hosts Granite BR.

---

## A. Water

**MEASURED — there is no water in the shipped level, not even a buried one.**
`probe_tung_types.py mp_subsurface --find "water|ocean|river"` scans all 1,897
partitions and matches **zero**. No `WaterSurfaceEntityData`, no
`WaterOceanSimulationEntityData`, no `OceanComponentData` in any `ve_*` preset,
no `WaterAsset`. This is a step beyond Tungsten/Eastwood (water authored below
the floor): Subsurface simply has none.

**MEASURED.** `_layers_content/water.ebx` exists but is an empty `LayerData`
(`Objects = []`, 418 bytes). The Tungsten-style companion partitions
(`water_shared_schematic`, `river*`, `creeks*`) do not exist at all.

**MEASURED — wet surfaces are FX, not water.** The level root and `fx/` carry a
`fx_sub_*` family of 142 partitions including `fx_sub_water_stream_waterfall_l/m`,
`fx_sub_rooftop_water_stream_l/m`, `fx_sub_sewer_waterdropplets`,
`fx_sub_water_droplet_onscreen_*` (screen-space drips). The sewer area is a
room prefab (`pf_sewer_01` + `lighting/ve_mp_subsurface_sewer_01`), not a water
volume.

Consequence for the plugin: `highpoly_gamesource.gd::water()` on this map finds
no partition containing the type. Whatever `_water_partition()` returns in that
case must be handled as a clean "this level has no water" — the water toggle
can never show anything here, and the diagnostic proposed in MAP-TUNGSTEN.md §G5
should print "no water entity in level" rather than nothing.

**MEASURED — the ECS law holds.** All **27** `*_ecsprefab_ecsprefab.ebx`
partitions in the level are the identical empty stub
(`ent=1 arch=1 seg=1 edits=0 comps=[26]`). None populated
(`probe_tung_ecs.py mp_subsurface`).

---

## B. Terrain and ground layers

### B1. Streaming tree

**MEASURED** (`probe_tung_terrain.py mp_subsurface`):

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 61, PersistentNodeCount 56
block 0  heights    8,966 B   xs=265, WorldSizeY=1024.0, 61 nodes (5 Packed, 56 External)
block 1  splat    286,556 B   LayerSlotCount=62, 157 nodes, 8,639 records
block 4  mask       1,037 B
block 7  material 135,682 B   dim=256, nodeCount=101 declared, levelMax=4, 5 pairs
block 8  mask      55,185 B   dim=265, 37 nodes, levelMax=3, maskUnknown0=4
```

No blocks 2 or 5 (Tungsten has both). `LayerSlotCount` is 62 (the common value;
Tungsten's 6 remains the outlier). Height quantisation: one u16 step = 1.56 cm
(`WorldSizeY` 1024), Tungsten-class, but over 13 m of actual relief.

The terrain directory is named **`mp_subsurface_terrain`** (dumbo style, not
Tungsten's `terrain_mp_tungsten`) — verifies the naming-inconsistency law.

### B2. Layer table — 28 layers, 12 with any texture

**MEASURED.** `VisualTerrain` (625 B): `layerCount = 28`,
`SurfaceShaderBlockKey 0xC2CA5D4C76FD2C9F`, three shaders including
**`holesterrainsurfaceshader`** (the terrain has authored holes — presumably the
shafts/openings into the complex; the default and holes shaders ship side by
side). Layer flags {0: 27, 1: 1}; **no linked layers** (Tungsten's L29-32→L28
link structure is absent, even though the crater layer exists).

`layergraphslayergraphs` (1,056 B): record table at **offset 72**, 28 records,
**28/28 keys resolve** in the paired depot (8,964-B class; 25 content-distinct
records, 54 texture params, 221 inline constants) — the "all keys must resolve"
rule verified (`probe_tung_layers.py mp_subsurface`).

Painted (weight page) 15: L02-L10, L12-L14, L20, L21, L27.
Base (no page) 13: L00, L01, L11, L15-L19, L22 (620 node-records each),
L23-L26 (596 each).

| L | side | textures | note |
|---|---|---|---|
| 00 | BASE | none | tint (0.302, 0.309, 0.347) |
| 01 | BASE | `t_euu_cobblestone_01_{cv,ao,nhs}` + default ao | cobblestone |
| 02 | painted | breakupmask + `t_com_asphaltdetail_02_ncs` (detail only) | tint (0.257, 0.264, 0.250) |
| 03 | painted | breakupmask + asphaltdetail (detail only) | tint (0.445, 0.472, 0.417) |
| 04 | painted | none | |
| 05 | painted | breakupmask + asphaltdetail (detail only) | tint (0.628, 0.601, 0.569) |
| 06-08 | painted | none | tints 0.599/0.344/0.200-class |
| 09, 10 | painted | none | L10 tint (0.170 grey) |
| 11 | BASE | default cv/ao/nhs + `t_wuu_sandnoise_02` | |
| 12 | painted | none | **empty depot record** |
| 13, 14 | painted | none | |
| 15 | BASE | default cv/ao/nhs/ao | |
| 16 | BASE | default cv/ao/nhs + sandnoise | **the 98.5% background field layer** |
| 17 | BASE | default ao + breakupmask | tint (0.050 — near black) |
| 18, 19 | BASE | `t_cas_asphaltedge_01_{op,cv,ao,nhs}` | the road edges |
| 20, 21 | painted | none | **empty depot records** |
| 22 | BASE | `hfd_debug` at slot **0xAE16A5C0** | **the crater layer** |
| 23 | BASE | `t_wum_asphaltedge_01` + `t_wum_crackedconcrete_03` | crater-material family |
| 24 | BASE | `t_wum_ls_gravel_01_a` + sand ncs | " |
| 25 | BASE | `t_wum_dryrockygravel` + sand ncs | " |
| 26 | BASE | `t_wum_concretedebris_01` + `_02` (6 tex) | " |
| 27 | painted | none | empty depot record |

**MEASURED — the materials-on-the-base-side law holds in Tungsten's absolute
form for real albedos:** every texture that is an actual colour map (cobblestone,
asphaltedge, gravel, concretedebris) is on a BASE layer; the only painted-layer
textures are `t_gen_breakupmask_02_rgba` and `t_com_asphaltdetail_02_ncs`,
i.e. masks/detail noise, not albedo.

**MEASURED — the identified constants recur:** `0xAE16A5C0` = crater texture
slot, exactly one layer (L22) binds it. `0x4FDCF6B1` (vec3 linear albedo tint,
already `C_TINT` in `bf6_terrainlayers.gd`) is present on most textureless
layers here with plausible per-layer albedos — on this map the tint constant is
carrying most of the ground colour that exists at all. `0xCF3F97E0` is again an
integer (values 2/3/4 observed). `0xCBB9A946` is (0,0) everywhere.
`0x2F9990B7` observed 10..105.4; `0xF7652FB3` observed 1..45 — consistent with
Tungsten's ranges, still unidentified.

### B3. Block 7 — one layer is 98.5% of the ground

**MEASURED** (`probe_tung_basefield.py mp_subsurface`): `pairCount = 5`,
`BackgroundMaterialIndex = 0x00000080` (the dumbo/eastwood "no background"
sentinel, resolving to L0 if decoded anyway). Only 4 live pairs:

```
pair 0 0x06710480 -> L16 (98.5% of texels)   default textures + sandnoise
pair 1 0x0670E280 -> L02 ( 1.1%)             the asphalt-detail painted layer
pair 2 0x0670FA80 -> L10 ( 0.2%)             textureless, grey tint
pair 3 0x06701F80 -> L01 ( 0.2%)             cobblestone
```

The rasterised field is a coherent picture: a uniform plain with a small
road/compound network clustered at the centre — matching the terrain-decal
AABBs (§D). **The honest ceiling for terrain texture on this map is ~1.3% of
texels with a real albedo** (L01 cobblestone + L18/L19 road edges via decal
slots); everything else is the default-texture layer whose look is tint +
noise. For an indoor map this is fine — the terrain is a lid, and players see
it only around the surface compound.

Parse note, MEASURED: the block-7 node walk finds 76 nodes against the header's
declared 101 and ends 28 bytes past the 64-byte-footer convention
(`slack=-28`), with 0 bad RLE rows. Tungsten/dumbo walk byte-exactly. Unknown
why; the decoded field is nonetheless spatially correct against the decals and
the layer table.

---

## C. Colour map and THE DECOMPOSITION TABLE

### C1. Layout: page 2,592 — but tile 17,424, ONE per primary chunk

**MEASURED** (`probe_subsurface_decomp.py mp_subsurface`): 107 chunks on disk
(61 primary, 46 paired). Exact-decomposition scores over candidate layouts:

```
page 2592 tile  4624 :   5 / 107     page 4356 tile  4624 :  76 / 107
page 2592 tile 17424 :  99 / 107     page 4356 tile 17424 :  76 / 107
page 5184 tile  4624 :   3 / 107     page 5184 tile 17424 :  91 / 107
```

The brief's derived table says Subsurface's page size is 2,592 — **verified** —
but the trailer tile is **17,424 B = 132x132 BC7 (Tungsten's tile size), not
dumbo's 4,624**, and there is exactly **one** tile per primary chunk (no
degenerate second tile). The canonical decompositions:

```
primary depth 0-1 (5 chunks):  0 prefix + {58,15,15,14,14} x 2592 + NO tile
                               (the 5 Packed-height nodes: pages only)
primary depth 2-4 (48 chunks): 149,297 + pages x 2592 + 1 x 17424
paired (44 chunks):            0 prefix + pages x 2592 + 4 x 17424 (tiles LAST,
                               verified: final 4 x 17424 bytes are 100% mode 6;
                               42 of 46 have zero pages)
```

**BC7 mode histogram, first vs last trailer tile: both 100.0% modes 4-7
(100% mode 6)** — with k=1 they are the same tile; there is no mode-3 degenerate
raster on this map.

### C2. Eight chunks carry an EXTRA variable-size payload — new, contradicts
the "exact decomposition" law

**MEASURED.** 8 of 107 chunks (4 parent/child pairs: 0x3022/0x30222,
0x3133/0x31333, 0x3200/0x32000, 0x3311/0x33111; sizes 222,244..287,048) do
**not** decompose as height + pages x 2592 + k x 17424 under any prefix in the
established set. The residual after removing 149,297 + 17,424 is ~1,077-1,124
bytes mod 2,592 — one extra payload of a few KB whose size varies per chunk.
**The colour tile is still the last 17,424 bytes on all 8** (each decodes 1,089
of 1,089 blocks as BC7 mode 6), so a tail-read of the colour tile is safe;
page slicing by arithmetic from the chunk start or end is NOT safe on these
nodes. HYPOTHESIS: an externalised block-4/8 mask (or block-7 material) node
payload — those blocks are unusually small in-tree here and their RLE rows are
variable-length. Not proven; the payload was not identified.

### C3. The colour map is authored NEUTRAL — uniform 0.502 grey

**MEASURED** (`probe_tung_bc7mode6.py mp_subsurface --tile second`, i.e. the
last 17,424 bytes): mean RGBA **(0.502, 0.502, 0.502, ~0.00)** at every depth,
60,989 mode-6 blocks. The full render (`probe_subsurface_colorrender.py`, exact
mode-6 decode of all 57 tiles, written to `_cmapprobe/FIXED_MP_Subsurface.png`)
is a **featureless mid-grey square — it does not read as an aerial photo at
all**, and that is correct: per the corpus the colour map *modulates* the
composite around 0.5-neutral, and this map's artists left it untouched.
Overall rendered mean 0.493.

Two consequences:

- Turning `colormap_enabled` on (MAP-TUNGSTEN.md §G3) is a **no-op on
  Subsurface by design** — harmless, but it will not add colour here. The
  per-map expectation table should record Subsurface as "neutral colour map".
- The current plugin bug (reading the last 4,624 bytes as the colour tile) is
  **accidentally invisible on this map**: those bytes are the bottom quarter of
  the real (uniform) tile, so the wrong read produces the right grey. Do not
  use Subsurface as a validation map for the colour-tile fix; use the mean
  (0.502, 0.502, 0.502) as its verification number instead.
- `detect_layout`'s wrong `(2592, 4624)` pick still corrupts the **weight
  pages** here: with tile 4,624 assumed instead of 17,424, `node_pages()`
  slices 12,800 bytes late — not a multiple of 2,592, so every page boundary is
  misaligned even though the page codec (BC4-class at 2,592) is right.

---

## D. Decals and roads

**MEASURED** (`probe_tung_decals.py mp_subsurface`): `decals.TerrainDecals` is
902,312 bytes: **recordCount 222, all parsed, 0 chain breaks**; slotCount
**27** with 8 GUID-bearing slots, 6 asset slots used (15-19 and 1; slot 16
carries 156 of 222 records). 45 texture-set groups; the big ones are potholes,
asphalt lane lines, gravel erosion, road mud, concrete broken edge, road
arrows/text (`t_wuu_road_hgwyarrows_*`), airstrip yellow markings. Mask-only
groups exist here too (`_op`-only stains x10, road arrows x7) — the
"no-basecolor is not a failure" gotcha holds.

**MEASURED — decals cover only the surface compound**: all 222 records fit in
x ∈ [-946, 281], z ∈ [-148, 798], y ∈ [61.7, 124.6] — the same central/NE
region as the block-7 road network. The rest of the world square, and the
entire underground, has **no terrain decal** (indoor floor markings are
`EnvironmentDecalVolumeData`, 1,204 of them, §E).

**MEASURED — slotCount (27) != layerCount (28).** On Tungsten both were 33 and
the doc concluded "one slot per terrain layer". Subsurface breaks the equality
by one — the slot table is *near* the layer count but not guaranteed equal.
Consumers must not index decal slots by terrain-layer index without checking.

---

## E. Lights, interiors, and how indoor space is bounded (the map-specific focus)

All numbers from `probe_subsurface_lights.py mp_subsurface`: opens all 1,897
partitions, decodes every `Pbr*LightEntityData` and the six volume/occluder
types, discovers reference types dynamically (Blueprint + BlueprintTransform),
and expands prefab placements recursively to world space. Raw expansion reaches
8,681 light placements; **deduplicated by (type, position) — the same authored
fixture reached through gamemode layers, high/low lighting layers and the
`_nongroupable_autogen` twins — the census is 4,883 unique world lights.**

### E1. Light entity density and types

**MEASURED:**

```
4,883 unique world lights:
   PbrSpotLightEntityData         3,021
   PbrSphereLightEntityData       1,795
   PbrTubeLightEntityData            63
   PbrRectangularLightEntityData      4
Y range -3.9 .. 91.5 (median 64.1)
AttenuationRadius  min 0.1 / median 6.0 / max 41.1 m
LightUnit = 0 for all 4,883 (the plugin's /20000 divisor branch)
Intensity  min 10 / median 10,000 / p90 50,000 / max 10,000,000
```

Aftermath — the previous record holder in `highpoly_lighting.gd`'s comment —
has 3,716. Subsurface has 31% more, in a quarter of the area, and concentrated:

```
worst-case lights within  10 m of a light:   157
worst-case lights within  25 m of a light:   803   (at ~(22, 5, 18))
worst-case lights within 150 m of a light: 3,582   (at ~(-58, 66, 9))
```

**This is task #80's mechanism, quantified.** `highpoly_lighting.gd` culls to
`lights_range = 150 m`; on this map that enables up to **~3,600 lights at
once — 7x Godot Forward+'s 512 max clustered elements**. Past the cap,
clustered omni/spot lights drop out non-deterministically — exactly "lights
vanish when the camera nears several". Even 25 m exceeds the cap at the
hotspot. The distance cull alone can never work here; the count must be capped
(k-nearest within budget), not just the radius.

**MEASURED — 30% of the lights should never be built at all.** The
(AffectDiffuse, AffectSpecular, AffectRadiosity) combos:

```
(T,T,T) 2,999   (F,F,T) 1,443   (T,T,F) 334   (T,F,T) 77   (F,F,F) 28   (F,T,F) 2
direct-shading lights (diffuse or specular): 3,412 of 4,883
```

1,471 lights affect neither diffuse nor specular — they exist to feed
Enlighten radiosity (the `pf_lighting_radiosity_{neutral,orange,green,yellow,
blue,...}` prefabs: 330 + 202 + 156 + 150 + 146 + ... placements of single
sphere lights) or volumetrics. `highpoly_gamesource.gd::_light_record` does not
read these flags, so the plugin currently builds them as real OmniLight3Ds:
wrong look (double-counted bounce as direct light) *and* 30% of the cluster
pressure for free.

**MEASURED — where the lights live.** Fixtures are authored inside per-fixture
prefab partitions (`lighting/lf_*` — 120 of them, e.g.
`lf_com_fluorescentlamp_rect_01_nbrk_h_mp_subsurface`: 824 placements x 2
lights = 1,648 world lights) and per-room lighting prefabs
(`prefabs/pf_<room>_lightingpropsa` / `_lightingpropsb_3` / `_lightingpropsb_4`).
The `a`/`b_N` suffixes are variant sets; `subsurfacelayoutsmetadata.ebx`
selects layouts with mode **"Random"** (MEASURED string in the partition), so
which set is live varies per round. Dedup keeps variants apart only when their
positions differ; a placement walk that loads *all* of them overlights rooms
that alternate.

### E2. How indoor space is bounded

**MEASURED**, unique world-space counts:

| type | count | where |
|---|---|---|
| `OccluderPlaneEntityData` | 454 | dedicated layers `_layers_content/occluders.ebx` (414 objects) + `occluders_sewer.ebx` — hand-placed occlusion planes, the only occluder type on the map |
| `LightProbeVolumeData` | 434 | one per room prefab + `lighting_global` |
| `PbrBoxReflectionVolumeEntityData` | 315 | per-room box reflection volumes |
| `ExclusionVolumeData` | 318 | per-room (HYPOTHESIS: excludes outdoor systems — sun/GI/weather — from interiors) |
| `ParticipatingMediaVolumeEntityData` | 392 | per-room volumetric dust/fog |
| `EnvironmentDecalVolumeData` | 1,204 | props/decal/signage layers — the indoor floor/wall markings |

Plus 23 `ve_*` visual-environment presets, one per room family
(`ve_mp_subsurface_sewer_01`, `_corridor_green_01`, `_corridor_yellow_01`,
`_powerroom_01`, `_hangarb_01`, `_centertunnel_01`, two
`_livingquarter_room_0N`, `_main_path_01/02`, `_vehicletunnel_01`, plus
`_thermal`, `ve_nvg_mp_subsurface`, `_darkness_soviz_override`) — indoor
"zones" are VE volumes per room, which is exactly the zone-blend model
`highpoly_lighting.gd` already implements for interiors. Note the naming split:
both `ve_mp_mp_subsurface_*` (double `mp_`) and `ve_mp_subsurface_*` exist;
name-derived matching must tolerate both.

Reflection extras: 8 `rveg_centertunnel_*` partitions (reflection cubemaps for
the central tunnel, per the type-DB correction that `rveg_` = reflection, not
interiors).

**There are no cell/portal graph assets and no occlusion volumes — visibility
is 454 hand-placed occluder planes plus streaming subworlds.** For the plugin,
the practical consequence: nothing in the shipped data will cull rooms for us;
draw-call pressure indoors is bounded only by the room structure itself.

### E3. Structure oddities that would confuse a placement walk

**MEASURED:**

- 291 `LayerData` partitions, **140 with zero Objects**. 20 subworld
  partitions: `area_01..area_10` each with `_subworld` + per-area sub-layers
  (`_base`, `_props`, `_decal`, `_signage`, `_roof`, `_cover`, `_sketch`,
  `area_04_light`...), plus room-prefab subworlds.
- **Typo layers ship in retail**: `area_01_deacl.ebx`, `area_02_deacl.ebx`
  (for "decal"), alongside correctly-spelt `area_03_decal.ebx`. Any walk that
  classifies layers by name suffix must not assume `_decal`.
- `lighting.ebx` (2,431 expanded lights) and **`shadows.ebx` (1,946)** are the
  two big light roots — a layer literally named "shadows" carries light
  entities (the shadow-casting subset). Skipping it by name would drop 40% of
  fixtures.
- The level hosts the whole `subsurfacegauntlet*` mode family inside
  `levels/mp_subsurface/` (gauntlet, gauntlet32_extraction, duel/heist,
  medium/vendetta, small/contract + their own shaderstates and network
  registries) — the Granite-on-Tungsten pattern again.
- `jas39/` (Gripen-named directory) sits at the level root containing generic
  `dc_mil_*` prop meshes — directory names are not asset taxonomy.
- 9 gamemode shaderstate depots are byte-identical
  (`shaderblockdepot_9526102139013923511` under breakthrough/conquest/domination
  /koth/operations/payload/rush/squaddeathmatch/strikepoint/teamdeathmatch).
- Largest files are lighting, as everywhere: `enlighten_mp_subsurface_highend`
  70.4 MB + lowend 45.6 MB; `materialgrid_win32.ebx` 14.2 MB.

### E4. Open-task sweep

- **Backdrop/skyline**: `_layers_world/backdrop.ebx` exists and is EMPTY.
  Subsurface ships no backdrop meshes; nothing for the plugin to add. MEASURED.
- **Scatter join validation** (brief's request): **cannot be validated on this
  map** — all `SingleTerrainLayerData.MeshScatteringTypes` arrays are `[]` and
  `meshscatteringdatabaseasset.MeshScatteringDatabase` is 3,645 bytes
  (near-empty). An indoor map has no clutter scatter. MEASURED.
- **Vehicle liveries**: no evidence found in the level tree (not searched
  beyond the level; the map is infantry-focused). Unknown.
- **Cloud-shadow mask**: irrelevant indoors; no `OceanComponentData` or
  outdoor-weather components surfaced in the type scans. Unknown/absent.
- **Per-map FX**: 190 FX partitions, 142 `fx_sub_*` (map-specific family):
  waterfalls, drips, godrays (`fx_contam_godrays_roof*` reused from
  contaminated), gas. A per-map FX pass on this map is mostly water-drip and
  godray content.

---

## F. Generalisation — what holds, what breaks

| finding | scope | verdict vs the laws |
|---|---|---|
| Page size 2,592 (exact decomposition, 99/107 chunks) | subsurface | **Confirms** the derived per-map table and the detect_layout fix row |
| Tile is 17,424 (132²) with **k=1**, even though the page size is dumbo's 2,592 | subsurface (battery/firestorm/limestone/plaza screening in MAP-TUNGSTEN suggests more mixes) | **Refines the law: page size and tile size are independent axes.** A fix that infers tile from page family will be wrong here |
| 8 chunks carry an extra variable-size (~1-6 KB) payload; no decomposition over {height, pages, tile} fits | subsurface | **CONTRADICTS** "every chunk decomposes exactly" as a universal. Colour tile is still the last 17,424 B on all 8; page slicing by arithmetic is what breaks |
| Colour map uniform 0.502 grey (mean per depth 0.502/0.502/0.502) | subsurface (probably any fully-indoor map) | **New case for the 0.5-neutral modulation law**: a map can ship an authored-neutral colour map; colormap_enabled is a designed no-op |
| Paired chunks end with 4 child tiles, reversed order; 100% mode 6 | subsurface | Confirms TERRAIN.md §5 |
| BC7 mode test separates colour tiles from non-tiles | subsurface | Confirms (100% modes 4-7 vs 0% on pages) |
| No water types at all in 1,897 partitions | subsurface | Extends the water law: check for absence before height |
| ECS prefabs: 27/27 empty stubs | subsurface | Confirms |
| All real albedo textures on BASE layers | subsurface | Confirms (absolute here, like Tungsten) |
| `0xAE16A5C0` = crater slot, exactly one layer (L22) | subsurface | Confirms — but the L(n+1..) → crater *link* structure is absent (linked list empty) while the crater-material layers (L23-26) still exist as plain base layers |
| Decal slotCount 27 != layerCount 28 | subsurface | **CONTRADICTS** "decal slot table has one entry per terrain layer" (equality held on Tungsten) |
| Terrain dir naming `mp_subsurface_terrain` | subsurface | Confirms the inconsistency law |
| `BackgroundMaterialIndex = 0x00000080` sentinel | subsurface | Same as dumbo/eastwood |
| Block-7 walk: 76 nodes vs 101 declared, slack -28 | subsurface | New parse wrinkle, unexplained; decoded field is spatially correct |

---

## G. Next actions for the plugin, in priority order

1. **`addons/highpoly_toggle/bf6_splat.gd::detect_layout`** — when implementing
   the exact-decomposition fix, detect page and tile **independently** and
   allow `k = 0 or 1` tiles with page 2,592 (this map) as well as dumbo's
   `(2592, 4624, k=1)` and Tungsten's `(4356, 17424, k=2)`. Verification row
   for MP_Subsurface: page **2,592**, tile **17,424**, one tile, 99/107 chunks
   exact; treat the 8 anomalous chunks as "colour tile from the tail, pages
   unknown" rather than failing the whole map.

2. **`addons/highpoly_toggle/highpoly_gamesource.gd::_light_record`** — read
   `AffectDiffuse` / `AffectSpecular` and **drop lights where both are false**
   (1,471 of 4,883 here, including every `pf_lighting_radiosity_*` bounce
   light). Cuts cluster pressure 30% and removes double-counted bounce.

3. **`addons/highpoly_toggle/highpoly_lighting.gd`** — the 150 m radius cull
   cannot work on this map (3,582 lights in radius at the hotspot; 803 within
   25 m; Forward+ caps at 512). Replace/augment with a nearest-N budget (e.g.
   keep the closest ~400 by distance, headroom under 512), and surface the
   dropped count in the status line the way `PROP_LIGHT_CAP` already does for
   props. This is the fix for task #80, and Subsurface is its test map.

4. **`addons/highpoly_toggle/highpoly_gamesource.gd::water()`** — handle "no
   partition contains WaterSurfaceEntityData" as a first-class case with a log
   line ("level ships no water entity"); Subsurface is the map where every
   water read returns nothing.

5. **Per-map expectation table (docs/GROUND-LAYERS.md or the map-notes file)**
   — record Subsurface: colour map authored neutral 0.502 grey (colormap on =
   no visible change, and that is correct); terrain is 98.5% one default
   layer; do not use this map to validate colour-tile fixes.

6. **Placement-walk hardening (`highpoly_mapcontext.gd` / the miner)** —
   tolerate the `deacl` typo layers, the `shadows.ebx` layer carrying lights,
   the `lightingpropsa`/`_b_N` random-layout variants (pick ONE set — `a` — or
   dedup by position, else rooms double-light), and the `subsurfacegauntlet*`
   mode content living inside the level directory.

7. **Upstream note to `BF6_Frostbite_Research/formats/TERRAIN.md`** — §5:
   trailer tile size is independent of page size (2,592-page maps can carry
   132² tiles, k=1), and some chunks contain an extra unidentified
   variable-size payload that breaks exact decomposition while leaving the
   colour tile at the tail; §10: decal slotCount can differ from layerCount
   (27 vs 28 here).
