# MP_Aftermath (and MP_Aftermath_Portal), end to end

One map — and, uniquely in this fleet, its Portal twin — read from the shipped
2026-08-01 pull until every question has a number behind it or the word
"unknown". Written against `MAP-TUNGSTEN.md` as the model; laws established
there are VERIFIED here with one probe run each, not re-derived.

**Every claim is tagged MEASURED or HYPOTHESIS.** Probes live in
`tools/probe_aftermath_*.py`; the parametric Tungsten probes were reused
unchanged with `mp_aftermath` as the level argument:

```
reused:  probe_tung_terrain.py mp_aftermath      blocks, splat, block-7 footer
         probe_tung_layers.py  mp_aftermath      layer -> depot -> textures
         probe_tung_water.py   mp_aftermath      the water partition, in full
         probe_tung_ecs.py     mp_aftermath      ECS prefab census
         probe_tung_decals.py  mp_aftermath      TerrainDecals records
         probe_tung_structure.py mp_aftermath    layers, subworlds, depots
         probe_tung_basefield.py mp_aftermath    block-7 raster texel shares
         probe_tung_guidscan.py                  (cached full-dump GUID scan)
new:     probe_aftermath_decomp.py       THE decomposition table + BC7 mode test
         probe_aftermath_colorrender.py  BC7-decoded colour map -> PNG
         probe_aftermath_ecs.py          deep decode of the populated ECS prefab
         probe_aftermath_portal.py       MP vs Portal-variant full diff
```

---

## 0. The map in one paragraph

**MEASURED.** MP_Aftermath is an **8,192 x 8,192 m** world (block-0 root AABB
`x,z ∈ [-4096, 4096]`), ground from **y = 0.105 to y = 110.674**, height scale
`WorldSizeY = 256.0`, xs = 265, 121 streaming-directory nodes (85 heightfield
nodes: 5 Packed + 80 External). It is Lower Manhattan / Brooklyn: the assembled
terrain colour map is a seamless aerial photo of the East River bridges,
Governors Island and the surrounding street grids. Its terrain palette is **40
layers** (block 1 uses indices 0–38; L39 is declared and never referenced), it
carries 255 terrain-decal records confined to the ~880 m playable core, one
`WaterSurfaceEntityData` at y = 49.7 (49.6 m ABOVE the terrain floor — this is
a map whose water renders), 396 `LayerData` partitions (216 with zero Objects),
50 `EcsRuntimePrefabAsset` partitions of which **one is populated** — the
backdrop-buildings spline prefab — and a `backdrop/buildings` directory with
**80 dedicated backdrop MeshSets**. A full Portal twin of the level ships under
`game/glacierportal/levels/mp_aftermath_portal` (§E).

---

## 1. THE DECOMPOSITION TABLE (detect_layout verification row)

**MEASURED** (`probe_aftermath_decomp.py`): all 121 primary + 75 paired chunk
files exist on disk, every declared size matches the file, and every chunk
decomposes **exactly, zero residual** as

```
size = heightPrefix + pages x 2592 + k x 17424
```

