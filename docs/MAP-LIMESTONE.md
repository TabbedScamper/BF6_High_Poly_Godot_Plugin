# MP_Limestone, end to end

Deep-study of MP_Limestone for the high-poly plugin, following the
MAP-TUNGSTEN.md model: the established laws are VERIFIED here (one probe run
each, cited), and everything new is tagged **MEASURED** (with the number and the
resource it came from) or **HYPOTHESIS**. Probes: `tools/probe_limestone_*.py`
(new) plus the reusable `tools/probe_tung_*.py` run with `mp_limestone` as the
level argument. All reads go through `BF6_Frostbite_Research/impl/pipeline/
bf6_paths.py` and are read-only against the 2026-08-01 pull.

```
tools/probe_limestone_decomp.py       chunk decomposition + BC7 mode histograms
tools/probe_limestone_colorrender.py  decode the 260x260 BC7 tiles -> PNG
tools/probe_limestone_constants.py    the six unidentified layer constants
```

## 0. The map in one paragraph

**MEASURED.** MP_Limestone is a 4,096 x 4,096 m world (block 0 root AABB
x,z ∈ [-2048, 2048]) — it is Gibraltar: the assembled colour map is an aerial
photo of the Rock, the harbour moles and the runway across the isthmus. Ground
runs **y = 0.112 to 435.091**, `WorldSizeY = 458.0` (u16 step 0.70 cm), 265
samples per height node, **77 streaming nodes** (a small tree — Tungsten has
269). Terrain palette **40 layers**; splat `LayerSlotCount = 6`;
**667 partitions** under the level (Tungsten: 1,405); 168 `LayerData`
partitions of which 71 declare zero Objects; **31 EcsRuntimePrefabAsset
partitions, all the empty `ent=1 arch=1 seg=1 edits=0 comps=[26]` stub**
(`probe_tung_ecs.py mp_limestone` — verifies the ECS-boilerplate law); 16
ShaderBlockDepots; 371 terrain-decal records. The terrain directory is named
**`mp_limestone_terrain4k`** — a THIRD naming convention after
`terrain_mp_tungsten` and `mp_dumbo_terrain`, with a "4k" suffix no other
studied map has; only a "contains `terrain`, holds a `.TerrainStreamingTree`"
search finds it.

---

## 1. THE DECOMPOSITION TABLE (detect_layout verification row)

**MEASURED** (`probe_limestone_decomp.py`). Page size **4,356** (raw 66x66),
agreeing with both the exact-decomposition method and
`impl/pipeline/bf6_splat.py`'s per-map table. Per-node stored-page count `m`
read directly from block 1's node headers. All 77 primary directory entries
account for:

| count | decomposition of `size0` | note |
|---|---|---|
| 72 | `149297 + m x 4356 + 67600` | one height LOD (xs=265) + pages + trailer |
| 4 | `0 + m x 4356 + 0` | the Packed height nodes (root 0x3 + children 0x31/0x32/0x33): pages only, **no trailer** |
| 1 | directory entry with GUID = 0, size0 = 0 | child 0x30, a Packed node with **no chunk at all** |

Zero residual on all 76 real chunks; no other prefix from
{0, 39919, 149297, 189216} is needed.

- **Trailer = 67,600 bytes = one 260 x 260 BC7 tile** (256 + 2 px apron per
  edge), exactly the size `bf6_colormap.py` predicts for
  battery/firestorm/limestone/plaza. **One tile, not Tungsten's two.**
- **BC7 mode histogram** (all 72 trailers, 304,200 blocks): first tile = last
  tile = `{m6: 258470, m5: 31166, m7: 12266, m4: 2297, m3: 1}` —
  **100.00% modes 4-7**. There is no degenerate second raster here.
- **The plugin's current read is wrong in a NEW way.** The final 4,624 bytes —
  what `bf6_splat.gd::color_tiles()` slices — are **also 100% modes 4-7**,
  because they are the bottom rows of the real 260-wide tile. So on Limestone
  the mode-histogram test CANNOT distinguish the correct read from the current
  one; only the size decomposition places the tile boundary. A colour decode of
  that slice as 68x68 produces plausibly-coloured garbage whose mean is roughly
  right — a mean-based check would pass a broken decode on this map.
- `detect_layout` picks `(page 2592, tile 4624)` here per MAP-TUNGSTEN.md §C3's
  16-map simulation (this map's true row: **page 4356**, trailer one 67,600 B
  tile), so the weight pages are additionally decoded with the wrong codec
  (BC4 instead of raw 66x66).
