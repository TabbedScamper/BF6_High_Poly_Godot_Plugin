# MP_GolmudRailway, end to end

One map read from the shipped data, following `MAP-TUNGSTEN.md`'s template and
verifying its laws. Golmud is a Season/DLC map and it is the fleet's best
counterexample generator: **three of the established laws break here** (colour
tile codec, painted-layers-are-textureless, TerrainDecals record layout), and
one law that MAP-TUNGSTEN could only state as a bug symptom (detect_layout) gets
a decomposition table with genuinely new values in it.

**Every claim is tagged MEASURED or HYPOTHESIS.** Probes live in
`tools/probe_golmud_*.py`; they reuse the `probe_tung_*` plumbing (same dump,
same read-only rules) and every number below reproduces from them:

```
probe_golmud_sizes.py        chunk size histogram, residue classes
probe_golmud_decomp.py       exact decomposition + trailer codec tests
probe_golmud_tail936.py      what the 936-residue tail actually is (byte level)
probe_golmud_bc1color.py     BC1 colour tile verification + the rendered map
probe_golmud_vehicles.py     gameplay-layer gem/spawner census (task #32)
probe_golmud_scatterjoin.py  MeshScatteringTypes -> catalogue join attempt
reused: probe_tung_terrain / layers / types / water / ecs / basefield /
        decals / structure  (all take the level name)
```

Sanity anchors: block 0 walks byte-exact (slack 0), block 1 walks all 23,185
declared nodes with slack 0, block 7's node stream ends exactly at its 68-byte
footer (4 + 15x4 + 4), and the layer-graph record table resolves 53/53 keys in
the depot.

---

## 0. The map in one paragraph

**MEASURED.** MP_GolmudRailway is an **8,192 x 8,192 m** world (block 0 root
AABB `x,z ∈ [-4096, 4096]` — 4x the area of Tungsten), ground from
**y = 80.251 to 1,824.801**, `WorldSizeY = 1881.0` (coarsest height
quantisation of any map studied: one u16 step = 2.87 cm). 5,857 streaming
nodes (725 block-0 nodes: 5 Packed + 720 External), **53 terrain layers** of
which **30 bind textures — including most painted layers**, `LayerSlotCount =
62`, 477,692 splat records. The terrain directory is named
`mp_golmudrailway_terrain8k` — a third naming variant ("terrain8k") after
`terrain_mp_tungsten` and `mp_dumbo_terrain`; `terr_dir()`'s substring search
still finds it. 1,135 partitions, 237 LayerData (123 with zero Objects), 63
EcsRuntimePrefabAsset — **all empty stubs**, 35 ShaderBlockDepots. The level
hosts a moving-train Portal subworld (`portal_movingtrain`), static-train
variants for breakthrough/rush, and it ships **no water entity of any kind**.

