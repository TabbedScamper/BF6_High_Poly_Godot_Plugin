# MP_Abbasid, end to end

One map read from the shipped data, following `MAP-TUNGSTEN.md`'s structure and
verifying its laws here rather than re-deriving them. **Every claim is tagged
MEASURED or HYPOTHESIS**; a MEASURED claim names the resource/value and the
probe that reproduces it. Probes live in `tools/probe_abbasid_*.py` and reuse
the `probe_tung_*.py` plumbing (all level-parameterised); everything is
read-only against the 2026-08-01 pull via
`BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`.

```
tools/probe_abbasid_decomp.py       chunk decomposition + BC7 mode histograms
tools/probe_abbasid_colorrender.py  BC7 colour tiles -> FIXED_MP_Abbasid.png
tools/probe_abbasid_scopes.py       subworld/depot scope census vs layer_of_scope (task #77)
tools/probe_abbasid_supremacy.py    census of the One-Off Supremacy tscn
(reused as-is: probe_tung_{terrain,structure,water,types,layers,colormap,
 basefield,decals,ecs}.py mp_abbasid)
```

## 0. The map in one paragraph

**MEASURED.** MP_Abbasid is a **2,048 x 2,048 m** world (block-0 root AABB
`x,z ∈ [-1024, 1024]`), ground from **y = 58.313 to y = 89.345** (31 m of
relief), `WorldSizeY = 1024.0` (u16 step 1.56 cm), 265 samples per node, **57
streaming nodes** (52 persistent). Terrain palette is **42 layers**, of which
**16 bind any texture, 7 carry a real albedo, and all 7 albedo layers are base
layers**. It
ships 540 terrain-decal records in 39 material groups, **zero water entities of
any kind**, 43 ShaderBlockDepots, 258 `LayerData` partitions (106 with zero
Objects), 43 `EcsRuntimePrefabAsset`s (42 empty stubs), 27 in-level backdrop
building MeshSets, and a 4,070-point generated "AftermathScatter" debris layer.
The city itself occupies only the central ~600 m; the rest of the world square
is backdrop terrain.

---

## A. Water

**MEASURED — MP_Abbasid has NO water entity at all.**
`probe_tung_types.py mp_abbasid --find "water|ocean|river"` scans all **6,090**
partitions under `game/glaciermp/levels/mp_abbasid` and finds **0** partitions
declaring any water-named type. No `WaterSurfaceEntityData`, no
`WaterEntityData`, no `WaterAsset`, no `OceanComponentData`, not even the
`WaterLevelDescriptionComponent` tungsten's `description.ebx` carries.

**MEASURED.** `_layers_content/water.ebx` exists but is an empty `LayerData`
(`Objects = []`, 416 bytes). `_layers_content/water_shared_schematic.ebx`
holds only schematic plumbing (`SchematicChannelEntityData`,
`MathOpEntityData`, `AreaProximityEntityData`) — a shared channel graph wired
to nothing. (`probe_tung_water.py mp_abbasid`)