- **Page size 2592 confirmed** (brief's derived table row for this map).
- **Height prefix**: 0 or exactly one 149,297 (the xs=265 inline heightfield
  payload; 71 chunks carry it — never two, unlike Tungsten's 2x).
- **Trailer**: primary chunks carry **k = 1 tile of 17,424 B = one 132^2 BC7
  tile** — confirming the task brief — except **5 chunks (the root + the four
  depth-1 nodes, exactly the 5 Packed-height nodes) which carry NO tile and no
  height payload**: 85,536 = 33 pages (x2), 31,104 = 12 pages (x2),
  139,968 = 54 pages (x1), pages only.
- **Paired chunks**: pages + **k = 4 x 17,424** (41 of them are exactly
  4 x 17,424 with zero pages).

Distinct primary sizes (top of the table; full output in the probe):

| size | count | decomposition |
|---|---|---|
| 197,825 | 49 | 149,297 + 12 x 2592 + 1 x 17,424 |
| 48,528 | 22 | 0 + 12 x 2592 + 1 x 17,424 |
| 17,424 | 12 | 0 + 0 pages + 1 x 17,424 |
| 85,536 | 2 | 0 + 33 x 2592 + **no tile** |
| 252,257…405,185 | 1–2 each | 149,297 + 14…92 x 2592 + 1 x 17,424 |

**BC7 mode histogram** over all 121 primary chunks: LAST 17,424 B = **95.87%
modes 4–7** (mode 6 dominant, 116,879 of 131k blocks; the shortfall is
entirely the 5 tile-less chunks — pure-tile chunks measure ~100%); the 17,424 B
**before** the tile = **0.20%** modes 4–7 (mode 0/1 dominated — weight-page
bytes, not a second tile). Paired chunks: each of the last four 17,424-B
windows is **100.0%** modes 4–7 and the window before them 0.0–0.1% — four
child tiles at the chunk END, verifying the paired-tile law on this map.

So on MP_Aftermath there is **no degenerate second raster** — one colour tile
per primary node, always last. `detect_layout`'s current pick of
`(2592, 4624)` gets the page size RIGHT here but the tile size WRONG: its
`color_tiles()` slice takes the last 4,624 B, i.e. the bottom ~35 rows of the
real 132^2 tile, and decodes a fragment as a whole tile.

## 2. The rendered colour map

**MEASURED** (`probe_aftermath_colorrender.py`, BC7-decoded via
`bf6_colormap.decode_tile`, coarse-first blit of 116 tiles):
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Aftermath.png`.
**It reads as one coherent, seamless aerial photograph of Lower Manhattan and
Brooklyn** — bridges, piers, Governors Island, Navy Yard drydocks, street
grids, Central-Park-corner at the edge — with no seams, no channel swap.
Assembled mean RGB **(0.478, 0.498, 0.454)** against the SDK overhead
`MP_Aftermath.jpg` mean (0.563, 0.513, 0.456); the SDK image includes rooftops
and roads the colour map does not, so agreement in the ~0.05 band with no
channel inversion is the expected signature of a correct decode. On this map
the colour map is effectively **satellite imagery** (as `bf6_colormap.py`
records for dumbo) and is by far the largest source of ground colour (§B4).

---

## A. Water

**MEASURED** (`probe_tung_water.py mp_aftermath`). The brief's claim holds:
the level's `WaterSurfaceEntityData` lives in **`_layers_content/water.ebx`**
(1,570 B, 4 instances: LayerData, WaterSurfaceEntityData,
WaterInteractHealthComponentData, FBPhysicsComponentData), not in
`<level>/default`:

```
Transform  right (10000, ~0, ~0)  forward (~0, ~0, 10000)
           trans (-35.746, 49.700, 1.634)        <- water height y = 49.70
QueryBoxHalfExtent (5000.0, 0.5, 4999.9995)      <- +0x90, NOT TileOffset
TileOffset         (0.0, 0.0, 0.0)               <- +0xB0, zero as everywhere
MaterialPair.Packed 283128969
```

- **Water y vs terrain floor: 49.700 vs 0.105 — 49.6 m ABOVE the floor.**
  Verifies MAP-TUNGSTEN §A3's table row and the sign of the law: this is one
  of the maps where the water toggle CAN and does render (the East River is
  most of the map's area).
- The `QueryBoxHalfExtent`-not-`TileOffset` correction verifies exactly
  (values above, read by field hash).
- `_layers_content/water_shared_schematic.ebx` carries the
  `WaterOceanSimulationEntityData` (Resolution 32, TileDimension 8.0,
  WindSpeed 0.5, EnableFoam false).

**MEASURED — a new wrinkle: the entity's `Visible` field is `false`** on
MP_Aftermath (and on its Portal twin), while buried-underground Tungsten's is
`true`. The East River visibly renders in game and in our plugin, so
**`Visible` on `WaterSurfaceEntityData` does not gate water rendering** — do
not "fix" the plugin by honouring it. HYPOTHESIS: it is an editor-side or
per-part visibility flag overridden by the water system at runtime.

## B. Terrain and ground layers

### B1. Blocks

**MEASURED** (`probe_tung_terrain.py mp_aftermath`): blocks **0, 1, 4, 7, 8**
— no block 2 (density) and no block 5, confirming MAP-TUNGSTEN §E's
"dumbo/aftermath ship no blocks 2/5". Block 1: `LayerSlotCount = 62` (the
dumbo/aftermath/eastwood value; still not the layer count), 245 nodes, 17,649
records, slack 0. Block 7: 100,471 B, dim 256, levelMax 5, node stream ends 64
B (its footer) before block end. Block 8: 208,886 B, dim 265, maskUnknown0=4.
All typed blocks walk byte-exactly.

### B2. The palette: 40 layers, 15 bind a texture — and 3 of those are PAINTED

**MEASURED** (`probe_tung_layers.py mp_aftermath`): layer-graph record table at
**offset 188** by the all-keys-resolve rule (40/40 in the paired depot; 40
keys over 32 content-deduplicated records, 57 texture params, 263 constants).
**The wrong-but-plausible table exists at offset 120 — exactly 68 bytes
earlier, resolving 0/40 — the same trap at the same distance as Tungsten.**
`probe_tung_terrain.py`'s distinct-keys heuristic picks 120 and prints garbage
A/B/C fields; only the resolve rule is safe.

Splat split: **25 painted / 14 base** layers. Base list (in all 980
base-carrying node-records): L00 02 03 06 08 15 25 32 33 34 35 36 37 38.
Three painted layers (L04, L09, L23) also appear in ALL 980 records — a
map-global painted trio. L39 appears in no record at all.

| L | side | textures bound |
|---|---|---|
| 00 | BASE | none (6 constants; tiling 0.02) — **the background layer** |
| 02 | BASE | `t_euu_cobblestone_01` cv/ao/nhs + default AO |
| 03 | BASE | defaults + `t_wuu_sandnoise_02` |
| **04** | **painted** | `t_gen_breakupmask_02_rgba` + `t_com_asphaltdetail_02_ncs` |
| 06 | BASE | `t_euu_concretetile_01` cv/ao/nhs |
| 08 | BASE | `t_naf_asphaltbrokendecal_01` cv/ao/nhs |
| 15 | BASE | `t_cas_asphaltedge_01` cv/nhs/ao/op (the road-edge set) |
| **16** | **painted** | `t_wuu_grass_fairway_01` cv/ao/nhs — real albedo |
| **19** | **painted** | `t_wum_m_sand_02` cv/ao/nhs — real albedo |
| 25 | BASE | default AO only |
| 32 | BASE | default cv/ao/nhs (placeholders) |
| 33 | BASE | default AO + breakupmask |
| 34 | BASE | `hfd_debug` at slot **0xAE16A5C0** — **the crater layer** |
| 35 | BASE | `t_wum_asphaltedge_01` + `t_wum_crackedconcrete_03` (links L34) |
| 36 | BASE | `t_wum_ls_gravel_01_a` + `t_wum_td_sand_01_ncs` (links L34) |
| 37 | BASE | `t_wum_dryrockygravel` + `t_wum_td_sand_01_ncs` (links L34) |
| 38 | BASE | `t_wum_ls_gravel_02_b` + `t_wum_m_burntdebris_01` (links L34) |
| others | painted | none — shader-computed |

- **CONTRADICTION of the absolute form of the base-side law.** On Tungsten the
  painted/textured split was total; on MP_Aftermath **painted L16 and L19 bind
  full cv/ao/nhs albedo sets** (golf-course fairway grass and sand — the park
  and the boardwalk sand) and painted L04 binds detail/mask textures. The law
  survives as a strong tendency (12 of 15 textured layers are base), **but a
  reader that skips textures on painted layers loses real albedo here**.
  `bf6_materialtree.gd`-style handling must bind textures on BOTH sides.
- **Crater law verified with different indices**: L34 is the only layer binding
  `0xAE16A5C0` (`hfd_debug`), and L35–L38 link to it (VisualTerrain link
  entries 35→34 … 38→34) — Tungsten's L28/L29-32, dumbo's L41/L42-45.
- **VisualTerrain oddity**: layerCount 40, flags {0: x39, 1: x1} — **the one
  flag=1 layer is L39, the never-referenced index**, whose depot record is the
  empty-constants class. HYPOTHESIS: flag 1 marks a reserved/disabled slot.
  Also: `SurfaceShaderBlockKey 0x43DB1AAE19A710A9` — **byte-identical on the
  Portal twin**, even though 30 of the 40 per-layer keys differ there (§E).
- Constants verify Tungsten's typings: `0xCF3F97E0` int values 2/4 here (never
  a float), `0x4C200FE0` in −0.02..0, `0xCBB9A946` (0,0) on all layers,
  `0x2F9990B7` 10..100, `0xF7652FB3` 2..16, tiling `0x5707A992` 0.01..0.1.

### B3. Block 7 is almost all background on this map

**MEASURED** (`probe_tung_basefield.py mp_aftermath`): pairCount 14 (12 used),
`BackgroundMaterialIndex = 0x06710080` → list 1 low-nibble 0 → **L00**, a
textureless layer. Texel shares of the resolved base field:

```
L00  95.3%   textureless background
L08   3.9%   naf_asphaltbrokendecal   (the street asphalt)
L02   0.5%   euu_cobblestone
L36   0.2%   wum_ls_gravel            (crater material — pair X=0x31 again,
L01/L03/L10/L06/L07  <=0.1%            reproducing TERRAIN.md §8's cross-map note)
```

So block 7 contributes ~4.6% textured ground; the painted weight pages add the
grass/sand/asphalt-detail layers over the core; **everything else is L00 +
the colour map**. On this map the colour map is not a modifier, it is the
picture — the strongest possible argument for finishing the colour-map path in
the plugin.

## C. Decals and roads

**MEASURED** (`probe_tung_decals.py mp_aftermath`): `decals.TerrainDecals`
2,505,688 B; slotCount **39** (30 empty, 9 with a GUID — note: 39 ≠ the
40-layer count; it equals the highest USED layer index + 1, a small correction
to "slot table has one entry per terrain layer"), recordCount **255**, all 255
parse with 0 chain breaks, 8 asset slots used, **40 texture-set groups**.

- Content is street furniture, not roads-as-mud: asphalt lane lines (23 full +
  16 dotted), crosswalks, yellow road lines, manhole covers (5 variants x5),
  sidewalk vents, tree/soil planters, cobblestone_02, blindpath tactile
  paving, drainage grates. One group of 5 binds only the
  `t_cas_roadvariationmask_01_rgb` `_op` mask (the no-basecolor class
  MAP-TUNGSTEN flags); **one 66-record group binds no textures at all**.
- **Coverage is tightly bounded**: every record AABB sits inside
  x ∈ [−718, −350], z ∈ [−307, 502], y ∈ [51.7, 71.2] — the ~880 m playable
  core (matching `highpoly_mapcontext.gd`'s MP_Aftermath_Portal combat box at
  pos (−577, 62, −30), size 878). The other 98% of the 8 km world carries no
  terrain decal — same shape as Tungsten's decal-less southern third.
- Two groups mix libraries (cobblestone_02 without `_op`; westusmountain road
  lines with eastusurban manholes in adjacent groups): group by whole texture
  set, as established.

## D. Everything else notable

### D1. The populated EcsRuntimePrefabAsset — what a REAL one carries

**MEASURED** (`probe_tung_ecs.py` + `probe_aftermath_ecs.py`). Census: 50
prefabs, **49 identical empty stubs** (`ent=1 arch=1 seg=1 edits=0
comps=[26]`) and **one populated**:
`lay_backdropbuildingsescsplines_ecsprefab_ecsprefab.ebx` (44,948 B). This is
the fleet's reference example for telling stubs from real prefabs:

```
118 instances:
  1   EcsRuntimePrefabAsset    ent=110 arch=3 seg=7
  110 payload entity records   (type be62bf1f-...; fields: PartitionGuid,
                                Name, guid)  names: 107 x "ControlPoint",
                                2 x "Spline",
                                1 x "EcsIntegration_LAY_BackDropBuildingsESCSplines"
  7   EcsComponentSegment      ComponentType = TypeInfoRef ("te0x19", N)
                               N in {46, 50, 54, 58, 62, 66, 70}
archetypes: [50], [70,0,66,0,62], [70,0,62,0]
edits (all DynamicEdits, 113 total):
  seg type 46:  1 edit   keys "IsClosed", "Tension"          <- the spline
  seg type 54:  2 edits  keys "InTangent", "OutTangent"      <- spline CPs
  seg type 62:  109 edits, each ONE key "LocalTransform"     <- per-point pose
  seg type 66:  1 edit   "DistanceShadowCacheEnable", "LocalShadowDisable"
```

So a REAL prefab has: named per-entity payload instances, more than one
archetype, ComponentType TypeInfoRefs other than index 26, and
`EcsDemiComponentEdit` lists keyed by property-name hashes ("LocalTransform"
KeyHash 730586598). A stub has none of these. Structure, not size, is the
discriminator (the stub is ~1.2 KB, but nothing prevents a small real one).

- **The edit VALUES could not be read**: each `EcsValuePair`'s value struct
  (type `6bdc1f5b-2557-d19f-b0aa-8772757aed3d`, value TypeInfoRef `te0x1a`)
  decodes to an empty struct with our deserializer. Where the actual
  float/vec payload lives is **unknown** — the one open question this prefab
  leaves. Until it is answered, the 107 control-point transforms are not
  extractable, so the backdrop splines cannot be rebuilt from the prefab.
- **MEASURED**: even this populated prefab's `SourceAsset.Partition`
  (`7ae87887-4736-f011-…`, a v1 UUID) is **absent from the 449,738-partition
  dump** — extending Tungsten's finding: SourceAsset names the unshipped
  authoring asset for populated and stub prefabs alike.

### D2. Backdrop meshes exist, and they are per-map assets (open task: skyline)

**MEASURED.** `levels/mp_aftermath/backdrop/buildings/` holds **80 MeshSets**
(240 files: `.ebx` + `_mesh.ebx` + `_mesh.MeshSet`) named
`bd_eus_aftermath_brooklyn_NN_mid`, `…manhattan…`, etc. This answers the
"which backdrop meshes exist" question for this map: the skyline is a
dedicated `bd_*` mesh library inside the level directory, semantically tied to
the backdrop-spline ECS prefab of §D1 (name: BackDropBuildingsESCSplines) and
to `generated/ag_motivebackdropsprefabasset_*`. `_layers_world/
global_backdrop.ebx` itself is an EMPTY layer — the backdrop is not placed via
LayerData Objects. HYPOTHESIS: the ECS spline prefab + the `bd_*` mesh library
are the placement mechanism (control points along the shoreline/horizon);
proving it requires the edit values above.

### D3. Structure

**MEASURED** (`probe_tung_structure.py mp_aftermath`): 396 LayerData
partitions, **216 with zero Objects**. Subworlds are `sub_art_*` (00_global,
01_plaza, 03_park, 04/05_panorama, 06_alleys, 07_firestation, 08_commercial,
10_boardwalk, 11_natohq, 12_paxhq) — a different naming convention from
Tungsten's `area_00N`, plus **two event subworlds `default_event` and
`winter_event`** (a seasonal-variant axis Tungsten does not have; anything
walking "the level" will pick up winter props/VFX/lighting layers unless it
filters). The single busiest layer is
`_layers_world/generated/ag_aftermathscatter_aftermathentities_1c9ee2d1.ebx`
with **2,285 Objects** — on this map the generated `ag_*` layers are NOT all
empty (contrast Tungsten). ~2,285 `aftermathasset<guid>.ebx` partitions under
`_layers_world` carry the scatter pieces, with the GUID embedded in the
FILENAME (per-level unique names — a name-keyed cross-level diff is useless).
Biggest files: Enlighten 59.6/37.8 MB, materialgrid 16.5 MB,
`portal_gameplay_win32_shaderstate` depot 14.5 MB (38 depots under the level).
Gauntlet (BR-adjacent `aftermathgauntlet*`, duo/trio partitions named
`snowybrookly_*`) lives inside the level like Granite does in Tungsten.

### D4. Scatter join — cannot be validated here

**MEASURED**: all 42 `SingleTerrainLayerData` instances in
`mp_aftermath_terrain.ebx` have `MeshScatteringTypes = []` (and no other
fields), while a 20,221 B `MeshScatteringDatabase` still ships (byte-identical
on the Portal twin). So the brief's Identifier-join validation is **not
possible on this map**: Aftermath does its clutter through the baked
`ag_aftermathscatter` layer (2,285 real placements) instead of terrain-layer
scatter. That is itself useful: a map can have a scatter CATALOGUE and zero
scatter USERS.

---

## E. MP_Aftermath_Portal — the variant, and why its GUID index was missing

All measurements from `probe_aftermath_portal.py` unless noted.

### E1. Where it lives (the answer to task #30)

**MEASURED.** The Portal variant is a complete, self-contained level at
**`game/glacierportal/levels/mp_aftermath_portal`** — the **glacierportal**
studio directory, not `glaciermp` (install TOC:
`Update/BF6_MARKER_DLC/Data/Win32/game/glacierportal/levels/mp_aftermath_portal/mp_aftermath_portal.toc`).
3,033 files / 2,916 EBX partitions / 617 MB, with its own terrain directory
`mp_aftermath_portal_terrain` (own TerrainStreamingTree, VisualTerrain,
LayerGraphs, TerrainDecals, ShaderBlockDepots).

**Nothing about the variant's data is malformed.** The missing per-map GUID
index is a pure tooling-history artifact, already half-documented in
`bf6-highpoly-pipeline/tools/run_map.py::guid_index`: the per-map
`guid_index_<abbrev>.tsv` files were built in the per-map-extraction era, and
MP_Aftermath_Portal (like MP_Isolated) was never extracted then, so no
`guid_index_afp.tsv` was ever written. Three additional facts close the item:

1. **The merged-pull `guid_index_all.tsv` already covers it completely**:
   2,916 rows under `game\glacierportal\levels\mp_aftermath_portal` — exactly
   the partition count on disk. The documented fallback works.
2. **A working `guid_index_afp.tsv` already exists elsewhere**:
   `bf6-fx-viewer/tools/.cache/guid_index_afp.tsv` (126,659 rows, per-map
   extraction scope). Copying/rebuilding into `bf6-highpoly-pipeline/data/`
   is mechanical.
3. **`maps.json`'s afp row is stale on two counts**: its `tree` points at the
   dead per-map root `A:\bf6dump\...` AND at **MP_Aftermath's glaciermp
   terrain** — written when the variant's own terrain was assumed shared. The
   variant has its own terrain (below), and the merged pull carries it.

Anything that assumes `game/glaciermp/levels/<level>` (the probes' own
`C.LEVELS`, index builders keyed on studio, `terr_dir()` etc.) finds nothing
for this map. That is the entire failure mode.

### E2. Terrain: identical data, re-keyed identity

**MEASURED**, and this is the part worth generalising to the other Portal
variants:

- The streaming tree is the same 909,905 bytes and **all five typed blocks
  (0/1/4/7/8) are byte-identical** to MP_Aftermath's. The FIRST differing byte
  is at 905,626 — inside the chunk directory, which starts at 905,622.
- The chunk directory names **196 chunk GUIDs, 0 shared with MP_Aftermath's
  196** — yet all 196 files exist, and **all 121 primary chunks are
  byte-identical** to their MP counterparts, node for node. The install ships
  a full duplicate of Aftermath's terrain chunk data under fresh GUIDs.
- `VisualTerrain` differs ONLY by the three embedded shader paths
  (glaciermp/mp_aftermath → glacierportal/mp_aftermath_portal; 676 → 751 B);
  `SurfaceShaderBlockKey` is **identical** (0x43DB1AAE19A710A9).
- LayerGraphs `.DE540C59`: same size, record table at the same offset 188
  (40/40 resolve in the variant's OWN depot; the offset-120 false table
  resolves 0/40 there too), but **only 10 of 40 ShaderBlockKeys match
  MP_Aftermath's** — per-layer keys are per-level. **A reader must join the
  variant's layer graph to the variant's depot; assuming Aftermath's keys
  fails for 30 of 40 layers.**
- `decals.TerrainDecals`: same size, bytes differ (unexamined; HYPOTHESIS:
  embedded per-level keys/GUIDs, as with the layer graph).
  `MeshScatteringDatabase`: **byte-identical**.
- Water: identical values (y 49.70, half-extent 5000, `Visible false`), in the
  same `_layers_content/water.ebx` location. ECS prefab census identical
  (49 stubs + the same one populated backdrop-splines prefab, 44,960 B).

### E3. Content differences beyond renaming

**MEASURED** (name-normalised diff `mp_aftermath_portal`→`@LVL@`):
3,892 vs 3,033 files; of 711 shared-by-name, 45 byte-identical and 666 differ
(the biggest: the variant's Enlighten databases are **4x larger** —
232.9 MB vs 59.6 MB highend — i.e. the Portal twin was re-baked at a different
GI quality, the single largest data difference between the two levels).

Portal-ONLY (beyond re-hashed shader depots):
- **`sub_art_portal_imports`** — an extra subworld (1.7 MB SubWorldData +
  StaticModelGroup with physics, door-damage-trigger physics and its own
  meshvariationdb; **1,404 imports**) plus its `lay_art_portal_imports.ebx`
  layer. HYPOTHESIS: the pre-mounted mesh set that makes Portal-editor object
  placement resolvable on this map.
- `ui/minimap/mp_aftermath_portal_buildings.ebx`, `…_terrain.ebx`, and —
  an oddity worth recording — **`ui/minimap/operationmetro.ebx`**.
- Its `generated/` directory carries the full `lay_*` layer set that
  MP_Aftermath keeps at the level root (layout differs, content parallel).

MP-ONLY: `backdrop/buildings` (**the 80 bd_* MeshSets — the Portal variant has
no backdrop mesh directory of its own**; how it gets a skyline is unknown —
HYPOTHESIS: cross-level reference into the MP level's bundles, or its 4x
Enlighten bake includes them), `prefabs/` (137 `pf_mp_aftermath_*` building
destruction/facade/interior prefabs), `cables/`, most `_layers_gameplay`
mode layers (conquest/rush/breakthrough sets; MP also has
`customportal_importsublevel.ebx` — MP hosts custom-portal by IMPORTING a
sublevel, while the variant IS the level), and the gauntlet duo/trio layers.

---

## F. Generalisation — what holds, what breaks

| finding | scope | note |
|---|---|---|
| Page 2592 / trailer 1 x 17,424 (132^2 BC7), colour tile LAST, exact zero-residual decomposition | verifies brief's table row | detect_layout must emit (2592, 17424, k=1) here; its current 4,624 tile slice reads the bottom rows of the real tile |
| Paired chunks end with 4 child tiles, each ~100% BC7 modes 4–7 | verified here | |
| Root + depth-1 chunks (the Packed-height nodes) have NO colour tile | **new** — at least aftermath | renderers must skip tile-less nodes (mode test or size decomposition), not assume every node has one |
| **Painted layers CAN bind real albedo (L16 grass, L19 sand, L04 detail)** | **CONTRADICTS the absolute form of the base-side law** | the law is a tendency (12/15 textured are base), not a rule; readers must bind textures on both sides |
| Crater slot 0xAE16A5C0 = one layer per map (L34), linked by L35–38 | verified, third map | |
| Layer-graph table located ONLY by all-keys-resolve; false table exactly 68 B earlier | verified — same 68 B offset on aftermath AND its portal twin | the 68-byte offset now looks structural, not coincidental |
| Water in `_layers_content/water`; y 49.70 vs floor 0.105; QueryBoxHalfExtent at +0x90; TileOffset zero | verifies brief + Tungsten A4 | |
| `WaterSurfaceEntityData.Visible = false` on a map whose water RENDERS | **new** | never gate water on this field |
| Empty ECS stub is boilerplate; populated one has named entities + typed segments + keyed edits | verified + reference example | discriminate by structure; edit VALUES still undecodable |
| SourceAsset partition unshipped even for populated prefabs | extends Tungsten | |
| Portal variant = separate glacierportal level; typed terrain blocks byte-identical, chunk GUIDs 100% re-minted, chunk BYTES identical; per-layer shader keys 75% re-minted | **new — likely template for the 7 Granite portal levels** | index/pipeline coverage is a path problem, not a data problem |
| Decal slotCount = highest used layer index + 1 (39), not layerCount (40) | small correction | |
| A map can ship a MeshScatteringDatabase with zero MeshScatteringTypes users | new | scatter-join validation must pick a different map (tungsten/dumbo) |
| Event subworlds (default_event / winter_event) inside the level | new naming axis | placement walks should filter or pick one event variant |

## G. Next actions for the plugin, in priority order

1. **detect_layout fix verification row** (`addons/highpoly_toggle/bf6_splat.gd`):
   mp_aftermath must detect page **2592**, tile **17424**, one tile, prefix
   {0, 149297}, five tile-less nodes. The BC7-mode discriminator (98%+ vs
   <1% modes 4–7) separates tile from pages perfectly on this map and costs
   one pass over 16-byte block headers.
2. **Skip tile-less nodes in `color_tiles()`** (`bf6_splat.gd`): the 5
   coarsest nodes have no trailer; slicing `size - tile_bytes` there returns
   weight-page bytes. Gate on the mode test or on exact decomposition.
3. **Turn the colour map on for this map first**
   (`highpoly_mapcontext.gd::colormap_enabled`): 95.3% of block-7 texels are
   the textureless L00 background — the colour map IS MP_Aftermath's ground.
   The FIXED_MP_Aftermath.png render is the reference output.
4. **Bind textures on painted layers too** (`bf6_terrainlayers.gd` /
   `bf6_materialtree.gd` path): L16 (park grass) and L19 (boardwalk sand)
   are painted layers with full albedo sets and are lost if textures are only
   resolved for base layers.
5. **MP_Aftermath_Portal support = path generalisation, not new decoding**
   (`highpoly_gamesource.gd` and any `game/glaciermp/levels` assumption):
   accept `game/<studio>/levels/<level>` with studio ∈ {glaciermp,
   glacierportal, glaciergranite}; read the variant's OWN terrain dir and
   depot (30/40 shader keys differ). For the pipeline: build
   `guid_index_afp.tsv` from the merged pull (or copy the fx-viewer cache) and
   fix the stale `maps.json` afp `tree` path.
6. **Backdrop/skyline follow-up** (open task): the 80 `bd_eus_aftermath_*`
   MeshSets in `levels/mp_aftermath/backdrop/buildings` are the skyline
   assets; the blocker for placing them is decoding `EcsValuePair` values
   (the 107 control-point `LocalTransform`s) in the populated prefab —
   worth a focused RE session on type `6bdc1f5b-2557-d19f-b0aa-8772757aed3d`.
7. **Do not read `Visible` on WaterSurfaceEntityData** — note it in
   `highpoly_gamesource.gd::water()`'s comment block: false on a map whose
   water demonstrably renders.
