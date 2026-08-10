# MP_Dumbo, end to end

The BASELINE map: the one the old plugin behaviour was closest to right on, and
the corpus's most-validated decode (68^2 colour tile, page 2592). This study
verifies every established law from `MAP-TUNGSTEN.md` / `TERRAIN.md` holds here
exactly — so the detect_layout fix provably does not regress the maps that
already worked — and documents the two things Dumbo has that Tungsten does not:
a **populated `EcsRuntimePrefabAsset`** (three of them) and a **shipped backdrop
generation chain**.

**Every claim is tagged MEASURED or HYPOTHESIS.** Probes are
`tools/probe_dumbo_*.py` plus the already-parameterised `tools/probe_tung_*.py`
run with `mp_dumbo`; all read the extracted 2026-08-01 pull through
`BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`, read-only.

```
probe_tung_terrain.py mp_dumbo    blocks 0/1/7/8, layer table, VisualTerrain
probe_tung_layers.py mp_dumbo     layer -> depot -> textures/constants
probe_tung_ecs.py mp_dumbo        ECS prefab census (54 stubs + 3 populated)
probe_tung_decals.py mp_dumbo     TerrainDecals
probe_tung_colormap.py mp_dumbo   chunk-tail BC7 mode histograms
probe_dumbo_decompose.py          THE decomposition table, all 485 chunks
probe_dumbo_detectsim.py          the FIXED detect_layout simulated on real data
probe_dumbo_colorrender.py        true-BC7 colour map -> FIXED_MP_Dumbo.png
probe_dumbo_ecs.py                the three populated prefabs, dumped in depth
```

---

## 0. The map in one paragraph