- Ambiguity example worth keeping: node 0x33's chunk is 17,424 bytes — the size
  of a 132x132 BC7 tile — but it is `m=4` raw pages. Size alone cannot classify
  a chunk; the block-1 page count `m` must anchor the decomposition.

**MEASURED — paired chunks contradict the paired-tile law.** Limestone has 8
paired chunks and every one decomposes as `sum(children m) x 4356` **exactly —
zero colour tiles**. Tungsten/dumbo paired chunks end with four child tiles in
reversed order (TERRAIN.md §5.2, bf6_colormap.py); Limestone's paired chunks
carry pages only, and each child's colour tile lives solely in its own primary
chunk. A reader that unconditionally strips four tiles from a paired chunk
corrupts every Limestone paired read. **Say it loudly: "paired chunks end with
4 child colour tiles" is per-map, not universal.**

## 2. The rendered colour map

**MEASURED** (`probe_limestone_colorrender.py`, decodes each 260² tile as
DX10-wrapped BC7 through Pillow, crops the 2 px apron, blits coarse-first).
Written to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Limestone.png`.
**It reads as a completely coherent aerial photo of Gibraltar** — sea, moles,
marinas, the airport runway, town, the Rock — with one caveat: the dense
playable zone in the map centre is flattened to a near-uniform pale grey
(authored that way, not a decode artefact; the surrounding vista keeps full
satellite detail). Mean RGB over the 72 tiles: **(0.468, 0.469, 0.477)** —
neutral because of the sea and the grey centre. No SDK overhead image of
Limestone exists in the project to diff against (maptiles are on-demand since
SDK 1.4.1.0), so the check is visual.

**HYPOTHESIS.** The grey centre means the colour map contributes little inside
the playable space of this map; Limestone's in-play ground colour must come
from layers and decals, with the colour map mattering mostly for the vista.
(Consistent with 0.5-neutral modulation: the grey is ~uniform, so it brightens
the composite uniformly rather than painting detail.)

---

## A. Water

**MEASURED — MP_Limestone ships NO WaterSurfaceEntityData at all.**
`probe_tung_types.py mp_limestone --find "water|ocean|river|creek|pool|lake"`
scans all 667 partitions: the only hit is `OceanComponentData` inside
`lighting/ve_mp_limestone_base_01.ebx`. `_layers_content/water.ebx` is a
414-byte `LayerData` with `Objects = []`; `water_shared_schematic.ebx` holds
only schematic-channel plumbing (SchematicChannel/MathOp/AreaProximity
entities); there is no `WaterAsset`, no `WaterOceanSimulationEntityData`, no
river layer of any name. Yet the map is an island surrounded by sea.

- The VE preset's `OceanComponentData` (instance 11, `@+0x990`) has
  `PropertyOverrides = [Enable, ShoreFadeDistance, SunShadowScale,
  MaterialModel, Albedo, IndexOfRefraction, SimplifiedDistortion]`, albedo
  (0.600, 0.937, 0.949), absorption R/G/B = 0.2/0.5/1.0.
- **HYPOTHESIS.** The visible sea is the global ocean system driven by the VE
  preset (terrain floor is y = 0.112, i.e. the map sits at sea level), plus the
  satellite sea already baked into the colour map for the vista. Nothing for a
  static reader to place.
- **Plugin consequence (MEASURED absence):** `highpoly_gamesource.gd::water()`
  finds no entity on this map — correctly drawing nothing — but it cannot
  distinguish "no water authored" from "read failed". Worth a log line: on
  Tungsten the diagnostic is "water y below floor", here it is "no
  WaterSurfaceEntityData in the level".

This extends the water table of MAP-TUNGSTEN.md §A3 with a third case:

| level | water y | terrain min y | state |
|---|---|---|---|
| mp_aftermath | 49.70 | 0.11 | renders |
| mp_tungsten | 0.00 | 64.77 | buried |
| **mp_limestone** | **no entity** | 0.11 | **nothing to render** |

## B. Terrain and ground layers

**MEASURED.** `mp_limestone_terrain4k.VisualTerrain` (688 B): `layerCount = 40`,
`SurfaceShaderBlockKey = 0xE5D8C318DBB3741E`, links **L35..L39 -> L34**, all
flag bytes 0. Streaming tree blocks: 0 (heights, 9,510 B), 1 (splat,
310,161 B), 4 (mask, 365 B), 7 (material raster, 174,448 B), 8 (mask raster,
536,737 B). **No block 2 (density) and no block 5** — Tungsten ships both, so
their presence is per-map, verifying that block set must be discovered, not
assumed. `LayerSlotCount = 6` (as on Tungsten; still not the layer count).

**MEASURED — the layer-table location law holds and bites again.** The weak
"keys distinct" rule fires at offset **120** in `…DE540C59` (1,488 B,
recordCount 40) and produces a plausible table whose L00/L01 keys are
`0x0000000100000001`-style garbage; the 100%-depot-resolve rule
(`probe_tung_layers.py`) finds the true table at offset **188**, 40/40 keys
resolving in `layergraphs_shaderblockdepot` (40 keys over 30 deduplicated
records, 70 texture params, 270 inline constants).

Splat block 1: 165 nodes, 9,352 records, slack 0. Painted / base split (flags
bit 0x0100 at record +20):

```
painted (22): L02 x206, L03 x202, L06 x34, L25 x31, L01 x30, L04 x29, L05 x26,
              L33 x26, L32 x21, L13/L14/L26 x20, L07/L08 x19, L31 x16, L15 x14,
              L18/L21/L23/L27/L28/L29 x12