**Consequence for the plugin.** The water-vs-terrain-floor diagnostic
(MAP-TUNGSTEN A3) does not even apply here — there is no Y to compare against
the 58.31 m floor. **This contradicts the assumption recorded in
`highpoly_gamesource.gd::_water_partition()` ("the entity is always somewhere;
only its partition varies"): on MP_Abbasid it is nowhere.** `water()` must
treat an absent water partition as a normal, loggable outcome, not a lookup
failure.

Oddity, recorded because it will confuse someone: the level ships
`lighting/t_mp_abbasid_flowmask_01.Texture` (a flow mask) and a fountain sound
spot (`SFX_..._Spots_Fountain_SimpleLoop3D`) on a map with no water body.

---

## B. Terrain and ground layers

### B1. Decomposition table (THE detect_layout verification row)

**MEASURED**, `probe_abbasid_decomp.py`, cross-checked against per-node page
counts read from block 1 (`probe_limestone_decomp.splat_page_counts`):

```
page size        4,356 bytes  (raw 66x66 weight page)      <- law's table: 4356. CONFIRMED
colour tile     17,424 bytes  (132x132 BC7, 128 core + 2px apron)
height prefix   {149297} on 52 primary chunks, {0} on 5 (root + all 4 depth-1)
ambiguity       0 of 100 chunks; every chunk decomposes exactly, residual 0

primary (57):   [149,297 heights] + m x 4,356 pages + ONE 17,424 tile   (52 chunks)
                [no heights]      + m x 4,356 pages + NO tile           (5 chunks: keys 0x3, 0x30..0x33)
                m = the node's own block-1 header page count: exact on 57/57
paired  (43):   sum(children's m) x 4,356 + exactly 4 x 17,424 child tiles: exact on 43/43

BC7 mode histogram (aggregate):
  primary tile[-1]  62,073 blocks  91.3% modes 4-7   (100% on the 52 tile-bearing
                                    chunks; the 5 tile-less chunks pollute the pool)
  primary tile[-2]  62,073 blocks   2.0% modes 4-7   <- weight pages, not a raster
  paired  tile[-1..-3]              100% modes 4-7   <- the 4 grouped child tiles
```

**The colour tile is the LAST thing in the primary chunk and there is exactly
ONE per node** — unlike Tungsten (two 17,424 tiles, colour FIRST) and unlike
dumbo (one 4,624 tile). The stable cross-map rule is therefore: decompose
exactly, then identify the colour tile by the BC7 mode test — never by a fixed
position or a fixed size.

**MEASURED — what the current plugin does here.** MAP-TUNGSTEN C3 already
simulated `bf6_splat.gd::detect_layout` on all 16 maps: on mp_abbasid it picks
`(page 2592, tile 4624)` against the true `(4356, 17424)`. So today the plugin
BC4-decodes weight-page slices cut at wrong offsets (wrong codec, wrong
stride), and its "colour tile" is the last 4,624 bytes of the real BC7 tile —
genuine colour data, but decoded as a 68x68 tile instead of the tail of a
132x132 one, so it is a misregistered crop.

### B2. The colour map, rendered

**MEASURED.** `probe_abbasid_colorrender.py` decodes the 52 real tiles
(Pillow/DDS BC7 via `bf6_colormap.py`) and writes
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Abbasid.png`.
**It reads as a coherent aerial: the central city's road grid, block structure
and two dark north-south arterials are clearly legible on a uniform
0.5-neutral field**, and the painted footprint coincides with the terrain-decal
AABB (x -339..225, z -276..242 — B4). Mean RGB over all tiles **(0.505, 0.501,
0.496)** — this map's colour raster is genuinely near-neutral outside the
playable area, which is exactly what the corpus's "0.5 = no modulation" law
predicts for a modulate-semantics colour map. No SDK overhead image exists for
Abbasid to compare against (`addons/bf_portal/terrain_decal/textures/` ships
only Aftermath, Capstone, Tungsten), so coherence is judged on structure, and
it passes.

### B3. The 42-layer palette

**MEASURED** (`probe_tung_layers.py mp_abbasid`): layer-graph record table at
offset 196 located by the all-keys-resolve rule (42/42 in the depot,
`abbasid_terrain2k.layergraphs_shaderblockdepot`, 42 keys over 30 deduplicated
records). Splat block 1: 27 painted layers, 16 base layers (L01 appears as
both, x138 painted / x8 base). **All 7 real-albedo layers are base layers**,
so the materials-live-on-the-base-side law holds for albedo — but it is NOT
absolute for "any texture" here: **two painted layers, L16 and L25, bind a
texture** (the detail normal map `t_rst_sanddetail_01_nm`, nothing else). A
reader that uses "binds a texture" as a proxy for "base layer" mis-sorts two
layers on this map.

| group | layers | textures |
|---|---|---|
| real albedo (7) | **L08, L09** `naf_tileshexagon_01` (pavement tiles); **L37** `wum_asphaltedge_01`+`wum_crackedconcrete_03`; **L38** `wum_ls_gravel_02_a/b`+concrete; **L39** `wum_ls_gravel_01_a`+`wum_td_sand_01_ncs`; **L40** `naf_sandrough_01`+sand; **L41** `wum_concretedebris_01/02` | full `_cv/_nhs/_ao` sets |
| placeholder set (5) | L10, L11, L12, L13, L23 | `t_ter_defaulttexture_{cv,ao,nhs}` only |
| ao/nm only (3) | L15 (`t_ter_defaulttexture_ao`), L16, L25 (`t_rst_sanddetail_01_nm`) | no albedo |
| crater (1) | **L36**: `hfd_debug` at slot **`0xAE16A5C0`** | confirms the crater-slot law |
| textureless (26) | everything else | constants only; L26–L35 share one depot record with **no parameters at all** |

**MEASURED — crater law confirmed:** list 2 (linked) = {37, 39, 40, 41}, all
linking to L36, the only binder of `0xAE16A5C0` — same structure as Tungsten
L29-32→L28 and dumbo L42-45→L41, different indices (and note L38 is textured
but NOT linked). `0xCF3F97E0` is again integer-typed with values {0, 2, 4}.
`0xCBB9A946` is (0,0) on all 42 layers. Curious cross-map detail: Abbasid
L15's depot key `958F2824AC0D7783` is byte-identical to Tungsten L10's (the
same "default ao + neutral constants" record content).

### B4. Block 7 and the honest albedo ceiling

**MEASURED** (`probe_tung_basefield.py mp_abbasid`): dim=256, 76 walked nodes,
0 bad RLE rows, `pairCount = 8`, `BackgroundMaterialIndex = 0x0660FA80 -> L10`
(numerically the same pair value as Tungsten's background, resolving to index
10 on both maps). Texel share: **L00 73.1%** (textureless), **L10 15.0%**
(placeholder default-texture set), L07 8.2% (textureless), L12 2.6%
(placeholder), **L39 0.9%** (the only real-albedo layer block 7 ever selects),
L02 0.2%, L01 0.0%. Pair 6 `X=0x31 -> wum_ls_gravel` family reproduces the
cross-map X=0x31 observation a third time.

**So block 7 resolves real albedo on 0.9% of this map's ground** (Tungsten:
20.6%). Abbasid's ground colour lives almost entirely in (a) the colour map
and (b) the terrain decals; the textured tile/pavement layers L08/L09 are
reached through the decal slot table (below), not the base field. Block
census: blocks 0, 1, 4, 7, 8 — **no block 2 (density) and no block 5** (which
Tungsten has). `LayerSlotCount = 6` (same as Tungsten, vs 62 on the dumbo
family). One parser note: the block-7 node stream ends 40 bytes into the
64-byte footer window (`slack=-40` vs 0 on tungsten/dumbo) — rows all decode;
the footer self-locates regardless; not chased further.

---

## C. Decals and roads

**MEASURED** (`probe_tung_decals.py mp_abbasid`): `decals.TerrainDecals` is
3,456,084 bytes; **slotCount 42 = layerCount** (9 slots carry a GUID),
recordCount **540**, all parsed, **0 chain breaks**. Used slots: 10 (256
recs), 8 (108), 15 (75), 11 (68), 23 (20), 12 (11), 9 (1) — **exactly the
placeholder/tile-textured base-layer indices of B3**, plus **one record with
slot 65535 and an empty GUID** (a reader that indexes the slot table by record
slot without a bounds check dies on this map). 39 texture-set groups, all
North-Africa families: cobblestone roads, pavement tiles (incl.
`naf_tileshexagon` matching L08/L09), soil planters, manhole covers, gutter
splines from the *southerneurope* library, plus two mask-only groups
(`naf_roadvariationmask_01`, 61 recs; `naf_trackstiresand_01`, 14 recs — the
`_op`-only class of MAP-TUNGSTEN D). One group has an Abbasid-specific
basecolor over shared normals (`naf_dirttrackspline_abbasid_01_cv` +
`_02_nhs`) — group by whole texture set, never one slot.

Decal AABB over all 540 records: x -339..225, z -276..242, y 58.6..70.7 —
decals exist ONLY in the central city, matching the colour map's painted
footprint one-for-one.

---

## D. Everything else notable

**MEASURED — structure** (`probe_tung_structure.py mp_abbasid`): 258
`LayerData` partitions, 106 with zero Objects. Busiest:
`generated/ag_aftermathscatter_aftermathentities_20abeece` (**4,070**),
`fx_global` (304), `area_06_volumedecals` (267), `area_08` (266), `area_02`
(263), `lighting` (252), `lighting_lightprobes` (225). World content in
**ten** area subworlds (01, 02, 03, 03b, 04, 04b, 05, 06, 07, 08) + `world` +
eight per-gamemode subworlds; see E for where they sit. Largest files:
enlighten highend 92.9 MB / lowend 60.5 MB, materialgrid 15.8 MB — lighting
dwarfs geometry again.

**MEASURED — the AftermathScatter layer.** One generated partition holds 4,071
instances: a LayerData plus 4,070 point entities of an un-named type
(`2a85e577-…`), each carrying a Vec3 position (Y ≈ 65-110, inside the city), a
per-point `Asset` import and one shared import — battle-damage debris
scattered as points, the single largest object layer in the level. The plugin
does not currently read this class of content at all.
(`probe_tung_ebx.py .../ag_aftermathscatter_....ebx`)

**MEASURED — backdrop/skyline.** 27 `bd_naf_buildingsabbasid_NN_mid` MeshSets
ship **inside the level** (`backdrop/buildings/`, 81 files), plus
`_layers_world/backdrop.ebx` (96 objects) and 25 `backdrop/Building_03`-class
distant meshes; `generated/backdropbuildings_output.ebx` is one of the empty
generated layers. Skyline meshes are available from the install for this map.

**MEASURED — lighting/atmosphere inventory** (`lighting/`): cloud-shadow masks
**`t_mp_abbasid_cloudshadows_02/03.Texture`** (open-task item), panoramic +
gradient sky textures, `hdrcube_mp_abbasid_16`, 6 `ve_*` presets — base,
interior_01, thermal, and **three `ve_mp_abbasid_sovis_test_*` test presets
shipping in retail** (brightonbright, darkondark, fogdistance). Prop-light
evidence: 88 `PbrSphereLightEntityData` + 75 `LightProbeVolumeData` + 61
`OccluderVolumeEntityData` in the type census; `EnvironmentDecalVolumeData`
appears in 14 world layers (areas, backdrop, signage).

**MEASURED — ECS prefabs** (`probe_tung_ecs.py mp_abbasid`): 43 total, **42
are the identical empty stub** (`ent=1 arch=1 seg=1 edits=0 comps=[26]`), one
(`default_ecsprefab`) is a near-stub variant (`ent=1 arch=1 seg=3 edits=1
comps=[0,42,46]`). No populated multi-entity prefab exists on this map —
empty-stub law holds.

**MEASURED — scatter join NOT validatable here.** The level ships a
MeshScatteringDatabase RES (12,744 B, `mp_abbasid/meshscatteringdatabaseasset`)
but **all 43 `SingleTerrainLayerData` instances have `MeshScatteringTypes =
[]`** (`probe_tung_ebx.py .../abbasid_terrain2k.ebx`) — the urban map has no
terrain clutter scatter, so the Identifier→catalogue join stays unvalidated.

**MEASURED — naming oddities that break path-building.** (1) The terrain
directory is **`abbasid_terrain2k`** — a THIRD naming pattern after
`terrain_mp_tungsten` and `mp_dumbo_terrain`; search, never construct. (2) Its
decal resources sit under a nested mirrored path
`abbasid_terrain2k/abbasid_terrain2k_game/glaciermp/levels/mp_abbasid/mp_abbasid/decals.*`.
(3) `_layers_content/fx_backrop.ebx` — "backrop", a shipped typo a
`*backdrop*` grep misses (102 + 93 objects of backdrop FX). (4)
`t_mp_abassid_01_portallight_open` — "abassid". (5) `description.ebx` is
ABSENT on this level (present on tungsten).

---

## E. Subworld / layer structure — task #77 (wrong-mode and missing props)

MP_Abbasid has **no `default_event`, no `winter_event`, no `sub_art_*`** — the
naming `layer_of_scope()` was derived from on MP_Aftermath simply does not
occur here. What it has instead (`probe_abbasid_scopes.py`, 41 depot-owning
scopes):

```
world content    _layers_world/{world, area_01..area_08(+b)_subworld}   (9 areas)
                 area_02_subworld  <-- AT THE LEVEL ROOT, not _layers_world
gamemode dress   _layers_world/{breakthrough,conquest,escalation,payload,
                                rush,squaddm,strikepoint,teamdm}_subworld
                 squadobliteration <-- at the level root
gameplay layers  _layers_gameplay/<mode>/<mode> (x/x dirs), plus flat layers
                 (kingofthehill, sabotage, sharedassets_*, portal_gameplay...)
other            _layers_autotests/autotests, _layers_content/content
```

Running the CURRENT `layer_of_scope` rules over those scopes (MEASURED, 1:1
port in the probe):

1. **All 8 gamemode `*_subworld`s return "" (always visible)** because they
   live under `_layers_world` — Rush barriers, Breakthrough covers, Payload,
   Escalation and both-DM dressing all drawn at once in every mode. This is
   the "gamemode props showing when they should not" fault, mechanically.
2. **`area_02_subworld` returns "area_02_subworld" (hidden by default)**
   because this one world area sits at the level root — a whole city block
   (263 objects, 6.4 MB physics, own depot) missing in the default view. This
   is the "missing props" fault. `squadobliteration` (root) is hidden too,
   which happens to be right for a mode but for the wrong reason.
3. **The `leaf == dir.get_file()` level-root rule collides with the
   `_layers_gameplay/<x>/<x>` convention**: breakthrough/conquest/domination/
   payload/rush/strikepoint/**testlevelmode** gameplay layers all return ""
   and are always visible — including test-level content.
4. `sharedassets_koth_sdm_tdm_dom` / `sharedassets_tdm_dom` become standalone
   hidden layers with no link to the modes that need them.

**Depot scope gap (the white/wrong-material class):** `area_02_subworld` and
`squadobliteration` own root-level depots
(`area_02_subworld_win32_shaderstate`, 4.16 MB;
`squadobliteration_win32_shaderstate`, 2.03 MB). Any depot discovery or scope
assignment that only walks `_layers_world/*` misses them, and by the
depot-is-graph-ancestry law their sections then dress from the wrong depot —
the user-marked "wrong/missing materials on map-context meshes" matches
area_02 exactly. HYPOTHESIS as to it being the *specific* marked meshes (the
markers' coordinates were not available to this study); MEASURED that the
mechanism exists and names area_02.

### The One-Off Supremacy scene

**MEASURED** (`probe_abbasid_supremacy.py`):
`User_Created/levels/User_Maps/One-Offs/MP_Abbasid_Supremacy_details_lights.tscn`
is a hand-built user map, **root node named "MP_Abbasid"** — so `map_of()`
detection works; that is not the problem. Content: 2,054 nodes, 1,962
instanced from 198 scenes; the map body is just the two SDK static bakes
(`static/MP_Abbasid_{Terrain,Assets}.tscn`); the placed content is dominated
by **light fixtures (426)**, small props (601: sandbags, Hescos, trash,
planters), modular walls, **294 instances from other maps' asset families**
(FiringRange x236, BR_* x24, OutskirtsHouse x28), 52 FX fires, 25 backdrop
buildings. **HYPOTHESIS** for "very few high-poly assets": the scene's
identity mesh volume is foreign-family and fixture-class content that a
level-filtered mp_abbasid lookup cannot resolve (the mount-carries-every-level
law requires filtering on the level, and FiringRange/BR/Outskirts meshes are
not in mp_abbasid's content), while the two static bakes carry everything
recognisable. Not measurable this session: no MP_Abbasid mapcontext cache or
plugin log exists on this machine to count actual swaps.

---

## F. What generalises / what contradicts the laws

| finding | scope | note |
|---|---|---|
| Page size **4,356** confirmed by exact decomposition, 100/100 chunks, zero ambiguity; block-1 page counts reproduce every chunk size byte-exactly | verification row | detect_layout fix must output (4356, 17424) here |
| **One colour tile per node, positioned LAST** (Tungsten: two, colour FIRST; dumbo: one 4,624) | **CONTRADICTS any fixed-position rule** | the only safe rule is exact decomposition + BC7 mode test |
| **Zero water entities in the level** | **CONTRADICTS "the water entity is always somewhere"** (`_water_partition()` comment) | water() needs an "absent" path |
| default_event / winter_event is Aftermath-specific; Abbasid stratifies by gamemode `*_subworld`s under `_layers_world` + root-level subworlds | every map | layer_of_scope's Aftermath heuristics misclassify 11+ scopes here (E) |
| Materials on the base side | every map, **refined** | holds for ALBEDO (7/7 base); two PAINTED layers (L16, L25) bind a detail normal map — "binds any texture" is not a base-layer test |
| Crater slot `0xAE16A5C0`, one layer per map, linked-layer structure | every map | confirmed (L36; links {37,39,40,41}) |
| `0xCF3F97E0` integer {0,2,4}; `0xCBB9A946` = (0,0) | every map | confirmed |
| Empty ECS stub is boilerplate | every map | confirmed (42/43; the 43rd is a 1-entity variant, still no content) |
| Terrain dir naming now has a THIRD pattern (`abbasid_terrain2k`) + nested mirrored decal path | every map | never construct the path |
| Scatter join | unvalidatable here | all `MeshScatteringTypes` empty despite a shipped catalogue RES |
| Real-albedo ceiling via block 7: **0.9%** (Tungsten 20.6%) | per-map magnitude | on urban maps colour = colour map + decals; the splat fix matters less here than the colour-tile fix |

---

## G. Next actions, in priority order

1. **`bf6_splat.gd::detect_layout` / `color_tiles`** — verify the fix against
   this row: mp_abbasid = page 4356, tile 17424, ONE tile, colour LAST, 5
   tile-less chunks (root + depth-1); select the colour tile by decomposition +
   BC7-mode test, not position (Tungsten first-of-two, Abbasid only-and-last).
2. **`highpoly_gamesource.gd::layer_of_scope`** — three changes driven by E:
   (a) `<mode>_subworld` leaves under `_layers_world` are gamemode layers, not
   always-on (strip `_subworld` for the layer key so they join the mode
   dropdown); (b) root-level `area_*_subworld` is world content, always-on;
   (c) restrict the `leaf == dir.get_file()` rule to the actual level root so
   `_layers_gameplay/<x>/<x>` (incl. testlevelmode) stops being always-on.
   This is the direct fix for task #77's two prop-fault classes.
3. **Depot scope discovery** (`bf6_walk.gd` scope_index build) — include
   root-level subworld depots (`area_02_subworld_win32_shaderstate`,
   `squadobliteration_win32_shaderstate`) so area_02 sections stop resolving
   textures from the wrong depot (the white-surface class).
4. **`highpoly_gamesource.gd::water()`** — handle "no water partition in the
   level" as a logged fact ("MP_Abbasid ships no water entity — nothing to
   draw"), not a silent miss; remove reliance on the always-somewhere comment.
5. **Colour map enablement** (`highpoly_mapcontext.gd`) — after 1, Abbasid is
   a good soak test for modulate semantics: near-0.5 neutral over 90% of the
   world with real colour only downtown; if the ground tints visibly outside
   the city after enabling, the blend is wrong, not the data.
6. **AftermathScatter point layer** (`bf6_walk.gd` / gamesource) — decide
   whether to render the 4,070-point generated debris layer; it is the largest
   single object layer on the map and entirely invisible today.
7. **Skyline** — the 27 `bd_naf_buildingsabbasid_*_mid` MeshSets are in-level;
   confirm they appear in the walk's SMG-from-level-root class like Tungsten's
   155 (level root has exactly one `StaticModelGroupEntityData`, so vista
   instancing likely hangs off the subworlds here — worth one probe when the
   skyline task is picked up).
8. **Cloud shadows** — `t_mp_abbasid_cloudshadows_02/03` answers the per-map
   cloud-shadow-mask question for this map; wire alongside the ve_ decode.