Blocks present: 0 (31,542 B), 1 (15,972,561 B), **4** (14,733 B boolean mask,
`57 + 4x3669` exact), 7 (5,822,066 B, dim=512 — double Tungsten's 256), 8
(1,124,143 B, dim=265, levelMax=5). **No block 2, no block 5** (Tungsten
ships 2, 4, 5; dumbo/aftermath neither) — the block set is per map, full stop.

---

## A. Water

**MEASURED — the level contains zero water types.**
`probe_tung_types.py mp_golmudrailway --find "water|ocean|river|lake|puddle"`
scans all 1,135 partitions: **0 match**. No `WaterSurfaceEntityData`, no
`WaterAsset`, no `WaterOceanSimulationEntityData`, nothing. The only artefacts
are an empty `_layers_content/water_shared_schematic.ebx` (a `LayerData` with
`Objects = []`) and an empty `_layers_world/bg_lakes.ebx`. There is no
`_layers_content/water.ebx` at all.

This is a **new case** for the plugin: on every previously studied map the
water entity exists (visible or buried). Here `_water_partition()` finds no
partition containing the type — whatever it does in that case is what the
water toggle does on Golmud, and the honest log line is "this level ships no
water entity", not a parse warning.

**MEASURED — wetness is terrain-side.** Ground layer **L41** is a dedicated
puddle layer bound on all 23,185 splat nodes as a base layer, with exactly one
texture: `westuscoastal/terrain/terraindecals/waterpuddles_01/wum_waterpuddles_01_rgb`
(plus 7 constants, e.g. `0x5227ADCF = 1.8`). Art layers `a_wetness`,
`b_puddles`, `hq_01_puddles`, `substation_puddles` exist as (mostly empty)
layers. The river law from Tungsten ("rivers are terrain, not water") holds
trivially — there is no river on this map, and nothing pretends to be one.

**MEASURED — ECS law verified.** All 63 `EcsRuntimePrefabAsset` partitions are
the identical empty stub `ent=1 arch=1 seg=1 edits=0 comps=[26]`
(`probe_tung_ecs.py mp_golmudrailway`). No populated ECS prefab ships.

---

## B. Terrain and ground layers

### B1. THE LAW BREAK: painted layers bind textures here

`MAP-TUNGSTEN.md` F: *"Terrain materials live on the base side; on Tungsten
all 24 painted layers are textureless"* — labelled "every map". **MEASURED —
false on Golmud.** Of 53 layers, **30 bind textures**, and the textured set
includes heavily-painted layers: L02 (`stonesdirt_01`, painted x3,347), L08
(`wum_chap_distance_02` x20,292), L36/L37/L38 (`larger_rocks_01` x20,498 /
18,842 / 15,473), L13 (`wum_ls_sidegravel_03` x11,005), L10
(`cliffsidehuge_03` x7,054), L12 (`wum_dirtroads_base_02` x3,179), L15, L16,
L23, L35... The base-side layers are textured too (L00 `mudside_01` x22,322,
L07 `sandtwigs_03`, L09 `gravelsand_04`, L24-L28 defaults, L41 puddles, L46
crater, L47-L51 gravel/concrete). The painted/base **mechanism** is unchanged
(record `+20` flag bit 8, base palette on every node); only the "textures are
base-only" correlation dies. `bf6_materialtree.gd`'s base-side handling stays
necessary, but any code path that skips texture lookup for painted layers
throws away most of this map's ground detail.

Consequence for the honest ceiling: on Tungsten only 20.6% of ground resolved
to a layer with albedo. On Golmud the block-7 base field resolves **~100% of
texels to textured layers** (B3), and the painted overlay is textured as well.
This map will actually look painted once the codecs are right.

### B2. The layer table

**MEASURED.** `layergraphslayergraphs` (0xDE540C59, 1,956 B) declares 53
records; the table sits at **offset 240**, found by the 100%-resolve rule
(53/53 keys in the 19,740 B depot; 45 content-deduplicated records, 147
texture params, 403 inline constants). The weak "distinct keys" rule fires at
**172** and yields a wrong-but-plausible table — the Tungsten law about table
location is **re-verified** exactly.

`VisualTerrain` (789 B): `layerCount 53`,
`SurfaceShaderBlockKey 0xE23F83C5C217BEC5`, and **seven** linked layers:
**L47, L48, L49, L50, L51 -> L46** (the crater cluster) plus **L07 -> L06 and
L09 -> L08** — the first observed links *outside* the crater structure.
L06/L08 are `wum_chap_distance_*` far-tiling materials, L07/L09 are
`sandtwigs`/`gravelsand` close-up materials. HYPOTHESIS: these pairs are
near/far halves of one material.

**MEASURED — crater law verified.** L46 is the only layer binding slot
`0xAE16A5C0` (`hfd_debug`), L47-L51 link to it — same structure as Tungsten
L28/L29-32 and dumbo L41/L42-45, with five links instead of four.

Highlights of the full table (complete dump in the probe output;
`probe_tung_layers.py mp_golmudrailway`):

| L | side | binds |
|---|---|---|
| 00 | BASE x22322 | `t_cas_mudside_01` cv/ao/nhs |
| 02 | painted x3347 | `t_cas_stonesdirt_01` — **90% of the block-7 base field** |
| 03,05,15,16 | painted | **dual texture sets** — close (`0929399a` set) + distance (`2e5acda8` set) + breakup mask |
| 06/08 | painted (large) | `wum_chap_distance_*_golmud` + `_ssm` slot `0x07A9B250` |
| 10 | painted x7054 | `t_cas_cliffsidehuge_03` — **BackgroundMaterialIndex layer** |
| 11,14,17,18,21,29-34,39-45,52 | painted | textureless (constants only, some empty records) |
| 12 | painted x3179 | `wum_dirtroads_base_02` — dirt roads |
| 19,20,22 | painted | `t_com_asphaltdetail_02_ncs` detail — asphalt roads |
| 24-28 | BASE x23183 | `t_ter_defaulttexture_*` defaults (L27 binds the `asphaltedge_01` set) |
| 36,37,38 | painted x15-20k | `t_larger_rocks_01` cv/ao/nhs/**op** + `t_wum_td_sand_01_ncs` |
| 41 | BASE x23185 | `wum_waterpuddles_01_rgb` — the puddle layer |
| 46 | BASE x23185 | `hfd_debug` at `0xAE16A5C0` — crater |
| 47-51 | BASE x23185 | gravel / cracked concrete / concretedebris families (link to L46) |

**MEASURED — new texture slot hashes** (beyond Tungsten's set), worth adding
to the plugin's slot table: `0x0929399A/0x09293A41/0x2E50567A` (close
cv/ao/nhs), `0x2E5ACDA8/0x2E5ACDF3/0xF9B44F08` (distance cv/ao/nhs),
`0x2E5B5189/0x2E5B51D2/0xF9C55709` (third set), `0x304613CC/0xF860C3BE`
(alternate ao), `0x07A9B250` (`_ssm`), `0x0B725504` (breakup mask
`t_gen_breakupmask_02_rgba`), `0xB6C7E795` (`_ncs` detail), `0xEB1B291C`
(`t_scatternoises2_rgb`), `0x09293810` (op/default-ao slot, already known).
Also new constants seen: `0x37984D1E/1F`, `0xD46383AC/AD` (per-set tiling
pairs on the dual-set layers), `0x4FDCF6B1` (float3 tint-ish, values around
0.5-2.2), `0xD8576C4B`, `0xDE3589AF` (uint 0/1).

`0xCF3F97E0` — **MEASURED** again as the integer type (values 0/2/4 here),
confirming the Tungsten correction.

### B3. Block 7 — material raster

**MEASURED** (`probe_tung_basefield.py mp_golmudrailway`): dim=**512**,
pairCount=15, `BackgroundMaterialIndex = 0x0660FA80` — numerically identical
to Tungsten's, but here list 0 low-nibble 10 resolves to **L10 =
cliffsidehuge** (the value is a coincidence of the encoding, not shared
meaning). New pair level digit: pair 13 has `Y=0x81` (level 8) — levels 6/7/8
appear where Tungsten had 6/7. Texel share, pooled: **L02 90.0%, L00 6.2%,
L06 3.2%**, then L10/L12/L11/L09/L01/L07 under 0.3% each. Rasterised, the
base field draws the railway as a continuous dark line across the map and the
northern mountain drainage in L00/L06 — a recognisable picture. **Every
significant base-field layer is textured on this map.**

### B4. Splat

**MEASURED.** Block 1: `LayerSlotCount 62` (same as dumbo/aftermath/eastwood —
Tungsten's 6 stays the outlier), 23,185 nodes / 477,692 records, slack 0.
38 layers painted; a ~15-layer base palette (L24-28, L41, L46-51, L00, L07,
L09) present on effectively every node. Weight pages are **2,592 B = BC4 72x72
with 3-px apron** (TERRAIN.md 5.2 row 1) — verified by the decomposition below.

---

## C. The colour map — BC1, not BC7 (LAW BREAK #2)

### C1. The decomposition table (the detect_layout verification row)

**MEASURED** (`probe_golmud_sizes.py`, `probe_golmud_decomp.py`). Every
primary chunk size falls in exactly three residue classes mod 2,592:
**{0, 936, 2489}**, and 2,489 = (149,297 + 936) mod 2,592. Exact
decomposition over all 10,182 on-disk chunks:

| page size | chunks decomposing exactly | verdict |
|---|---|---|
| **2,592** | **10,182 of 10,182** | the page size |
| 4,356 | 0 | excluded |
| 5,184 | 5,261 (ambiguous multiples only) | excluded |

with the canonical split:

```
x4330  paired   pages only                      (no tiles in ANY paired chunk)
x2944  primary  pages + 1 x 8,712 tile
x2188  primary  pages only                      (no tile — mostly depth 7/8 leaves)
x720   primary  149,297 height prefix + pages + 1 x 8,712 tile
```

The 720 prefix chunks are **exactly** the 720 External block-0 nodes — a
byte-perfect cross-check. Height prefix values observed: **{0, 149297} only**
(no 39,919 / 189,216 — no block 2 on this map, consistent with the prefix
being the External heightfield payload).

**The trailer is 8,712 bytes = 33x33 blocks x 8 = one 132x132 BC1 tile.**
This is the size MAP-TUNGSTEN.md's prefix/trailer grammar cannot produce: 936
appears in TERRAIN.md 5.2 only as an undecoded "(opt. +936 tail)" aside;
Golmud shows what it is — a BC1 trailer's residue (8,712 mod 2,592 = 936).

### C2. Codec proof

**MEASURED — the BC7 mode test FAILS on this map and must fail.** Last/prev
4,624 and 17,424 windows over all primary chunks: 1.9-4.5% modes 4-7 — under
the law's reading, "no colour tile anywhere". The bytes are BC1
(`probe_golmud_tail936.py` hexdumps show 8-byte blocks of paired RGB565
endpoints + 2-bit index words; `probe_golmud_bc1color.py` decodes them):

```
3,664 tiles, 3,990,096 blocks
  99.3% four-colour blocks (c0 > c1), 0.00% punch-through texels
  endpoint max-channel deltas concentrated < 96/255 (image-like, not noise)
  mean RGB (0.562, 0.530, 0.509)  -- 0.5-centred, per the modulation law
  tile-bearing nodes per depth: {2:16, 3:64, 4:256, 5:1024, 6:2304}
```

The depth histogram is a **complete quadtree through depth 5** (4^d exactly)
plus 2,304 of 4,096 depth-6 nodes; depths 0/1/7/8 carry no tile. Paired
chunks carry **no colour tiles at all** — the Tungsten/dumbo law "paired
chunks end with 4 child tiles" also does not hold here; leaf colour comes
from ancestor tiles.

### C3. The picture

The assembled map is at
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_GolmudRailway.png`
(2048², block-resolution BC1 means, coarse-first). **It reads as a fully
coherent aerial photo**: grey-green steppe cut by white braided washes,
red-brown mesa country, the central town with green field parcels, and the
railway line traced continuously east-west through the town — unmistakably
Golmud Railway.

### C4. What this does to the plugin

`detect_layout` currently picks `(2592, 4624)` everywhere. On Golmud the page
size is *accidentally right*, and everything else is wrong: `color_tiles()`
takes the last 4,624 bytes (the tail 53% of a BC1 tile) and decodes it as
`FORMAT_BPTC_RGBA`; `node_pages()` slices at `size - 4624 - n*2592`, and since
the real trailer is 8,712 (not ≡ 4,624 mod 2,592), the page window is
misaligned by 4,088 bytes — **the weight pages are read from the wrong offsets
on this map even though the BC4 codec choice is correct.** The G1 fix from
MAP-TUNGSTEN.md must therefore also: add **8,712** to the tile-size candidate
set, choose the **codec by tile size** (8,712 -> BC1/`FORMAT_DXT1`;
4,624/17,424/67,600 -> BC7), accept **zero-tile chunks** as normal (2,188
here vs 5 on Tungsten), and not require the BC7 mode test to pass — use it
only to *classify* an already-sized tile, with a BC1 counterpart test
(fraction of c0>c1 blocks) for the 8,712 case.

---

## D. Decals and roads — new record format (LAW BREAK #3)

**MEASURED.** `decals.TerrainDecals` is **33,454,716 bytes** (6x Tungsten's),
`slotCount 53` (= layerCount — law verified), `recordCount 1,746`. Seven
slots carry a GUID: **24, 25, 26, 27, 28, 41, 46** — precisely the map-global
special base layers (the defaults, the puddle layer, the crater layer),
against Tungsten's two (9, 10).

**MEASURED — the TERRAIN.md §10 record grammar does not parse a single
record.** `probe_tung_decals.py mp_golmudrailway` parses 0 of 1,746 (chain
scan finds no anchor). The record layout changed: byte inspection
(`decal_diag*` in the session scratchpad, worth promoting into the probe set
when the layout is finished) shows each record now *leads* with a fixed
header — `u64 hash` (NOT a key of the paired depot; identity unknown), zeros,
`u32 3`, scale floats (0.5, 19.84...), **two vec4 world corner points and a
2D x0,z0,x1,z1 box** (values sit exactly in the map's coordinate/height
range, e.g. y 684.05), flag bytes `01 01 01 01`, counts (`0x18`, `0x120`,
`0xC7`, `5`), and only then a property stream in which the familiar texture
slot hash `0x399AC0336ACFE03C` (`_cv`) appears. The property stream moved
from the record head to the tail, behind a fixed geometry header.

**MEASURED — a `decals.shaderblockdepot` (4,080 B) ships beside the resource**
(Tungsten's decals have no paired depot): 20 keys over 19 records, and **every
record binds exactly one texture at slot `0xAE16A5C0`** — the crater slot —
naming the whole heightfield-decal palette:
`hfd_{xs,s,m,l}_{hard,soft}[_denied|_deny]` under
`common/shaders/terrain/craters/textures/hfdecalcopy/`. So on this map the
crater/heightfield-decal *materials* are proper depot records, and
`0xAE16A5C0`'s identification is re-confirmed from an independent direction.

**HYPOTHESIS.** The 1,746 records mix draped texture decals (roads, paths)
with heightfield decals whose materials resolve through the new depot; the
GUID-bearing slots 24-28/41/46 are the terrain-layer attachment points for
them. Deriving the full new record layout is the single most valuable
follow-up this map offers the research repo.

---

## E. Everything else notable

### E1. Vehicle spawners and liveries (task #32)

**MEASURED** (`probe_golmud_vehicles.py`). Conquest0 (55,936 B) contains 135
instances of the gem-reference type `ee2bf4d0-c3fd-b131-1c29-78b6dd42672e`,
each holding a pointer (field `0xCBD4EB97`) to an imported **gem prefab** plus
a full `LinearTransform` (world position in the Vec3 at `0xBC4B07B4`).
Census: **61 x `gem_vehiclespawner`, 18 x `gem_stationaryspawner`, 2 x
`gem_automaticaa`, 11 x `gem_vehicleresupplystation`**, 16 insertion points, 7
capture points, 2 HQs, plus battle pickups/telemetry/sector gems. The gems
live at `game/glaciermp/gamemodes/_shared/gems/vehiclespawner/...`, and beside
the generic gem sit **per-class prefabs** `gmpf_vehiclespawner_{tank, ifv,
apc, mobileaa, lighttransport, attackhelicopter, scouthelicopter,
transporthelicopter, attackplane, fighterplane, patrolboat, rhib,
ptv_dirtbike, ptv_quadbike, ptv_golfcart, ...}` and
`gmpf_stationaryspawner_{hmg, antitank, antiaircraft}` / `gmpf_automaticaa`.

**MEASURED — the layer does NOT say which vehicle a spawner spawns.** All 61
vehicle-spawner references import the *generic* `gem_vehiclespawner` and have
empty override arrays (only 9 gem references map-wide carry property-override
entries, none of them vehicle spawners). The class assignment happens in mode
logic (`diceex_setvehiclespawners` et al.), not in the spatial data. A
placement walk gets position + "vehicle spawner", not the model.

**MEASURED — livery evidence.** Vehicle skins ship as ObjectVariations under
`common/hardware/vehicles/<class>/<name>/art/skins/<vseNNNN|vslNNNN|vsrNNNN>/ov_veh_*.ebx`
(209 vehicle-path OVs; base faction liveries like `ov_veh_boat_rhib_base_all`
exist beside store skins). Directly relevant to markers: **conquest0 itself
imports `ov_hemtt_01_nat.ebx`** (NATO livery of the HEMTT truck prop) together
with `pf_hemtt_01_nongroupable_autogen` — a livery applied through the normal
per-instance ObjectVariation mechanism the plugin already implements
(`bf6_walk.gd` `F_SMG_OBJVAR`). Per-map prop reskins: **30 OV leaves suffixed
`_golmud`** (poplar/olive/walnut trees, containers, storefronts, rural houses)
plus map-local `levels/mp_golmudrailway/backdrop/buildings/ov_bd_tr_trees_golmud_01[_shrubs]`.

### E2. Backdrop / skyline

**MEASURED.** `backdrop/terrain/` ships **8 skirt segments as near+far MeshSet
pairs** — `bd_cas_terraingolmudrailway_0[1-8]_{near,far}_mesh.MeshSet` (near
ones with their own `.physics.PhysicsResource`) and per-segment `t_bd_*_cs/
_na/_rgb` textures; `backdrop/buildings/` holds backdrop tree prefabs. A
further **skyline mountain ring lives under `lighting/`**:
`lighting/cas_backdropmountains_01_mesh.MeshSet` with
`t_golmud_backdrop_mountains_cs/_nea` — a backdrop mesh a walk over
`backdrop/` alone will miss.

### E3. Trains, structure, oddities

- **MEASURED.** The moving train is a dedicated Portal subworld + layer:
  `_layers_gameplay/portal_movingtrain{,_layer}.ebx`, with
  `portal_statictrain_breakthrough_subworld`, `portal_statictrain_rush_layer`
  and `esc_cq_train` variants, and `_layers_art/c_traintracks`. Anything
  placing "the train" statically is placing a runtime-moving object — flag it
  in placement walks. Reflection cubemaps exist for the train bridge:
  `lighting/rveg/rveg_mp_golmudrailway_ext_bridgetrain_{a,b}` (rveg = cubemaps
  per the type-DB correction; only 3 rveg files total).
- **MEASURED.** World content sits in `_layers_art/*` + `_layers_world/*`
  areas named by LETTER (`area_c`..`area_i`, `area_substation`, `hqs`,
  `traversal_spaces`, `world`, farmland quadrants, `fields_e/w`) — not
  Tungsten's `area_00N`. Busiest layers: `area_f_main` (598 objects),
  `fx_global` (486), `b_props` (350). **`prefabs/pf_gol_military_warehouse_*_ruin.ebx`
  are map-local prefab partitions with hundreds of placements (234/154)** —
  a walk that only visits `_layers_*` misses them.
- **MEASURED.** Gamemode naming is mixed: subfolders (`conquest/conquest0`,
  `rush/rush0`, `domination/mp_domination0`, `obliteration/mp_obliteration0`,
  `squaddeathmatch/mp_squaddm0`) with `mp_escalation0.ebx` loose at the top,
  plus `customportal*`, `strikepoint`, and per-mode `generated/ag_*_dynamicdd`
  layers. `conquest_win32_shaderstate` depot 1,988,880 B is byte-shared with
  escalation and obliteration (same depot name hash) — the Tungsten depot
  sharing pattern again.
- **MEASURED.** Per-map FX/atmosphere: `lighting/pm_mp_golmudrailway_dust_
  {extvoxel,froxel}.C189B12B` (volumetric dust), `ve_mp_golmudrailway_base`,
  `_base_interior`, `_airunfog_01` presets, `hdrisky/`. Biggest files are
  again lighting: two EnlightenDatabases at 91.4 + 90.6 MB, then the 33.4 MB
  TerrainDecals and the 23.2 MB streaming tree; `materialgrid_win32.ebx` is
  16.75 MB.
- **MEASURED — scatter.** `mp_golmudrailway/meshscatteringdatabaseasset.
  MeshScatteringDatabase` parses with the existing `msdb.py` (77 entries,
  budgets 32768 x4, cell 4096). The terrain EBX has **69**
  `SingleTerrainLayerData` instances (not 53 — count differs from the layer
  palette) and **every one has `MeshScatteringTypes = []`** — the
  Identifier->catalogue join cannot be validated on this map. Unknown remains
  unknown.

---

## F. What generalises, what breaks (the loud part)

| finding | verdict on the established laws |
|---|---|
| Colour tile is **132² BC1 (8,712 B)**, one per tile-bearing chunk; BC7 mode test reads 2-4% and "fails" | **BREAKS** "colour trailers are BC7" (TERRAIN.md 5.3). Codec is per map. The undecoded "+936 tail" of TERRAIN.md 5.2 is this tile's mod-2592 residue. BC1 halves the size of a 132² tile; expect other Season maps to do the same. |
| Paired chunks carry **no colour tiles**; tiles exist only at depths 2-6 (complete quadtree through 5) | **BREAKS** "paired chunks end with 4 child tiles" as a universal; it is a per-map layout property. |
| **30 of 53 layers bind textures, most of them painted**; dual near/far texture sets; new slot hashes | **BREAKS** "terrain materials live on the base side" as a law. It was a correlation on 2 maps; treat painted layers as first-class texture holders. |
| TerrainDecals records: fixed geometry header first, property stream last, paired ShaderBlockDepot, leading u64 | **BREAKS** TERRAIN.md §10's record grammar (0/1,746 parse). New format version; slotCount = layerCount still holds. |
| Page size 2,592 (BC4), exact decomposition unique, prefix 149,297 on exactly the 720 External nodes | **VERIFIES** the decomposition method and the per-map page-size law; adds Golmud's row to the detect_layout verification table. |
| Layer table located only by 100%-key-resolve (240 vs the false fit at 172) | **VERIFIES** the location law, third map running. |
| `0xAE16A5C0` = crater/heightfield-decal slot (L46 + the entire decals depot binds it) | **VERIFIES**, now from two independent directions. |
| All 63 ECS prefabs are the empty stub | **VERIFIES**. |
| Zero water partitions of any type | **EXTENDS** the water law with a third state: renders / buried / **absent**. |
| `0x0660FA80` appears as BackgroundMaterialIndex on both Tungsten and Golmud but resolves to different layers | Caution: the pair *value* is not portable across maps; only the resolution procedure is. |
| Terrain dir `mp_golmudrailway_terrain8k` | third naming variant; substring search remains the only safe way. |

---

## G. Next actions for the plugin, in priority order

1. **Extend the detect_layout fix with Golmud's shapes** —
   `addons/highpoly_toggle/bf6_splat.gd`. Tile candidate set must include
   **8,712**; per-tile-size codec map (8,712 -> `FORMAT_DXT1`, others ->
   `FORMAT_BPTC_RGBA`); allow tile count **0** per chunk (2,188 chunks here);
   prefix set per map from the block-0/2 walk (`{0, 149297}` here), not the
   hardcoded four. Verification row: page **2,592**, trailer **0 or 1 x
   8,712**, prefix 149,297 on exactly 720 chunks.
2. **BC1 path in `assemble_colors` + per-node tile presence** — same file. On
   Golmud the colour tile exists only on tile-bearing nodes (depths 2-6);
   assemble coarse-first and let ancestors cover leaves. Verify the assembled
   mean is ~(0.56, 0.53, 0.51) and the railway line is visible.
3. **Stop special-casing painted layers as textureless** —
   `bf6_terrainlayers.gd` / wherever the splat composite samples albedo. Add
   the new slot hashes (B2 list): close/distance/third texture sets, `_ssm`,
   breakup mask, `_ncs`, scatternoise. On Golmud this is the difference
   between a flat map and a textured one; 90% of the base field is textured
   L02 and the painted overlay is textured everywhere.
4. **Water absence is a normal state** —
   `highpoly_gamesource.gd::_water_partition()`: when no partition in the
   level declares the water type, log "level ships no water entity
   (mp_golmudrailway)" and disable the toggle cleanly. Complements the
   MAP-TUNGSTEN G5 buried-water diagnostic (three states now).
5. **Vehicle spawner markers: classify by gem import, don't wait for a model
   name** — `highpoly_gamemode.gd`. The spatial layer gives position +
   `gem_vehiclespawner` / `gem_stationaryspawner` / `gem_automaticaa` /
   `gem_vehicleresupplystation`; the concrete vehicle is assigned in mode
   logic, not spatial data. Render a class-generic vehicle (or the gmpf class
   list if mode logic is ever decoded) and apply liveries through the existing
   ObjectVariation path (`ov_*_nat` etc. — conquest0 imports one directly).
6. **Placement walks: include `prefabs/*.ebx` map-local partitions and flag
   the train subworlds** — `highpoly_gamesource.gd` walk roots. 234-object
   prefab partitions sit outside `_layers_*`; `portal_movingtrain` content
   moves at runtime.
7. **Backdrop completeness: also scan `lighting/` for backdrop MeshSets** —
   the mountain skyline ring is `lighting/cas_backdropmountains_01_mesh`, not
   under `backdrop/`.
8. **Research-repo pushes** — `BF6_Frostbite_Research/formats/TERRAIN.md`:
   §5.2/5.3 (the 936 tail IS a BC1 132² tile; colour codec per map; tiles
   optional per chunk; paired chunks may carry none), §10 (record format has
   a second version — Golmud parses 0 records; new version has geometry
   header first + paired decals ShaderBlockDepot of `hfd_*` crater
   materials). Then finish the new decal record layout on Golmud's data — the
   biggest open decode this map exposes.