base (13):    L00 L10 L11 L12 L16 L17 L34 L35 L36 L37 L38 L39 x660, L01 x627
absent (6):   L09 L19 L20 L22 L24 L30  (no splat record at all)
```

### B1. The "textures only on base layers" ceiling is NOT absolute here

**MEASURED** (`probe_tung_layers.py mp_limestone`, full table in the probe
output). Texture-binding layers:

| L | side | binds |
|---|---|---|
| 00 | BASE | `t_com_asphaltdetail_02_ncs` (detail only, no albedo) |
| **04** | **painted x29** | **`t_wuu_grass_fairway_01_{cv,ao,nhs}` — a full real albedo set on a PAINTED layer** (golf-course fairway grass) |
| 06,07,08,13,14,15 | painted | `t_gen_breakupmask_02_rgba` + `t_com_asphaltdetail_02_ncs` (mask + detail, no albedo) |
| 10, 16 | BASE | `t_ter_defaulttexture_{cv,ao,nhs}` + breakup mask (engine default set) |
| **11, 12** | BASE | **`common/environment/common/debug/roadblockout_01`** `_cv/_ao/_nhs` + defaults — a DEBUG blockout texture set |
| 17 | BASE | `t_ter_defaulttexture_ao` only (the Tungsten-L10-style default record) |
| 34 | BASE | `hfd_debug` at slot `0xAE16A5C0` — **the crater layer, verifying that law**; L35-L39 link to it |
| 35, 36 | BASE | `wum_ls_gravel_02` a/b + `wum_crackedconcrete_03` (+`concreteedge`/`asphaltedge` on 35) — 9 textures each |
| 37 | BASE | `wum_ls_gravel_01_a` + `t_wum_td_sand_01_ncs` |
| 38 | BASE | `wum_dryrockygravel` + sand detail |
| 39 | BASE | `wum_concretedebris_01`+`_02` (6 textures) |

So: **on Limestone 7 of 22 painted layers bind textures, and one of them (L04)
binds a genuine colour albedo.** Tungsten's "all painted layers are textureless"
is Tungsten-absolute, not universal. The correct universal statement is:
**real terrain surface albedos live overwhelmingly on the base side; painted
layers usually bind at most masks/details, but CAN carry a full albedo set**
(one in 40 here). A plugin splat compositor that skips textures on painted
layers loses L04's fairway grass on this map.

Also new: **most of Limestone's base-field albedo is literally debug content**
(`roadblockout_01`, `t_ter_defaulttexture`, `hfd_debug`) — see B2. Ten layers
(L01, L24-L33) have the empty depot record (`contentHash 04B2008FD98C1DD4`,
zero parameters), the same class as Tungsten's L22-L27.

### B2. Block 7 — material raster

**MEASURED** (`probe_tung_terrain.py`, `probe_tung_basefield.py`): dim = 256,
34 populated nodes, levelMax 5, all rows nibble-RLE-clean, walk ends exactly at
the 68-byte footer. `pairCount = 15` (11 used, 4 zero),
`BackgroundMaterialIndex = 0x00000080` — the **"no background" sentinel** like
dumbo/eastwood (Tungsten's real-pair background is the odd one out). Pair 8
`0x06923180` (X=0x31, list 2) again lands on the `wum_ls_gravel` family —
third map confirming TERRAIN.md §8's X=0x31 observation.

Texel share of the resolved base field:

```
L11  79.2%   debug roadblockout_01  (!)      L00   1.3%  detail-only
L02  13.3%   textureless                     L36   0.2%  wum_ls_gravel_02 (real)
L12   5.9%   debug roadblockout_01           L01   0.1%  empty record
                                             L37   0.05% wum_ls_gravel_01 (real)