**MEASURED.** MP_Dumbo is an **8,192 x 8,192 m** world (block 0 root AABB
`x,z ∈ [-4096, 4096]` — twice Tungsten's span), ground from **y = 24.750 to
y = 110.674**, `WorldSizeY = 256.0` (finest height quantisation of the set,
0.39 cm/step), xs = 265, container NodeCount **277** (PersistentNodeCount 100).
Terrain palette **47 layers** (30 painted / 16 base / L38 + L46 in no splat
record), blocks 0 / 1 / 4 / 7 / 8 (no density block 2, no block 5). One
`WaterSurfaceEntityData` at **y = 49.80**, 25.05 m above the terrain floor —
one of the two maps where water actually renders. 328 `LayerData` partitions
(190 with zero Objects), 44 ShaderBlockDepots, 57 `EcsRuntimePrefabAsset`s of
which **3 are populated**. World content sits in `sub_art_00..10` subworlds and
`lay_art_*` layers (note the shipped typos `gloabl`, `lighitng`); the terrain
directory is `mp_dumbo_terrain` (suffix form, vs Tungsten's prefix form).

---

## 1. THE DECOMPOSITION TABLE (verification row for the detect_layout fix)

**MEASURED — every one of the 485 on-disk chunks (277 primary + 208 paired)
decomposes byte-exactly, zero failures** (`probe_dumbo_decompose.py`), as

```
size = heightPrefix + storedPages x 2592 + k x 4624
```

with `storedPages` predicted independently per node from block 1 (a node's
painted records) — so this is one equation with no free variable, not a fit:

| chunks | which | depth | height prefix | k x 4624 | note |
|---|---|---|---|---|---|
| 5   | primary | 0-1 | 0 (Packed heights) | **k = 0** | pages only — NO colour tile |
| 100 | primary | 2-6 | 149,297 (External) | k = 1 | |
| 172 | primary | 3-6 | 0 | k = 1 | |
| 208 | paired  | 3-6 | 0 | **k = 4** | four child tiles, reversed order |

- **Page size 2592, tile 4624 = 68^2 BC7 — confirmed.** Distinct primary
  residuals (size − pages x 2592): **{0, 4624, 153921}**, i.e. {nothing,
  one tile, 149297 + one tile}.
- **Height-prefix set observed on Dumbo: {0, 149297} only.** 39,919 and the
  sums (189,216 / 2x149,297) never occur here. 149,297 is exactly this map's
  inline height payload (xs 265: 265²·2 + 4358 + 4489).
- **BC7 mode histogram** over every k ≥ 1 trailer: FIRST tile **100.00%**
  modes 4-7 (138,720 blocks: m6 93.8%, m7 3.4%, m4 2.5%, m5 0.4%); LAST tile
  **100.00%** (on Dumbo first = last for primaries, and all four paired tiles
  are real colour tiles). The mode-test law holds with nothing to spare.
- **The k = 0 counter-case.** The 5 depth-0/1 chunks' final 4,624 bytes are
  mode-0-dominated (`probe_tung_colormap.py mp_dumbo`: node 0x3 tail = m0:289)
  — they are weight-page bytes, not a tile. Any reader that unconditionally
  takes "the last 4,624 bytes of the chunk" as the colour tile is wrong on the
  baseline map's root nodes. k = 0 must stay legal in `_tiles_in`.
- **The fixed detect_layout picks Dumbo decisively** (`probe_dumbo_detectsim.py`
  mirrors the rewritten scoring): page 4356 and 5184 are REJECTED outright
  (negative residuals); 2592 fits with 3 distinct residuals; tile 4624
  decomposes all three. **Picks (2592, 4624). No regression.**
- **Paired-chunk law verified:** paired size = children's pages + exactly
  4 x 4624 at the END, zero height prefix, 208/208. The reversed child order
  [3,2,1,0] is confirmed visually: the assembled map (below) is seamless — a
  wrong order would checkerboard every 2x2.
- The 16 paired chunks belonging to chunk-directory **leaf** nodes decompose
  only when their children are derived arithmetically ((key<<4)|i): block 1
  has 341 nodes vs 277 chunk-directory nodes, and the extra **64 = 16 x 4**
  are exactly those children. A pages-lookup keyed on chunk-directory nodes
  alone under-counts these 16 paired chunks.

## 2. The colour map, rendered

**MEASURED.** `probe_dumbo_colorrender.py` (true BC7 decode via
`impl/pipeline/bf6_colormap.py`, apron-cropped, coarse-first) assembled all
**1,104** colour tiles — 272 primary (277 − 5 with k = 0) + 832 paired (208x4)
— into

```
%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Dumbo.png
```

**It reads as one seamless aerial photograph of Brooklyn and lower Manhattan**
— East River, Manhattan/Williamsburg bridges, Navy Yard, Governors Island, the
BQE, block-level street grid — with no tile seams, no quadrant swaps, no hue
cast. True pixel mean RGB **(0.500, 0.500, 0.500)** — exactly the 0.5-neutral
of a modulate map — and tile alpha mean **0.018** (like Tungsten's 0.002;
alpha does not carry AO here as it does on plaza). No SDK overhead reference
exists to compare against: `addons/bf_portal/terrain_decal/textures/` ships
only MP_Aftermath / MP_Capstone / MP_Tungsten. Caution for mean-checks:
Pillow `resize((1,1))` is NOT a true mean (it gave 0.084); use `ImageStat`.

---

## A. Water

**MEASURED — the entity lives in `mp_dumbo/default.ebx`,** not in
`_layers_content/water.ebx` (that layer exists with `Objects = []`).
Third observed location (tungsten `_layers_content/water.ebx`, aftermath
`_layers_content/water`), confirming "the entity is always somewhere; only its
partition varies" — a path-keyed reader misses it here.

```
Transform  right (4096,0,0)  forward (0,0,4096)  trans (0.0, 49.800, -285.235)
QueryBoxHalfExtent (2048.0, 0.5, 2048.0)      TileOffset (0, 0, 0)
MaterialPair.Packed 114308233 = 0x06D03489    (identical to Tungsten's)
StateKey 0x42F38EEAAC4AA54E   AdditionalWaterDepth 0.0
ShoreDepth 100.0              ProjectorElevation 8.0
```

- **Water y 49.80 vs terrain floor 24.75 → 25.05 m above. Renders.** Verifies
  the A3 table row and the above/below-floor law from the rendering side.
- **`TileOffset` (+0xB0) is (0,0,0), `QueryBoxHalfExtent` (+0x90) carries the
  half-extent, instance size 0x280** — the §A4 correction holds on Dumbo.
- **The plane is NOT world-sized here.** 4,096 x 4,096 m centred at
  (0, −285.2) in an 8,192 m world — it covers the East River band, about a
  quarter of the map. Tungsten/eastwood had world-sized planes; a consumer
  that assumes "water = world quad" over-draws Dumbo by 4x.
- Ocean simulation types present: `WaterOceanSimulationEntityData` in
  `default_schematic.ebx`, `OceanComponentData` in
  `lighting/ve_mp_dumbo_suncloudy_04.ebx`.

## B. Terrain and ground layers

**MEASURED — palette 47 layers** (`VisualTerrain` layerCount 47, LayerGraphs
recordCount 47, depot 47 keys over 40 content-deduplicated records, 47/47
resolve). **L42..L45 link to L41**; **L41 binds `hfd_debug` at slot
`0xAE16A5C0`** — the crater layer, exactly as published (`dumbo L41`), and
L42..L45 are the crater materials (`wum_asphaltedge/crackedconcrete`,
`wum_ls_gravel_01_a`, `wum_dryrockygravel`, `wum_ls_gravel_02_b/burntdebris`).

**MEASURED — the layer-graph table-location trap reproduces here.** The weak
rule ("keys non-zero and distinct") fires at offset **148** and prints a
plausible, wrong table (`probe_tung_terrain.py`'s output for L00/L01 is
garbage rows from it). The load-bearing rule ("every ShaderBlockKey resolves
in the paired depot") finds the true table at **216** — again exactly 68 bytes
later, as on Tungsten (92 → 160). The 100%-resolve rule is not optional.

Splat (block 1): LayerSlotCount **62**, 341 nodes, 31,123 records, slack 0.
30 painted / 16 base, reproducing the published census. L06 appears on both
sides (painted x846, base x3), like Tungsten's L01/L04. L38 and L46 appear in
**no** splat record. Map-global base palette (x1364 records): L02 L03 L04 L08
L10 L21 L30 L39 L40 L41 L42 L43 L44 L45 (+L00 x1361); painted majors: L11 L12
L28 x1364, L05 x1361, L37 x1343, L22 x1016, L06 x846, L09 x840.

**Textures.** 10 of 47 layers bind a colour (`_cv`) texture — 8 base, 2
painted (L13 `t_wum_m_sand_02`, L22 `t_wuu_grass_fairway_01`), so
"materials live on the base side" is strong but, unlike Tungsten, **not
absolute** here (published as "11-of-16 on dumbo"):

| L | side | colour texture | tiling (0x5707A992) |
|---|---|---|---|
| 02 | BASE | `t_euu_cobblestone_01` | 0.10 |
| 08 | BASE | `t_euu_concretetile_01` | — |
| 10 | BASE | `t_naf_asphaltbrokendecal_01` | — |
| 13 | painted | `t_wum_m_sand_02` | — |
| 21 | BASE | `t_cas_asphaltedge_01` (+`_op`) | — |
| 22 | painted | `t_wuu_grass_fairway_01` | — |
| 42-45 | BASE | crater set (via L41) | — |

Plus mask/detail-only binders: L03/L04 (`t_wuu_sandnoise_02`), L05
(`t_gen_breakupmask_02` + `t_com_asphaltdetail_02_ncs`), L40
(`t_gen_breakupmask_02`). The other 33 layers bind **nothing** — constants
only (`0x5707A992` tiling, `0xFA13C5B0` smoothness, `0xCF3F97E0` integer
values 2/4 — integer type confirmed here too, never a float).

**Block 7** (532,204 B, dim 256, header nodeCount 85, walked 64 nodes,
44,032-row nibble-RLE decodes with 0 bad rows, stream ends exactly 72 bytes
(= its 16-pair footer) before block end): `pairCount = 16`,
`BackgroundMaterialIndex = 0x00000080` → resolves to L0. Texel share:

```
L0  67.6%  textureless base       L43  0.4%  crater gravel (textured)
L6  30.3%  textureless painted    L12  0.2%, L1 0.1%, L2 0.1%, L3 0.0%
L10  1.3%  asphaltbroken (textured)
```

**So the block-7 base field can colour at most ~1.7% of Dumbo's ground from a
real albedo.** Dumbo's look comes from the painted weight pages (L13/L22) and
above all from the colour map — which is a complete satellite photo here. The
honest-ceiling shape from Tungsten §B4 holds, with an even lower base-field
ceiling and a far higher colour-map payoff.

**Scatter join: not validatable on this map.** The catalogue RES ships
(`mp_dumbo/meshscatteringdatabaseasset.MeshScatteringDatabase`) but the
level's single `SingleTerrainLayerData` partition
(`mp_dumbo_terrain/mp_dumbo_terrain.ebx`) contains **zero**
`MeshScatteringTypes` entries — an urban map with no terrain-scatter
authoring. The Identifier→catalogue join stays UNVALIDATED; use a rural map.

## C. Decals and roads

**MEASURED.** `decals.TerrainDecals` is 5,095,152 B: **recordCount 433, all
433 parse, 0 chain breaks** (the FirstIndex invariant holds). `slotCount = 46`
— **note: NOT equal to the 47-layer count.** Tungsten's "slot table has one
entry per terrain layer" equality (33 = 33) is off by one here (46 vs 47);
per-slot GUIDs: 10 of 46. Asset slots used: 7 (10, 8, 4, 2, 3, 21, 40), 47
distinct texture-set groups. Top groups: `t_euu_covermanhole_01` x23,
`t_euu_drainageroad_01` x21, `t_white_crosswalk` x20, `seu_treeplanter_01`
x16, `t_cas_roaddirt_02` x15, cobblestone/brickroad/asphalt lines — street
furniture, not the CAS road-spline library that dominates Tungsten.

- **135 of 433 records bind NO textures at all** — one third of the map's
  decal records, dwarfing Tungsten's 14 `_op`-only cases. A reader that
  treats "no basecolor" as failure mis-handles a third of Dumbo's decals.
- Slot 10 (153 records) spans y **−792.3**..62.9 — the draped-vertex AABB-Y
  caveat (TERRAIN.md §10.4) at an extreme; never cull decals by Y here.
- Coverage is central only: x −695..926, z −2369..401 of a ±4096 world. The
  whole backdrop ring carries no terrain decal (its road decals were meant to
  come from `ag_motivebackdrops_outputs_road_decals` — shipped EMPTY, below).

## D. The populated EcsRuntimePrefabAsset — what "populated" actually holds

**MEASURED** (`probe_dumbo_ecs.py`). 57 prefabs: **54 are the identical empty
stub** (`ent=1 arch=1 seg=1 edits=0 comps=[26]`) — the boilerplate-per-layer
law holds — and **3 are populated. All three are SPLINE authoring data, not
geometry:**

| prefab | entities | contents |
|---|---|---|
| `lay_backdropbuildingsescsplines` | 85 | 4 `Spline` + 77 `ControlPoint` + 3 **`Manual City Blocks`** + 1 `EcsIntegration_…`; edit props `LocalTransform` (x83), `InTangent/OutTangent/TangentType`, `IsClosed/Tension`, and generator switches **`GenerateCityBlocks`, `GenerateStreets`, `BackdropRoofTop`, `GenerateCollision`, `UseCityBlocksFromLayer`, `Priority`**, shadow flags |
| `lay_art_10_oob_architecture` | 21 | 1 `Spline` + 18 `ControlPoint` + `AG_SplineScatter_Splines/Volumes/Extents` — spline-scatter input for the OOB ring |
| `_layers_gameplay/payload/mp_payload0` | 3 | 1 `Spline` + 1 `ControlPoint` — the payload route |

Segments carry `EcsComponentSegment`s whose `ComponentType` is a runtime type
INDEX (`te0x19[38..86]`), with per-entity `LocalTransform` dynamic edits — the
spline geometry is recoverable from the edits if ever needed. All three
`SourceAsset` partitions are **NOT in the 449,738-partition dump** (same as
Tungsten's stubs — the authoring asset never ships). **Conclusion, stated next
to the empty-stub pattern: even a populated ECS prefab contains no meshes,
transforms-of-props, or materials; it is the authoring INPUT whose build
OUTPUT ships elsewhere.** A plugin placement walk gains nothing from ECS
prefabs on any map studied so far.

**And the output does ship.** The chain, closed end-to-end on Dumbo:

- `generated/ag_motivebackdrops_outputs_city_blocks_dbfa4760.ebx` — **963
  `TerrainFillDecalData`** (the backdrop ground fill; the busiest layer
  partition in the level).
- `generated/ag_motivebackdropsoutputs_generated_blueprints_01a817dc.ebx` —
  one `ObjectBlueprint` (StaticModelEntityData + RigidMeshAsset, 5 materials,
  own MeshSet + PhysicsResource) = the generated backdrop city mesh, and it is
  **imported/placed by `mp_dumbo.ebx` itself**.
- `generated/ag_motivebackdrops_outputs_{blueprints_instances, distant_lights,
  props, road_decals}` — all **empty** LayerData.
- `backdrop/buildings/` — **92 authored MeshSets**
  (`bd_eus_dumbo_brooklyn_NN_mid`, `bd_eus_dumbo_manhattan_NN_mid`): the
  skyline library. **No layer imports them**; the only referencing partition
  in the level is `mp_dumbo/meshvariationdb_win32.ebx`. HYPOTHESIS: the
  generated city mesh / engine instances them through the variation DB rather
  than EBX imports; a placement walk that only follows layer imports will
  never see the skyline.

## E. Everything else notable

- **MEASURED — structure.** 328 LayerData partitions, 190 with zero Objects.
  Busiest: `generated/ag_motivebackdrops_outputs_city_blocks` (963),
  `_layers_world/global_debrispiles` (874), `lay_art_00_gloabl_decals` (419),
  `lay_art_04_shops_decals` (345), `_layers_content/occluders` (234). Nine
  `sub_art_NN_*` subworlds each with their own physics (3.8–18.8 MB),
  meshvariationdb and ShaderBlockDepot (44 depots total; breakthrough/
  conquest/domination/escalation/kingofthehill/payload/rush/sabotage/
  squaddeathmatch share `shaderblockdepot_9526102139013923511` byte-for-byte).
- **MEASURED — naming traps.** Shipped typos `lay_art_0N_gloabl_*` and
  `area_04_lighitng_schematic.ebx`; gameplay dirs include `cables`,
  `freeroam0`, `customportal`, `strikepoint`, `teamdeathmatch`,
  `shared_cq_esc`, `sharedassets_rooftopropes_cq_esc_bt_koth`,
  `sharedassets_rooftopziplines_cq_esc_koth`,
  `sharedassets_smallmodes_tdm_dom_strike`, plus `_layers_autotests`,
  `_layers_tools`, `dbt`, `prefabs` at level root. No BR/granite content
  (that is Tungsten-specific hosting).
- **MEASURED — light/reflection volumes for the open task list.**
  `PbrBoxReflectionVolumeEntityData` in `lay_art_03_rooftop_lighting`,
  `lay_art_04_shops_lighting`, `lay_art_05_archway_lighting`;
  `EnvironmentDecalVolumeData` in nearly every `lay_art_*`
  decals/props/architecture layer. VE presets: `ve_mp_dumbo_suncloudy_04`
  (active-sun candidate, has `OceanComponentData`), `darkalley`,
  `interiorinside`, `interiorinside_constructionsite`, `thermal`.
- **MEASURED — biggest files are lighting:** `enlighten_mp_dumbo_highend`
  105.5 MB / lowend 32.3 MB; `materialgrid_win32.ebx` 16.3 MB.

## F. What generalises — law-by-law verdict on the baseline map

| law (MAP-TUNGSTEN.md / TERRAIN.md) | Dumbo verdict |
|---|---|
| Page size table: dumbo = 2592 | **HOLDS** — byte-exact on 485/485 chunks; 4356/5184 impossible (negative residuals) |
| Trailer = k x tile; dumbo tile 4624 = 68² | **HOLDS**, k = 1 primaries, k = 4 paired — **and k = 0 exists** (5 root chunks, no tile) |
| Height prefixes ∈ {0, 39919, 149297, 189216} | **HOLDS as a subset** — only {0, 149297} occur here |
| BC7 mode test (colour ≈ 100% modes 4-7) | **HOLDS**: 100.00% first AND last; root-chunk tails are m0 (pages, not tiles) |
| Colour tile FIRST in trailer | Trivially holds (k=1); paired = 4 real colour tiles, reversed order verified by seamless render |
| Colour map modulates at 0.5-neutral | **HOLDS**: true mean (0.500, 0.500, 0.500); alpha ≈ 0.02 |
| Materials on the base side | **HOLDS as a tendency**: 8 of 10 albedo layers base; L13/L22 are painted WITH albedo — not absolute here |
| `0xAE16A5C0` = crater slot, one layer per map | **HOLDS**: L41 `hfd_debug`, L42-45 link to it |
| `0xCF3F97E0` integer (0/2/4), not float | **HOLDS** (values 2 and 4 observed) |
| Water +0x90 QueryBoxHalfExtent, TileOffset (0,0,0), size 0x280 | **HOLDS** |
| Water renders iff y above floor | **HOLDS**: 49.80 > 24.75, and it renders |
| Empty ECS stub is per-layer boilerplate | **HOLDS**: 54 stubs beside 3 populated ones and beside full layers |
| SourceAsset partitions never ship | **HOLDS**: all 3 populated prefabs' sources absent from the dump |
| Terrain dir name inconsistent | **HOLDS**: `mp_dumbo_terrain` (suffix) |
| Layer-graph table by 100%-key-resolve only | **HOLDS**: decoy table at 148, true at 216 (again +68) |
| Decal slotCount == layerCount | **BREAKS (off by one)**: 46 slots vs 47 layers |
| Decal chain invariant, 4-slot texture hashes | **HOLDS**: 433/433, 0 breaks; but 135 records bind NO textures |

## G. Next actions for the plugin, in priority order

1. **Keep k = 0 legal and never read the chunk tail as colour** —
   `addons/highpoly_toggle/bf6_splat.gd` (`_tiles_in`, `color_tiles`). The
   baseline map itself has 5 no-tile chunks whose tails are BC4 page bytes;
   regression test: Dumbo must yield exactly 272 primary + 832 paired tiles.
2. **Add Dumbo's row to the detect_layout verification set** — page 2592,
   tile 4624, residuals {0, 4624, 153921}, prefixes {0, 149297}
   (`bf6_splat.gd`; `tools/probe_dumbo_detectsim.py` is the oracle).
3. **Turn the colour map on** — `addons/highpoly_toggle/highpoly_mapcontext.gd`
   (`colormap_enabled`). Dumbo is the strongest argument in the fleet: the
   colour map is a complete seamless aerial photo of NYC while the base field
   offers 1.7% albedo coverage. `FIXED_MP_Dumbo.png` is the ground truth to
   compare the in-engine composite against.
4. **Make the placement walk find the skyline** —
   `addons/highpoly_toggle/highpoly_gamesource.gd`. The generated backdrop
   blueprint is placed by `mp_dumbo.ebx` (verify it is not filtered out); the
   92 `bd_eus_dumbo_*` MeshSets are reachable only via
   `meshvariationdb_win32.ebx`, so an import-following walk misses the entire
   Brooklyn/Manhattan backdrop.
5. **Do not assume the water plane is world-sized** —
   `highpoly_gamesource.gd::water()`: build it from the transform basis
   (4,096 m) and translation (0, 49.8, −285.2), not from the terrain bounds
   (8,192 m); Dumbo over-draws 4x otherwise.
6. **Skip ECS prefabs in any future geometry source** — even populated ones
   are spline authoring inputs (document in `docs/GROUND-LAYERS.md` beside the
   empty-stub correction); their outputs ship as ordinary layers.
7. **Decal reader: tolerate texture-less records** — 135 of Dumbo's 433 bind
   nothing; and do not index decal slots by layer count (46 ≠ 47 here)
   (whichever file takes over `TerrainDecals` consumption).