```

**The honest ceiling on this map:** only **~0.25%** of the base field resolves
to a layer with a real (non-debug) albedo; ~85% resolves to the
`roadblockout_01` debug set and the rest is textureless. Limestone's in-play
ground is meant to be covered by road/plaza meshes and decals — with the ground
seen mostly through the L04 fairway (painted weight pages) and terrain decals.
The block-7-only view of this map is essentially a blockout. (Compare
Tungsten's 20.6% real-albedo ceiling: same shape, far lower number, different
reason.)

### B3. The six unidentified constants — Limestone's distributions

**MEASURED** (`probe_limestone_constants.py mp_limestone`, control run on
mp_tungsten in the same probe). Per-layer table in the probe output; summary:

| hash | on | values (Limestone) | with Tungsten control |
|---|---|---|---|
| `0x4C200FE0` f32 | 27/40 | `0 x22, 0.01 x3, 0.005 x1, 0.02 x1` | Tungsten adds negatives (-0.04..-0.01). Range across both: [-0.04, +0.02]. The non-zero Limestone values sit on the debug-blockout and gravel-path layers. HYPOTHESIS unchanged: small signed height/blend bias. |
| `0xCBB9A946` f32x2 | 27/40 | **(0,0) x27 — all** | (0,0) on all 22 Tungsten layers too. 60/60 layers over two maps never use it. A UV pan that is never authored. |
| `0xCF3F97E0` int (`0x34791132`) | 25/40 | `4 x21, 2 x4` | Tungsten `4 x18, 2 x1, 0 x1`. Confirmed integer enum {0,2,4}; 4 is the default. On Limestone the value-2 layers are L09/L11/L12/L16 — three of the four are the debug/default-texture base layers. HYPOTHESIS: variant/quality selector for the layer shader path. |
| `0xF7652FB3` f32 | 17/40 | 1..45 (2 x3, 6.5 x2, 5 x2, 15.56 x2, 1 x2, then 7.256, 10, 10.22, 20.96, 35, 45) | Same range (2..45) on Tungsten. |
| `0x2F9990B7` f32 | 17/40 | 0.328..266.4, mostly round 45..270 (100 x3, 50 x3, 80 x2, 45, 75, 150, 160, 185, 234.2, 266.4, 105.4, 0.328) | Tungsten adds 1.2..1334. |
| `0xE68B2B10` f32 | 19/40 | `1.0 x15, 0.5 x3, 0.236 x1` | Tungsten `1.0 x18, 0.5, 0.3`. A 0..1 scalar defaulting to 1. HYPOTHESIS: layer intensity/opacity multiplier. |

**MEASURED — the strongest new structural fact:** `0xF7652FB3` and
`0x2F9990B7` **co-occur exactly** — on Limestone the same 17 layers carry both
and no layer carries only one (Tungsten: the same 19 layers carry both). They
are a paired parameter set. HYPOTHESIS: a distance + scale pair for far/macro
tiling (0x2F9990B7 values look like metres — 45..270 round numbers — with rare
ratio-like outliers 0.328/1.2/1334; 0xF7652FB3 1..45 like a repeat factor).
Not proven; the compiled layer-graph program would have to be read.

**MEASURED — depot records are shared content across maps:** Limestone
L37/L38 print byte-identical constants (45/45, 35/105.4, tiling 0.075/0.055…)
to Tungsten L30/L31 and bind the same `wum_ls_gravel_01`/`wum_dryrockygravel`
sets; the `wum_ls_gravel_02` pair (0.328 / 15.56) recurs on both maps too. The
per-layer ShaderBlockDepot record is a content-addressed library shared by
maps, not per-map authoring — which is why cross-map value distributions of
these constants cluster.

## C. Decals and roads

**MEASURED** (`probe_tung_decals.py mp_limestone`). `decals.TerrainDecals` is
8,037,808 B: `slotCount = 40` (= layerCount, law verified; 34 empty), 371
records, all parsed, **0 chain breaks**. Asset slots used: **10, 11, 12, 16,
17** — exactly the textured base-layer indices again (the debug/default ones on
this map). 52 texture-set groups; the big ones are southern-Europe street
surfaces: `naf_pavementsquaretiles_02` x41, `seu_concretepatchspline_01` x35,
`seu_tilesstone_03` x34, `seu_cobblered_01` x28, `seu_concretebroken_02` x18,
`com_watermarks_01` x14 (an `_op`-only mask group — same reader gotcha as
Tungsten's roadvariationmask), plus manhole covers, potholes, road lines,
gutters. Groups again mix libraries (cas_ potholes + seu_ roadlines with
naf_/seu_ splits), so grouping must key on the whole texture set.

**MEASURED — coverage is a postage stamp.** The union AABB of all 371 records
is x ∈ [215, 463], z ∈ [-46, 188], y ∈ [42.5, 87.1] — one ~250 x 235 m patch
of old town. **>99% of the 4,096 m world square carries no terrain decal.**
(Tungsten already showed a third of the map bare; Limestone is the extreme
case.) Any "why is the ground bare here" question outside the town centre is
answered by authoring, not by a reader bug.

## D. Everything else notable

- **MEASURED — structure:** world content is a single `_layers_world/world.ebx`
  (3.1 MB, 44 `LayerReferenceObjectData`, 1 SubWorldData) with ONE
  `staticmodelgroup.physics.PhysicsResource` (12.5 MB) — **not** Tungsten's
  nine `area_00N` subworlds each with its own physics. Area granularity here is
  by *content type* layers (`area_0N_architecture/decals/props/roads/
  vegetation`, N = 1..5). A walker keyed on "one physics per area subworld"
  must not assume that shape.
- **MEASURED — gamemode layer naming oddities** (for the gamemode miner):
  `domination/` sits at the level root, NOT under `_layers_gameplay/`;
  strikepoint is nested as `_layers_gameplay/flag/strikepoint`; squaddeathmatch
  and teamdeathmatch double their directory (`squaddeathmatch/squaddeathmatch`);
  breakthrough/rush are absent; `sabotage`, `koth`, `freeroam0`, `customportal`
  are present; and there are per-area gameplay gates
  `_layers_gameplay/area01_rooftops`, `area04_rooftops`, `area04_interiors`.
  Five gamemodes share depot `shaderblockdepot_9526102139013923511` byte-for-byte.
- **MEASURED — backdrop/skyline:** `_layers_world/backdrop.ebx` is empty;
  `_layers_world/backdrop_near.ebx` carries **79
  SpatialPrefabReferenceObjectData + 2 TerrainFillDecalData**;
  `generated/backdropbuildings_output_09c85e22.ebx` is empty (baked). So the
  skyline for this map is the 79 near-backdrop prefabs; anything missing in our
  build should be checked against that layer first. `TerrainFillDecalData` is a
  type worth noting for the environment-decal open task.
- **MEASURED — scatter:** the level ships
  `mp_limestone/meshscatteringdatabaseasset.MeshScatteringDatabase` (15,724 B,
  **43 records, walk lands on the exact final byte** — layout law verified).
  But **all 40 `SingleTerrainLayerData` instances in
  `mp_limestone_terrain4k.ebx` have `MeshScatteringTypes = []`** — zero
  per-layer scatter bindings on the whole map. The Identifier→catalogue join
  therefore CANNOT be validated here; and conversely, a populated catalogue
  with zero per-layer consumers means the catalogue is not gated on
  MeshScatteringTypes. Two catalogue records carry inline point lists
  (`ms_com_grasskitflat_01_a_mesh` 19 pts, `ms_com_grasskitshort_01_a_mesh`
  81 pts) — the "catalogue, not placement" reading is mostly right but not
  strictly: some records do embed points.
- **MEASURED — the biggest files are lighting again:** enlighten highend
  92.6 MB + lowend 44.5 MB, materialgrid 14.9 MB. Nothing reads them.
- **MEASURED — no BR/extra-host content** (unlike Tungsten's granite payload):
  the level directory holds only its own MP content plus `_layers_autotests`.

## E. Generalisation — what holds, what breaks

| finding | scope | verdict |
|---|---|---|
| Page size 4356 for limestone; detect_layout's (2592, 4624) pick is wrong here | verifies MAP-TUNGSTEN §C3 row | **CONFIRMED** by exact decomposition, 76/76 chunks |
| Colour trailer = ONE 260² BC7 tile; first tile = colour map | per-map tile size/count | **CONFIRMED**, and the "two tiles, take the first" Tungsten shape is absent — trailer shape is per-map: count AND size must come from the decomposition |
| **Paired chunks carry four child colour tiles** | claimed by TERRAIN.md §5.2 / bf6_colormap.py | **CONTRADICTED on Limestone** — all 8 paired chunks are child pages only, zero tiles |
| **BC7 mode test tells the colour tile from a wrong slice** | MAP-TUNGSTEN §G2 proposes it as validation | **INSUFFICIENT on Limestone** — the tail-4624 slice of the single big tile is also 100% modes 4-7; only the size decomposition is decisive |
| "Textures live on the base side" | absolute on Tungsten | **WEAKENED** — L04 is painted with a full real albedo set; 6 more painted layers bind masks/details. Treat as strong prior, not invariant |
| `0xAE16A5C0` = crater slot, one layer per map, linked-to | universal | **CONFIRMED** (L34, hfd_debug, L35-39 link) |
| `0xCF3F97E0` integer {0,2,4} | universal | **CONFIRMED** (2 x4, 4 x21) |
| Layer table located only by 100% depot resolve | universal | **CONFIRMED** — wrong-but-plausible table at offset 120, true at 188 |
| Empty ECS stub is boilerplate | universal | **CONFIRMED** — 31/31 empty |
| decals slotCount = layerCount; used slots = textured base indices; op-only groups exist; AABBs bound sparse coverage | universal | **CONFIRMED** (40 slots, slots 10/11/12/16/17, watermarks op-only, one 250 m patch) |
| Water y vs floor diagnostic | universal | **EXTENDED** — third case: no water entity at all (0 in 667 partitions); sea = VE OceanComponentData + colour-map imagery |
| Terrain dir naming | universal warning | **CONFIRMED + new variant** `mp_limestone_terrain4k` |
| Blocks 2/5 optional per map | universal | **CONFIRMED** (absent here, present on Tungsten) |
| Chunk directory may contain zero-GUID, zero-size entries | new | node 0x30: a Packed node with no chunk; readers must tolerate it |

## F. Next actions for the plugin, prioritised

1. **`addons/highpoly_toggle/bf6_splat.gd::detect_layout`** — same fix as
   MAP-TUNGSTEN §G1; this document is the Limestone verification row: page
   4356, prefix set {0, 149297}, trailer 67,600.
2. **`bf6_splat.gd::color_tiles`/`assemble_colors`** — tile size and count must
   come from the per-chunk decomposition (`trailer = k x tile`), NOT from a
   fixed 4,624 slice and NOT from the mode test alone (insufficient here). On
   Limestone the correct read is one 260x260 tile (crop 2 px apron); paired
   chunks contribute NO tiles on this map, so the paired-tile path must be
   conditional on the decomposition too.
3. **`bf6_splat.gd` splat compositor** — do not assume painted layers are
   textureless: composite L04's `t_wuu_grass_fairway_01_cv` through its weight
   pages (29 records). This is the only real grass albedo in Limestone's
   playable area.
4. **`highpoly_mapcontext.gd` colormap enable** — on Limestone the colour map
   is the entire vista (sea + town + Rock); with the centre grey it will not
   fight the composite in-play. Good second verification map after Tungsten.
5. **`highpoly_gamesource.gd::water()`** — add the "no WaterSurfaceEntityData
   in level" log branch (distinct from Tungsten's below-floor branch).
6. **`bf6_terrainlayers.gd`** — when the crater slot `0xAE16A5C0` lands, L34 is
   Limestone's crater layer (L35-39 link to it).
7. **Gamemode miner** (`docs/GAMEMODE-MINER.md` consumers) — handle
   `domination/` at level root, `flag/strikepoint` nesting and doubled
   `<mode>/<mode>` directories when walking `_layers_gameplay`.
8. **Upstream** to `BF6_Frostbite_Research/formats/TERRAIN.md` §5.2: paired
   chunks do not always carry child colour tiles (Limestone: never), and the
   trailer's tile count/size is per-map; `findings/meshscatteringdatabase-layout`:
   note that per-layer `MeshScatteringTypes` can be empty map-wide while the
   catalogue is populated, and that some catalogue records embed points.
