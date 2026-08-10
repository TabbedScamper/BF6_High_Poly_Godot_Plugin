# MP_Tungsten, end to end

One map read from the shipped data until every question about it has either a
number behind it or the word "unknown". Written so the parts that generalise can
be lifted onto every other map, and so the parts that do not are labelled.

**Every claim below is tagged MEASURED or HYPOTHESIS.** A MEASURED claim names
the resource, offset or value it came from and the probe that reproduces it. If
a thing could not be determined it says so; nothing here is filled in with a
plausible mechanism.

Probes live beside this document in `tools/probe_tung_*.py`. They read the
already-extracted 2026-08-01 pull through
`BF6_Frostbite_Research/impl/pipeline/bf6_paths.py` — the one source of truth for
that root — and they are read-only against it. Nothing here touched the plugin,
its shaders, or any `user://` cache.

```
tools/probe_tung_common.py      shared plumbing: EBX, type/field names, paths
tools/probe_tung_guidscan.py    partition GUID -> asset path index (cached)
tools/probe_tung_ebx.py         dump any EBX partition in full
tools/probe_tung_types.py       which EBX types a level contains, and where
tools/probe_tung_water.py       the water surface, the river layer, the ECS stubs
tools/probe_tung_ecs.py         every EcsRuntimePrefabAsset and what is inside it
tools/probe_tung_terrain.py     streaming tree: blocks 0/1/2/7/8, layer table
tools/probe_tung_layers.py      every ground layer -> depot -> textures/constants
tools/probe_tung_colormap.py    chunk directory + colour-tile codec identification
tools/probe_tung_bc7mode6.py    mean colour of a colour tile from BC7 mode-6 endpoints
tools/probe_tung_colorrender.py assemble colour planes to a PNG
tools/probe_tung_basefield.py   block-7 material raster decoded and rasterised
tools/probe_tung_decals.py      TerrainDecals: records, materials, where they sit
tools/probe_tung_structure.py   layers, subworlds, depots, largest partitions
```

Two independent checks say the parsers below are not fooling themselves:

- **MEASURED.** `probe_tung_terrain.py mp_dumbo` reproduces the published
  mp_dumbo numbers exactly — 30 painted / 16 base splat layers, `pairCount = 16`,
  `BackgroundMaterialIndex = 0x00000080`, pair 0 `0x06710080`, pair 1
  `0x06915080` — against a decode this session did not perform.
- **MEASURED.** Every typed block walks byte-exactly on MP_Tungsten: block 0
  slack 0, block 1 slack 0, block 2 slack 0, block 7 node stream ends exactly 64
  bytes (= its footer) before the block end, and 44,032 of 44,032 nibble-RLE
  material rows decode clean (`src == rowLen`). The chunk directory walks 269
  nodes and consumes the resource to its exact final byte.

---

## 0. The map in one paragraph

**MEASURED.** MP_Tungsten is a 4,096 x 4,096 m world (`block 0` root AABB
`x,z ∈ [-2048, 2048]`), ground from **y = 64.771 to y = 992.443**, height scale
`WorldSizeY = 1045.0`, 265 samples per heightfield node, 269 streaming nodes.
Its terrain palette is **33 layers**, of which **8 bind any texture and all 8 are
base (no-weight-page) layers**. It carries 613 terrain-decal records in 21
material groups, one `WaterSurfaceEntityData`, 37 ShaderBlockDepots, 292
`LayerData` partitions of which **171 declare zero Objects**, and 61
`EcsRuntimePrefabAsset` partitions **all of which are empty**. It is also the
host level for the Granite battle-royale content (`granitebr*`, `graniteloot`,
`granitemissions` partitions sit inside `levels/mp_tungsten/`).

---

## A. Water and the river

### A1. What represents the river in the shipped data

**MEASURED — there is exactly one water entity in the level, and it is not the
river.** `probe_tung_types.py mp_tungsten --find "water|ocean|river"` scans all
1,405 partitions under `game/glaciermp/levels/mp_tungsten` and finds:

| partition | type(s) |
|---|---|
| `_layers_content/water.ebx` | `WaterSurfaceEntityData`, `WaterInteractHealthComponentData` |
| `_layers_content/water_shared_schematic.ebx` | `WaterOceanSimulationEntityData` |
| `mp_tungsten.ebx` | `WaterEntityData`, `WaterHealthComponentData` (identity transform, no geometry) |
| `lighting/ve_mp_tungsten_base_01.ebx` | `OceanComponentData` |
| `mp_tungsten/description.ebx` | `WaterLevelDescriptionComponent` |
| `terrain_.../mp_tungsten/water.mesh.ebx` | `WaterAsset` |

**MEASURED — the `WaterAsset` is empty.** `water.mesh.ebx` is 380 bytes and
holds one `WaterAsset` instance with exactly two fields: `PhysicsResource` =
`ResRef 0` (null) and its own name. There is no MeshSet beside it in the level's
resource set. It contributes no geometry.

**MEASURED — the single water surface is a 4,096 x 4,096 m plane at y = 0,
centred on the world origin.** From `_layers_content/water.ebx`:

```
Transform  right   (4096.0, 0.0, 0.0)
           up      (0.0, 1.0, 0.0)
           forward (0.0, 0.0, 4096.0)
           trans   (0.0, 0.0, 0.0)          <- water height y = 0.000
QueryBoxHalfExtent (2048.0, 0.5, 2048.0)
TileOffset         (0.0, 0.0, 0.0)
MaterialPair.Packed 114308233 = 0x06D03489
field 0x2E15621F    0x109C22DA5F67CF7A      <- ShaderBlockDepot StateKey
```

**MEASURED — that plane is 64.77 m below the lowest ground on the map.** Block 0's
root AABB minimum Y is 64.771. So the level's only water surface is buried under
the entire terrain and can render nothing.

**MEASURED — `_layers_world/river.ebx` is an empty layer.** 414 bytes, one
`LayerData` named `Game/GlacierMP/Levels/MP_Tungsten/_Layers_World/River`, with
`Objects = []`. Same for `riversplines_backdrop.ebx` and `creeks_backdrop.ebx`.

**MEASURED — the river is drawn by the TERRAIN, as ground layer L10.**
`probe_tung_basefield.py` decodes block 7 (the `TerrainMaterialTree`) and
resolves each 4-bit texel through the pair table (TERRAIN.md §8). Rasterised over
the world square, **the texels that resolve to layer 10 form the braided river
channels and nothing else**, matching the channel network in the SDK's own
overhead image `addons/bf_portal/terrain_decal/textures/MP_Tungsten.jpg`
one-for-one. L10 is 7.4% of all decoded texels. It is also the map's
`BackgroundMaterialIndex`:

```
BackgroundMaterialIndex = 0x0660FA80  ->  list 0 (all layers), low nibble 10 -> L10
pair 10                 = 0x0660FA80  ->  L10
```

**MEASURED — L10 binds no colour texture.** Its ShaderBlockDepot record
(`key 0x958F2824AC0D7783`) holds exactly one texture,
`common/shaders/textures/terrain/t_ter_defaulttexture_ao`, in the default slot
`0x09293810`, plus 14 constants (`0x7E604C6D = float3 (0.5, 0.5, 0.5)`,
`0x7AF79259 = 0.5`, `0x5707A992 = 0.05` tiling, `0xCF3F97E0 = 4`, …). Whatever
the river looks like in game is computed inside that layer's shader.

**HYPOTHESIS.** L10 is the map's *water/wet* terrain material — the flowing
channel — and the `WaterSurfaceEntityData` at y = 0 is an unused default (origin
centre, exact power-of-two 4,096 extent, y exactly 0, `TileOffset` all zero are
the signature of an untouched entity). Not proven: nothing on the entity or on
L10 names a water shader, and the compiled layer-graph program was not read.

**Unknown.** Whether the game renders any true water surface on MP_Tungsten at
all. `OceanComponentData` is present in the level's active `ve_*` preset with
`FoamEnable = true`, which argues something water-shaded exists, but that
component is present on maps with and without a visible surface.

### A2. The ECS runtime prefab — it contains nothing, and it is not special

`docs/GROUND-LAYERS.md` currently says the river "is assembled at runtime by the
same ECS system that holds conquest's objective logic". **That is not supported
by the data.**

**MEASURED.** `probe_tung_ecs.py mp_tungsten` opens all 61
`*_ecsprefab_ecsprefab.ebx` partitions in the level and decodes every
`EcsRuntimePrefabAsset` and `EcsComponentSegment`. All 61 have the identical
shape:

```
61 ECS runtime prefabs in mp_tungsten
   x61   ent=1 arch=1 seg=1 edits=0 comps=[26]
```

One entity, one archetype whose only component is type index 26, one component
segment with `StaticEdits = []` and `DynamicEdits = []`. No transform, no mesh,
no material, no bounds. `river_ecsprefab_ecsprefab.ebx` is byte-for-byte the same
shape as `area_06_props_ecsprefab_ecsprefab.ebx` — and `area_06_props.ebx` is a
15,974-byte layer with 57 Objects. **The stub coexists with real content, so its
presence says nothing about where content went.**

**MEASURED — the control.** The same probe on other maps finds ECS prefabs that
*do* carry content:

```
mp_dumbo     x54 ent=1 arch=1 seg=1 edits=0 comps=[26]      <- the same empty stub
             x1  ent=85 arch=6 seg=8 edits=90 comps=[0,58,74,78,82,86]
             x1  ent=21 arch=4 seg=7 edits=38 comps=[0,50,54,66,70]
             x1  ent=3  arch=3 seg=6 edits=2  comps=[0,42,54,58]
mp_aftermath x49 empty stub
             x1  ent=110 arch=3 seg=7 edits=113 comps=[0,50,62,66,70]
```

So a populated ECS prefab is readable when one exists. **MP_Tungsten has none.**
Its ECS layer is empty everywhere, river included.

**MEASURED.** `SourceAsset.Partition` on the river prefab is
`8352268b-f28c-11ee-a41e-b5c87f7c0da9`. That GUID is **not present in the whole
449,738-partition dump** (`probe_tung_guidscan.py .`). Same for
`riversplines_backdrop` (`2f2be42b-f26a-11ef-…`) and `creeks_backdrop`
(`ce0b5133-f268-11ef-…`). All three are v1 (time-based) UUIDs, the shape an
authoring tool mints.

**HYPOTHESIS.** `SourceAsset` names the *authoring* asset in the editor project,
which is not shipped. The prefab stub is the build record of "this layer was
authored as a prefab", and the river's authored content was **baked at build
time** into the heightfield, the block-7 material raster and the decal/scatter
sets rather than shipped as placements. Supporting but not conclusive: the
level's `generated/` directory contains
`ag_generateroadsplinesprefabasset_dc7e5505_ecsprefab.ebx` and three
`ag_loadhoudinifileprefabasset_*_ecsprefab.ebx`, all with the same empty shape,
and `_layers_world/generated/ag_*_output_*.ebx` partitions that are also empty.

**Answer to "can its contents be resolved statically": no, and not because they
are runtime-only — because there are no contents.** There is nothing in the
prefab to resolve.

### A3. Why water renders on some maps and not this one

**MEASURED.** The difference is authored height, not structure. Water height
comes from the entity's transform translation Y; terrain floor from block 0's
root AABB minimum Y:

| level | water y | terrain min y | water is | our plugin |
|---|---|---|---|---|
| mp_aftermath | 49.70 | 0.11 | 49.6 m **above** floor | renders |
| mp_dumbo | 49.80 | 24.75 | 25.1 m **above** floor | renders |
| mp_eastwood | 3.08 | 174.82 | 171.7 m **below** floor | buried |
| mp_tungsten | 0.00 | 64.77 | 64.8 m **below** floor | buried |

The entity, the transform read, the StateKey and the depot join all work
identically on all four. Tungsten's water is built correctly and put underground
by the data itself.

### A4. Correction: `+0x90` is `QueryBoxHalfExtent`, not `TileOffset`

`formats/TERRAIN.md` §11 and `findings/water-surface-geometry-from-transform-and-tileoffset`
both read the Vec3 at instance `+0x90` as `TileOffset` and conclude that
`TileOffset.xz` equals the half-extent on all 11 water surfaces in the game, with
`TileOffset.y = 0.5` everywhere.

**MEASURED — the field at `+0x90` is `QueryBoxHalfExtent`.** The retail MP exe's
own type layout for `WaterSurfaceEntityData`
(`ae0b69fc-2207-d874-8230-fcd467a592cf`, size **0x280**, 75 fields):

```
+0x020  Transform
+0x090  QueryBoxHalfExtent
+0x0B0  TileOffset
+0x1DC  MaterialPair
+0x1EC  AdditionalWaterDepth
+0x208  ProjectorElevation
+0x220  ShoreDepth
```

**MEASURED — `TileOffset` is (0, 0, 0) on every map checked.** Deserialised by
field hash rather than by offset:

| level | Transform basis / 2 | `QueryBoxHalfExtent` (+0x90) | `TileOffset` (+0xB0) |
|---|---|---|---|
| mp_tungsten | 2048 x 2048 | (2048.0, 0.5, 2048.0) | (0, 0, 0) |
| mp_aftermath | 5000 x 5000 | (5000.0, 0.5, 5000.0) | (0, 0, 0) |
| mp_eastwood | 2048 x 2048 | (2048.0, 0.5, 2048.0) | (0, 0, 0) |

So the "second, redundant read of the half-extent" is real and useful, but it is
`QueryBoxHalfExtent` — which also explains the constant `y = 0.5` (a query box is
a metre thick) far better than "a tiling phase". A consumer that reads
`TileOffset` **by name** gets zero and draws no water at all. Two documents in
the research repo need this correction; `TERRAIN.md` also states the instance
size as 0x260, and it is 0x280.

The plugin is not affected: `highpoly_gamesource.gd` reads the transform from raw
offsets `+0x20 / +0x48 / +0x50` and never reads `+0x90`.

### A5. The mud at the river

**MEASURED — `t_cas_roadmud_01_tungsten` is a genuine authored road decal, and
there is none of it at the river.** `probe_tung_decals.py` parses all 613 records
of `decals.TerrainDecals` (chain invariant `FirstIndex == prev + prevTri*3` holds
for all 613, zero breaks) and queries by world box:

```
river-upper  [    0   150 ..   800   700]  [('t_cas_erosiongravel_02_cv', 12)]
river-mid    [  600   300 ..  1600   900]  []
river-south  [ -500   900 ..  2048  2048]  []
town         [ -400  -500 ..   400   100]  [('t_cas_roadmud_01_tungsten_cv', 70),
                                            ('t_cas_road_graveldirt_tungsten_01_cv', 58),
                                            ('t_cas_littlepathcraked_01_cv', 38), ...]
```

70 of the 95 mud records are in the town box. **Zero terrain decals of any kind
overlap the mid or south river.** In fact no decal record on the whole map has
`AabbMax.z > 627`, so the entire southern third of the world — which is where the
braided river is — carries no terrain decal at all.

**HYPOTHESIS.** What reads as "mud at the river" in our build is the terrain
surface itself, not a decal: L10 has no colour texture, so the shader falls back,
and both of the fallbacks available to it are currently wrong (§B and §C below).
The `_MAP_CONTEXT/Roads` reading from a problem marker does not contradict this
and does not localise anything — Roads is one mesh with one surface per material
group, so a hit anywhere on it selects the whole group.

---

## B. Terrain and ground layers

### B1. The palette is 33 layers, and only 8 have a texture

**MEASURED.** `terrain_mp_tungsten.VisualTerrain` (RES `0x1CA38E06`, 632 B) gives
`layerCount = 33`, `SurfaceShaderBlockKey = 0x1E1BF58E3A8AC8B4`, and four linked
layers: **L29, L30, L31, L32 all link to L28**. Every layer's type flag byte is
0. The record ends exactly at EOF.

**MEASURED.** `terrain_mp_tungsten.layergraphslayergraphs` (RES `0xDE540C59`,
1,236 B) declares `recordCount = 33` at +8. The record table starts at **offset
160** — found by TERRAIN.md §9.1's stated rule, that *every* record's
`ShaderBlockKey` must resolve in the paired depot (33/33 at 160). A weaker rule —
"the 33 u64s at +20 are non-zero and distinct" — fires at offset 92 and produces a
table that looks entirely plausible and resolves **zero** keys. The 100%-resolve
requirement is load-bearing, and this probe originally got it wrong.

**MEASURED.** The paired depot
`terrain_mp_tungsten.layergraphs_shaderblockdepot.ShaderBlockDepotResource`
(8,964 B) holds 33 keys over 27 content-deduplicated records; 33 texture
parameters and 233 inline constants across them; 33/33 keys resolve.

Full layer table. `painted` = has a weight page in block 1; `BASE` = `Flags &
0x0100` set, no page. Counts are records over the 645 block-1 nodes.

| L | side | textures bound (slot -> asset) |
|---|---|---|
| 00 | BASE x1830 | none — 6 constants only |
| 01 | painted x58, BASE x20 | none |
| 02 | painted x398 | none |
| 03 | painted x165 | none |
| 04 | painted x669, BASE x25 | none |
| 05 | painted x1696 | none |
| 06 | painted x420 | none |
| 07 | painted x1226 | none |
| 08 | painted x100 | none |
| **09** | BASE x2564 | `t_cas_asphaltedge_01_{cv,nhs,ao,op}` |
| **10** | BASE x2564 | `t_ter_defaulttexture_ao` **only** (slot `0x09293810`) |
| **11** | BASE x2564 | `t_cas_grasstuftspline_01_tungsten_{cv,nhs,ao,op}` |
| 12 | painted x112 | none |
| 13 | painted x1362 | none |
| 14 | painted x1404 | none |
| 15 | painted x107 | none |
| 16 | painted x716 | none |
| 17 | painted x172 | none — 2 constants only |
| 18 | painted x504 | none |
| 19 | painted x220 | none — 2 constants only |
| 20 | painted x1965 | none — 2 constants only |
| 21 | painted x259 | none — 2 constants only |
| 22-27 | painted x23..x67 | **no parameters at all** (empty depot record) |
| **28** | BASE x2564 | `hfd_debug` at slot **`0xAE16A5C0`** — the crater layer |
| **29** | BASE x2564 | `t_wum_ls_gravel_02_a` + `t_wum_ls_gravel_02_b` + `t_wum_crackedconcrete_03` (9 textures, slot sets A+B+C) |
| **30** | BASE x2564 | `t_wum_ls_gravel_01_a_{cv,nhs,ao}` + `t_wum_td_sand_01_ncs` |
| **31** | BASE x2564 | `t_wum_dryrockygravel_{cv,nhs,ao}` + `t_wum_td_sand_01_ncs` |
| **32** | BASE x2564 | `t_wum_concretedebris_01` + `t_wum_concretedebris_02` (6 textures) |

**MEASURED — the split is total. All 24 painted layers bind zero textures; all 8
textured layers are base layers.** This is the same trap
`findings/terrain-materials-are-on-the-base-side` documents on mp_dumbo (30
painted / 2 textured vs 16 base / 11 textured), and on Tungsten it is not a
tendency, it is absolute.

**MEASURED — L29..L32 are the crater materials and L28 is the crater layer.**
L28 is the only layer binding `0xAE16A5C0`, the texture is
`common/shaders/terrain/craters/textures/hfdecalcopy/hfd_debug`, and L29-L32 all
`link` to it. Exactly the structure `findings/terrain-layer-slot-hashes`
describes for mp_dumbo (L42-L45 -> L41 bound to `hfd_debug`), with different
indices.

**So `0xAE16A5C0` is answered: it is the heightfield-decal / crater mask texture
slot.** `docs/GROUND-LAYERS.md` lists it as "a slot hash we do not know … adding
it would gain one texture". It gains one texture because there is exactly one
crater layer per map.

### B2. Where the appearance of the 24 textureless layers comes from

**Unknown, and it is not in the depot.** MEASURED: the complete parameter list of
a typical textureless layer, L00:

```
L00  key=32BDD0EE4E2641FE
     0x4C200FE0  float   -0.010
     0x5707A992  float    0.040    (UV tiling, repeats/m — identified)
     0xCBB9A946  float2  (0.0, 0.0)
     0xCF3F97E0  uintB?   0
     0xE68B2B10  float    1.0
     0xFA13C5B0  float    0.600    (smoothness — identified)
```

Six of the 24 (L22-L27) have **no parameters at all** — an empty depot record,
which is not a parse failure: the record's blob parses and holds zero entries.
Their appearance is entirely inside the compiled layer-graph program.

The three named constants from `GROUND-LAYERS.md`, as far as Tungsten's data can
settle them:

- **`0x4C200FE0`** — MEASURED: `Float32`, present on 20 of 33 layers, values
  observed `-0.040, -0.025, -0.010, 0.0, +0.010`. Small and signed both ways.
  HYPOTHESIS: a height/displacement bias or a blend-edge offset. Not a colour
  (never a triple, never in 0..1 as a group).
- **`0xCF3F97E0`** — MEASURED: **not a float.** Its type hash is `0x34791132`
  (an integer type in `impl/pipeline/shaderblock.py`'s table), and the observed
  values across Tungsten's layers are `0`, `2`, `4` only. `GROUND-LAYERS.md`
  prints it as `[0.0000]` because a reader that assumes `Float32` for every
  4-byte constant reinterprets a small integer as a denormal. HYPOTHESIS: a
  blend-mode / channel-select enum. Its meaning is unknown.
- **`0xCBB9A946`** — MEASURED: type `0x39AB6941` = `Vec2`, and it is **(0.0, 0.0)
  on all 33 Tungsten layers**. A UV pan/offset that this map never uses.
- **`0xAE16A5C0`** — MEASURED: a *texture* slot, not a constant. Crater mask
  (above).

Two more that are common and unidentified, recorded so they are not re-derived:
`0x2F9990B7` (`Float32`, 0.33 .. 1333.5 — the two crater-adjacent layers L20/L21
read 1333.521 and L19 reads 1268.058, which is a different magnitude class from
every other layer) and `0xF7652FB3` (`Float32`, 2.0 .. 45.0).

### B3. Masks and splat streams

**MEASURED.** MP_Tungsten's streaming tree carries seven typed blocks:

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 269, PersistentNodeCount 264
block 0  heights   16,038 B   xs=265, WorldSizeY=1045.0, 269 nodes (5 Packed, 264 External)
block 1  splat  1,139,572 B   LayerSlotCount=6, 645 nodes, 34,355 records
block 2  density    9,668 B   xs=265, 125 nodes (4 Packed, 22 Empty, 99 External)
block 4  mask       4,365 B
block 5  mask       2,829 B
block 7  material 3,291,743 B dim=256, 229 nodes declared, levelMax=4, 14 pairs
block 8  mask       283,804 B dim=265, 97 nodes, levelMax=4, maskUnknown0=4
```

`LayerSlotCount` is **6** on Tungsten against 62 on dumbo/aftermath/eastwood —
MEASURED, meaning unknown, and note it is emphatically *not* the layer count (33).

The splat's per-layer record split, from the `Flags & 0x0100` bit at record
offset **+20** (not +18 — the record is `u16 LayerIndex, u16 LayerId, f32x4
bounds, u16 Flags, u8[11] Presence` = 33 bytes):

```
painted (weight page): L01 L02 L03 L04 L05 L06 L07 L08 L12 L13 L14 L15 L16 L17
                       L18 L19 L20 L21 L22 L23 L24 L25 L26 L27      (24 layers)
base (no page):        L00 L01 L04 L09 L10 L11 L28 L29 L30 L31 L32  (11 layers)
```

L09, L10, L11, L28, L29, L30, L31, L32 appear as a base record in **all 2,564**
node-records that carry base entries — a map-global base palette. L00 in 1,830.

### B4. Block 7 — the material raster, decoded

**MEASURED.** Footer: `pairCount = 14`, `BackgroundMaterialIndex = 0x0660FA80`
(a real pair, not the `0x00000080` "no background" sentinel dumbo and eastwood
use). Pairs, and their resolution through TERRAIN.md §8's lists:

```
list 0 (all layers)     [0..32]
list 1 (base, no page)  [0, 1, 4, 9, 10, 11, 28, 29, 30, 31, 32]
list 2 (linked)         [29, 30, 31, 32]

pair  0 0x06610280  list1 lo 2  -> L04        pair  7 0x0660FB80  list0 lo 11 -> L11
pair  1 0x0660FE80  list0 lo 14 -> L14        pair  8 0x06615180  list1 lo 1  -> L01
pair  2 0x0660E280  list0 lo 2  -> L02        pair  9 0x06615280  list1 lo 2  -> L04
pair  3 0x0670E280  list0 lo 2  -> L02        pair 10 0x0660FA80  list0 lo 10 -> L10
pair  4 0x06615080  list1 lo 0  -> L00        pair 11 0x06601F80  list0 lo 15 (none), hi 1 -> L01
pair  5 0x06610380  list1 lo 3  -> L09        pair 12 0x00000000  unused
pair  6 0x06623180  list2 lo 1  -> L30        pair 13 0x00000000  unused
background 0x0660FA80 -> L10
```

Pair 6 (`X = 0x31`, list 2) resolving to the `wum_ls_gravel` family reproduces
TERRAIN.md §8's cross-map observation ("X=0x31 → shared wum_ls_gravel family on
dumbo AND tungsten") independently.

**MEASURED — texel share of the resolved base field, pooled over all tree levels:**

```
L02  27.5%   textureless
L04  16.9%   textureless
L00  15.6%   textureless
L09  10.4%   t_cas_asphaltedge_01     <- the road network
L30   9.8%   t_wum_ls_gravel_01_a
L10   7.4%   default AO only          <- the river channels
L14   7.2%   textureless
L01   4.7%   textureless
L11   0.4%   t_cas_grasstuftspline_01_tungsten
```

**So even with block 7 fully implemented — which the plugin already does
(`bf6_materialtree.gd`) — only 20.6% of MP_Tungsten's ground resolves to a layer
that has an albedo to sample** (L09 + L30 + L11). L10's 7.4% has an AO map and no
colour, and the remaining 72% is on shader-computed layers. That is the honest
ceiling for this map with the data we can read, and it is the real reason the
terrain looks flat — separate from, and additional to, the decode bug in §C.

The rasterised base field is a recognisable picture of the map (field parcels,
town, road network, braided river), which is what makes the L10-is-the-river
identification safe: it is a spatial match against the SDK's own overhead image,
not a guess from a name.

---

## C. The colour map — the decode bug, found

`docs/GROUND-LAYERS.md` records that MP_Tungsten's colour map decodes to cyan
`(0.119, 0.735, 0.676)` against the SDK overhead's warm `(0.520, 0.473, 0.356)`,
that a red/blue swap moved it the wrong way, and concludes "structure surviving
while colour scrambles is what a **wrong block codec** looks like", with tile size
4,624 bytes = 68x68.

**MEASURED — the codec is right and the tile POSITION is wrong. There are two
tiles per node on this map and the plugin reads the second one.**

### C1. Tungsten's chunk layout

Every one of MP_Tungsten's 471 streaming chunks (269 primary + 202 paired)
decomposes **exactly, with zero residual**, as

```
size = k x 149,297      (height-block payloads, xs = 265)
     + storedPages x 4,356   (raw 66x66 weight pages)
     + 34,848                (the trailer)
```

and for 264 of the 269 primary chunks that trailer is exactly `8 x 4356`, i.e.
**34,848 bytes = 2,178 sixteen-byte blocks = 2 x 1,089 = two tiles of 33x33
blocks = two 132 x 132 BC7 tiles (17,424 bytes each)**. The remaining 5 primary
chunks have no heights and no trailer.

### C2. Which of the two is the colour map

BC7's mode is unary in the low bits of byte 0. Over all 269 primary chunks:

```
first  17,424-byte tile:  292,941 blocks,  98.16% in modes 4-7,
                          1,089 distinct blocks per tile in 252 of 269 nodes
second 17,424-byte tile:  292,941 blocks,   4.19% in modes 4-7 (90.6% mode 3),
                          ONE distinct block repeated 1,089 times in 187 of 269 nodes
```

The first tile is real BC7 image data. The second is a degenerate/uniform tile.

**MEASURED — the first tile's mean colour matches the SDK's overhead image.**
Decoding BC7 mode-6 endpoints only (`probe_tung_bc7mode6.py`; mode 6 is 89.6% of
the first tile's blocks, one subset, two RGBA endpoints, so the endpoint midpoint
estimates a block's mean):

```
first tile  262,478 mode-6 blocks   mean RGBA (0.497, 0.464, 0.339, 0.002)
  by depth 2 (0.444, 0.409, 0.304)  3 (0.445, 0.410, 0.305)
           4 (0.488, 0.458, 0.334)  5 (0.551, 0.516, 0.375)
second tile  11,955 mode-6 blocks   mean RGBA (0.584, 0.911, 0.477, 0.979)
```

`MP_Tungsten.jpg` averages **(0.520, 0.473, 0.356)**. The first tile is within
about 0.02 per channel, with no channel swap. **The colour map is BC7, it is
correct, and it is the FIRST of the two tiles.** The red/blue-swap experiment
recorded in `GROUND-LAYERS.md` was chasing a fault that is not there.

**MEASURED — the control.** mp_dumbo's chunks end with a *single* 4,624-byte
tile: at depth >= 2 the last 4,624 bytes are 100% modes 4-7, and the 4,624 bytes
before them are not.

**Unknown.** What the second tile is. Its alpha is ~0.98 where the colour map's
is ~0.002, and it is uniform on 70% of nodes. It is a legitimately BC7-compressed
raster; nothing identifies which `RasterType` it carries.

### C3. The plugin picks the wrong page size and the wrong tile — on 9 of 16 maps

`addons/highpoly_toggle/bf6_splat.gd::detect_layout` scores each
`(page_size, tile_bytes)` pair by counting nodes where
`primary_size - tile_bytes - pages * page_size >= 0`. That test is satisfied by
almost every combination whenever the trailer is large, and the tie check it
computes (`ties`) **is never read** — only `if best <= 0` can fail.

**MEASURED — simulating that exact scoring:**

```
mp_tungsten  picks (page 2592, tile 4624)  score 269   tied with (2592, 17424) at 269
mp_dumbo     picks (page 2592, tile 4624)  score 272   next best 100  (decisive, correct)
```

Tungsten's true page size is **4,356** and its true tile size is **17,424**, with
two tiles. Both picks are wrong. The consequences follow mechanically:

- `node_pages()` slices at `data.size() - tile_bytes - n_pages * page_size`. With
  the wrong page size and the wrong tile size this lands inside the trailing
  tiles, so **the weight pages the splat composites are colour-tile bytes**, then
  BC4-decoded because `page_size == 2592` selects the BC4 codec.
- `color_tiles()` slices `data.slice(size - tile_bytes, size)` — the last 4,624
  bytes — which on Tungsten is the tail of the **second** tile, the uniform one.
  `assemble_colors()` then hands that to `Image.FORMAT_BPTC_RGBA`. That is the
  cyan.

**MEASURED — this is not Tungsten-specific.** Running the same simulation over
every map with a streaming tree, and determining each map's true page size by the
exact-decomposition method, `detect_layout` picks `page 2592 / tile 4624` on
**all 16 maps**, while the true page size is:

```
page 2592: aftermath, contaminated, dumbo, eastwood, golmudrailway, isolated, subsurface
page 4356: abbasid, badlands, battery, capstone, firestorm, limestone, outskirts, tungsten
page 5184: plaza
```

**That split matches, map for map, the independently derived table in
`BF6_Frostbite_Research/impl/pipeline/bf6_splat.py`** (8/8 on the 4,356 set, 6/6
on the named 2,592 set, plaza 1/1 on 5,184) — two methods, same answer. So the
plugin decodes weight pages with the wrong codec on **nine of sixteen maps**, and
reads the colour tile from the wrong place on every map whose trailer is not a
single 4,624-byte tile.

---

## D. Decals, roads and paths

**MEASURED.** `decals.TerrainDecals` is 5,479,892 bytes and holds:

```
slotCount   33  (29 empty, 4 carry a GUID)     <- equals the terrain layerCount
recordCount 613, all 613 parsed, 0 chain breaks
asset slots used: 9 (599 records, 47,391 tris) and 10 (14 records, 398 tris)
21 distinct texture-set groups over the 613 records
```

The slot table has one entry per terrain layer, and only slots 9 and 10 are used
— the same two indices as the textured base layers L09 (`asphaltedge`) and L10
(the river/background material). The *material* discriminator is not the slot but
the per-record property stream, which is where the 21 groups come from. The four
texture slot hashes of TERRAIN.md §10.3 (`_cv`, `_nhs`, `_ao`, `_op`) resolve
100% of the bindings; no other slot appears.

The eight largest groups, all `common/environment/asia/centralasia/terraindecalssplines/…`
unless noted:

| recs | basecolor |
|---|---|
| 149 | `tungsten/road_graveldirt_tungsten_01/t_cas_road_graveldirt_tungsten_01_cv` |
| 99 | `erosiongravel_02/t_cas_erosiongravel_02_cv` |
| 95 | `tungsten/road_mud_tungsten_01/t_cas_roadmud_01_tungsten_cv` |
| 50 | `tiretracks_01/t_cas_tiretracks_01_cv` |
| 46 | `littlepathcraked_01/t_cas_littlepathcraked_01_cv` |
| 38 | `tungsten/road_tiretracks_tungsten_01/t_cas_tiretracks_tungsten_02_cv` |
| 23 | `tungsten/road_graveldirt_tungsten_03/t_cas_road_graveldirt_tungsten_03_cv` |
| 22 | `littlepathpebbles_01/t_cas_littlepathpebbles_01_cv` |

The 149 / 99 / 95 / 50 counts reproduce `docs/GROUND-LAYERS.md`'s table exactly
from an independent parse, which is a useful cross-check on both.

Two groups are worth flagging:

- **14 records bind only `_op`**, to `roadvariationmask_01/t_cas_roadvariationmask_01_rgb`
  — a mask with no colour at all. A consumer that treats "no basecolor" as a
  resolution failure will mis-classify these; they are the same class as the
  puddle decal in `findings/water-and-decal-reader-gotchas`.
- Several groups **mix libraries**: the mud group takes `_cv/_ao/_op` from
  `tungsten/road_mud_tungsten_01` and its `_nhs` from the shared `roadmud_01`.
  Two groups pull from `africa/northafrica/…` with a `_tungsten` basecolor over
  shared normals. Grouping by any single slot merges or splits materials wrongly;
  group by the whole texture set.

**MEASURED — decal coverage is bounded.** Over all 613 records, `AabbMin.z` is
-1,543 and `AabbMax.z` is 627, against a world spanning -2,048..2,048. The whole
southern band `z > 627` — roughly a third of the map, and where the river is —
has no terrain decal. Decal Y spans 47.2 to 97.8 (the AABB minimum sits below the
terrain floor of 64.77, which is expected for AABBs on draped, Y-less decal
vertices; TERRAIN.md §10.4 notes the vertex format stores X and Z only).

---

## E. Everything else notable about the map

**MEASURED — structure.** 292 `LayerData` partitions, of which **171 declare zero
Objects**. The busiest are `loot_layer` (502), `_layers_content/fx_global` (230),
`_layers_world/crater_backdrop` (188), `_layers_gameplay/escalation/mp_escalation0`
(111), `_layers_content/lighting` (111), `_layers_gameplay/conquest0` (101). The
world content is in nine `_layers_world/area_00N.ebx` subworlds (368 KB – 1.13 MB
each) plus `backdrop_001.ebx` (637 KB), each with its own
`staticmodelgroup.physics.PhysicsResource` (3.3 – 8.2 MB) and its own
`meshvariationdb_win32.ebx`.

**MEASURED — 37 ShaderBlockDepots under the level**, the largest being
`_layers_gameplay/portal_gameplay_win32_shaderstate/…` (8.2 MB) and
`mp_tungsten_win32_shaderstate/…` (5.7 MB); each `area_00N` has its own. Several
gameplay modes share a depot byte-for-byte (breakthrough / strikepoint / rush /
squaddeathmatch all use `shaderblockdepot_14169225245257695775`).

**MEASURED — Tungsten hosts the Granite battle-royale content.**
`granitebr.ebx` (131 KB), `graniteloot.ebx` (141 KB), `granitemissions.ebx`,
`granitebr_extraction`, `granitebr_insertion`, `granitebr_ziplines`,
`granitesolo0/duo0/trio0/squad0` and `loot_layer.ebx` (91 KB, 502 objects) all sit
inside `levels/mp_tungsten/`. Anything that walks "the level" gets BR content
mixed in with the MP layers.

**MEASURED — the biggest files are lighting, not geometry.**
`lighting/enlighten_mp_tungsten_highend.EnlightenDatabase` is 136.8 MB and the
lowend twin 38.6 MB; `mp_tungsten/materialgrid_win32.ebx` is 15.9 MB. Nothing in
the plugin reads any of them.

**MEASURED — height quantisation is coarser here.** `WorldSizeY = 1045.0` against
256.0 on dumbo and aftermath and 518.0 on eastwood, so one u16 step is 1.59 cm on
Tungsten against 0.39 cm on dumbo. Relevant to any terrain-normal or slope
computation tuned on dumbo.

**MEASURED — Tungsten ships blocks 2 and 5 (density + second mask), dumbo and
aftermath do not.** Block 2 is a heightfield-format tree with 125 nodes,
`WorldSizeY` identical to block 0 and a root Y range of 64.006..76.523.

---

## F. What generalises, and what this contradicts

| finding | scope | what it explains / contradicts |
|---|---|---|
| `detect_layout` scores permissively and its tie check is dead code; it picks `(2592, 4624)` on all 16 maps while 9 have a different true page size | **every map** | The primary cause of bad ground on Tungsten and, by the same mechanism, on abbasid, badlands, battery, capstone, firestorm, limestone, outskirts and plaza. Contradicts the implicit assumption that a permissive fit plus "best score wins" identifies the codec. |
| A node's colour tile is not always the last thing in its chunk — Tungsten has **two** 17,424-byte tiles and the colour map is the first | **at least Tungsten**, screening suggests battery / firestorm / limestone / plaza too | Explains the cyan colour map completely. Contradicts `GROUND-LAYERS.md`'s "wrong block codec" conclusion and its "4,624 bytes = 68x68" tile size for this map. |
| The colour map IS BC7 and needs no channel swap; the first tile's mean is (0.497, 0.464, 0.339) against the SDK image's (0.520, 0.473, 0.356) | every map | Retires the red/blue-swap line of investigation. |
| Terrain materials live on the **base** (no-weight-page) side; on Tungsten *all* 24 painted layers are textureless and *all* 8 textured layers are base | **every map**, absolute here, 11-of-16 on dumbo | Already implemented (`bf6_materialtree.gd`); confirms it must never be treated as optional. |
| Even with block 7 correct, only 20.6% of Tungsten's ground resolves to a layer with an albedo | Tungsten-specific magnitude, general shape | Sets the honest ceiling. Fixing the codec will not make this map look painted; it will make it look like a correct colour map with roads and gravel on top. |
| `0xAE16A5C0` is the crater / heightfield-decal texture slot, bound by exactly one layer per map (Tungsten L28, dumbo L41) | **every map** | Answers an open item in `GROUND-LAYERS.md`; worth +1 texture per map and correct crater rendering. |
| `0xCF3F97E0` is an integer type (`0x34791132`), values 0/2/4 — not a float | **every map** | `GROUND-LAYERS.md` prints it as `0.0000`; any reader that assumes `Float32` for 4-byte constants is silently wrong here. |
| `WaterSurfaceEntityData +0x90` is `QueryBoxHalfExtent`, not `TileOffset`; `TileOffset` (+0xB0) is (0,0,0) on every map checked; instance size is 0x280 not 0x260 | **every map** | Corrects `formats/TERRAIN.md` §11 and `findings/water-surface-geometry-…`. A name-keyed reader gets zero extent and draws nothing. |
| Water renders where the entity's y is above the terrain floor and not where it is below; Tungsten (-64.8 m) and eastwood (-171.7 m) are buried | **every map** | Replaces "the river is missing" with "the water surface is authored underground"; gives a one-line diagnostic. |
| The empty `ent=1 arch=1 seg=1 edits=0 comps=[26]` ECS prefab is boilerplate emitted for *every* layer, including layers that also ship full content | **every map** | Contradicts `GROUND-LAYERS.md`'s "the river is assembled at runtime by ECS". 171 of Tungsten's 292 layers are simply empty; the river is one of them. Nothing is waiting at runtime to be found. |
| A level's terrain directory is not consistently named (`terrain_mp_tungsten` vs `mp_dumbo_terrain`) | **every map** | Anything that builds that path from the level name works on some maps and silently finds nothing on others. |
| The layer-graph record table must be located by "all keys resolve in the depot", never by "keys look distinct" | **every map** | A wrong-but-plausible table exists 68 bytes earlier on Tungsten. |

---

## G. Next steps, in priority order

1. **Fix `detect_layout` in `addons/highpoly_toggle/bf6_splat.gd`.** Replace the
   `rest >= 0` score with the exact decomposition: require
   `primary_size - heightPrefix - pages * page_size` to be a non-negative
   multiple of a candidate tile size, over the prefix set
   `{0, 39919, 149297, 189216}`, and require the winner to be unique. Then make
   the `ties` counter actually fail the detection instead of being computed and
   discarded. This is the highest-value change in the whole document: it is wrong
   on nine of sixteen maps today. Verification: the detected page size must come
   out `4356` for tungsten/abbasid/badlands/battery/capstone/firestorm/limestone/
   outskirts, `5184` for plaza, `2592` for the rest.

2. **Support more than one tile per node, and stop assuming the colour tile is
   last** — `bf6_splat.gd::color_tiles` and `node_pages`. Count the trailer's
   tiles (`trailer / tile_bytes`) and take the **first**; validate the choice with
   the BC7 mode test (a real colour tile is ~98% modes 4-7, a degenerate one is
   not). Verification: Tungsten's assembled colour map must average near
   `(0.50, 0.46, 0.34)`, not cyan.

3. **Turn the colour map on, once 1 and 2 are done** — `MapContext.colormap_enabled`
   in `addons/highpoly_toggle/highpoly_mapcontext.gd` has never been set by
   anything. On this map it is the single largest source of real colour: 72% of
   the ground has no layer albedo at all. Do it *after* the two fixes above and
   verify `use_colormap`, `cmap_bounds` and `cmap_strength` separately, per
   `GROUND-LAYERS.md`'s own warning.

4. **Add slot `0xAE16A5C0` to the terrain layer slot table** —
   `addons/highpoly_toggle/bf6_terrainlayers.gd`. One texture per map, and it is
   the crater layer that L29-L32 link to.

5. **Diagnose water by comparing its Y against the terrain floor** —
   `addons/highpoly_toggle/highpoly_gamesource.gd::water()`. When
   `height < terrain_min_y`, say so in the log line
   ("water surface at y 0.0 is 64.8 m below the lowest ground — not drawn")
   instead of silently building an invisible plane. Cheap, and it converts a
   mystery into a fact for every map.

6. **Handle a level with more than one water surface** —
   `highpoly_gamesource.gd::_water_partition()` returns the first partition
   containing the type and stops. Tungsten has exactly one so it is not bitten
   here, but the function's own comment claims "the entity is always somewhere;
   only its partition varies", and that is an assumption, not a measurement.

7. **Do not read `TileOffset`** anywhere, and if the raw-offset water read is ever
   replaced by a field-name read, use `QueryBoxHalfExtent`. Note this in
   `highpoly_gamesource.gd`'s comment block, which currently repeats the
   `TileOffset at +0x90` error from `TERRAIN.md`.

8. **Correct `docs/GROUND-LAYERS.md`** — the river/ECS paragraph, the 4,624-byte
   tile size, the "wrong block codec" conclusion, and the `0xAE16A5C0` /
   `0xCF3F97E0` entries. Leave the record of what was tried; replace the
   conclusions.

9. **Push three corrections upstream to `BF6_Frostbite_Research`** —
   `formats/TERRAIN.md` §5.3 (a node's trailer can hold more than one tile, and
   the colour map is not always last), §11 (`+0x90` is `QueryBoxHalfExtent`,
   instance size 0x280), and
   `findings/water-surface-geometry-from-transform-and-tileoffset` (the field
   identification). Each is a one-line fix that another consumer would otherwise
   repeat.

---

## UPDATE (2026-08-10) — the river IS shipped: streaming-tree block 2 is a water-surface heightfield

Ground truth from the game: MP_Tungsten's braided river renders as REAL water
in retail. Section A above concluded the level ships no river water geometry.
The game was right and the study's negative had a hole. The mechanism is found,
measured, and cross-validated on a second map. New probes:

```
tools/probe_tungwater_refs.py     reverse-import chain + parent transforms of
                                  any partition (suspect 1)
tools/probe_tungwater_block2.py   block-2 payload decode, water-vs-ground
                                  tests, depth/level PNG + ASCII renders
```

### U1. The mechanism

**MEASURED — terrain streaming-tree BLOCK 2 is a second, absolute-Y
heightfield: the WATER SURFACE.** Decoded with the same u16 codec as block 0
(`y = u16/65536 * WorldSizeY`, same xs=265 grid, same 4-sample border), its
quadtree carries 125 nodes (99 External, 22 Empty, 4 Packed) and decodes to a
braided channel network:

- **T1 — the values are heights.** All 99 External payloads decode with every
  interior sample inside the node's own stored AABB Y band (99 ok / 0 bad).
  A density/mask interpretation cannot produce that.
- **T2 — the water sits ON the ground.** Against block 0 in the same chunk,
  13.28% of samples are above ground (>2 cm); per-node max depth peaks at
  **5.85 m**; median wet depth ~3 m.
- **T3 — the wet mask IS the river.** Rasterised (water > ground), the mask
  reproduces the wet channels of the SDK overhead `MP_Tungsten.jpg`
  one-for-one — the braided network entering at the east edge, looping through
  the south-centre, exiting west (`probe_tungwater_block2.py --png`).
- **T4 — the surface falls downstream, monotonically.** Mean water level by
  256-m x-band: 76.36 m at x -2048 falling to 66.87 m at x +2048, no
  inversions.

**The river's numbers (MEASURED):** water level **66.05..76.52 m** (p5 67.47,
median 69.98, p95 75.58), wet extent **x -2048..2048, z -424..1254**, wet area
**0.82 km²** (4.9% of the world square). The dry remainder of the grid holds a
constant **64.006 m** — 0.77 m below the terrain floor of 64.771, i.e. the
water surface exists everywhere and is simply authored underground wherever
there is no river. Block 2's "root Y 64.006..76.523" in §E was this all along.

### U2. Where the study's negative had its hole

Section A scanned entity types, layers, decals and ECS prefabs — all EBX-side.
The water is not EBX; it is a **terrain resource plane**, and TERRAIN.md had
labelled block 2 "Density / DetailDisplacement" from an engine binder slot
name (slot 1 `DensityMap`), so no water-side search ever looked at it. The A3
water-height table ("entity y below floor = buried = no water") is correct for
the ENTITY but wrong as a verdict on the MAP: on block-2 maps the entity's
transform Y is irrelevant to where water renders.

**HYPOTHESIS (mechanism join, not traced in the exe):** the full-map
`WaterSurfaceEntityData` (§A1: 4,096 m basis, QueryBoxHalfExtent covering the
whole world, MaterialPair 0x06D03489, depot StateKey 0x109C22DA5F67CF7A) is the
render entity — material, foam, interaction — and the runtime displaces its
surface per-texel from block 2. Under this reading the full-map query box and
the y=0 transform are exactly right for a terrain-conforming surface, and A1's
"untouched default entity" hypothesis is retired.

### U3. Chunk-layout correction (affects every reader of block-2 maps)

**MEASURED — the chunk order is `[block-0][weight pages][block-2][colour
tiles]`, not "height payloads followed by pages".** Found structurally: the
bytes at +149,297 have 66-byte-stride u8 smoothness (weight pages are raw
66x66), and the row-major u16 heightfield begins exactly at
`149,297 + pages*4,356`, ending `2 x 17,424` before the chunk end where tiles
exist. Exactly **99 primary chunks decompose with two payloads = the 99
External block-2 nodes**, key-for-key. TERRAIN.md's chunk-composition section
("payload(s) — block 0 and, where present, block 2 — followed by the splat
pages") states the wrong order; the study's §C1 decomposition proved only the
size multiset. Consequence for any consumer that slices pages from the chunk
END (the plugin's `node_pages()` pattern): on tungsten/eastwood/isolated a
back-slice lands on the block-2 payload, not the pages — pages must be sliced
forward from +149,297. Note `2*17,424 = 8*4,356`, so tile-vs-page ambiguity is
real; resolve the block-2 offset by the in-AABB-band test
(`probe_tungwater_block2.py` does; dry texels hold the band floor, so a correct
slice is ~100% in-band).

### U4. Cross-validation on mp_eastwood — block 2 equals LakeData, rasterised

**MEASURED.** Eastwood's block 2 (23 External nodes, dry-fill exactly
**50.00 m**) decodes 23 ok / 0 bad, and its wet plateaus sit at **215.88,
221.70, 225.09, 230.51, 234.49, 237.59** — the authored LakeData water levels
of MAP-EASTWOOD.md §A2 (215.89..237.28) to the centimetre, at the lakes'
positions (e.g. node 0x32003, x 0..256 / z 256..512, level 225.09 = the
fountain pond at y 225.10). Since eastwood's water ENTITY sits at y 3.08,
block-2 values are **absolute world Y**, not offsets from the entity. LakeData
is the authoring form; block 2 is the shipped, rasterised render form. The
same holds for tungsten's river: the empty `river`/`riversplines_backdrop`
layers and ECS stubs of §A2 are the authoring records, and block 2 is where
their content was baked — the §A2 bake hypothesis, now with the bake found.

### U5. Fleet census

**MEASURED** (block presence over every level with a streaming tree):

| level | blocks | block-2 root Y | the map's water |
|---|---|---|---|
| mp_tungsten | 0,1,**2**,4,**5**,7,8 | 64.01..76.52 | braided river (this doc) |
| mp_eastwood | 0,1,**2**,4,**5**,7,8 | 50.00..237.59 | 20 LakeData ponds/pools |
| mp_isolated | 0,1,**2**,4,**5**,7,8,**10** | 100.49..109.12 | its river (untested here) |
| all 13 others | 0,1,4,7,8 | — | flat entity plane, vista mesh, or none |

Block 2 ships on exactly the three maps whose water must follow a varying
level, and block 5 co-occurs with it 3-for-3. TERRAIN.md's "8k maps
(mp_tungsten, mp_eastwood, mp_granite) add 2 and 5" is wrong on membership:
**mp_isolated ships both** (and an undocumented block 10, content unknown), and
the correlate is not resolution but terrain-conforming water.
**HYPOTHESIS:** block 5 (the "twin" coverage mask) is the water-coverage mask
for block 2. Untested.

### U6. What this changes in section A and the F table

- A1's "Unknown: whether the game renders any true water surface on
  MP_Tungsten" — **answered: yes, the river**, from block 2.
- A1's HYPOTHESIS "L10 is the water/wet terrain material" stands, refined:
  **L10 is the river BED; block 2 is the river SURFACE.** Two different
  things at the same place.
- A3 / F-table row "water renders where the entity's y is above the terrain
  floor" — **demoted from diagnostic to half-truth**: it holds only on maps
  without block 2. The one-line diagnostic must become: entity-y test, THEN
  block-2 presence test, THEN (per MAP-BATTERY.md) vista-mesh search.
- §E's "Tungsten ships blocks 2 and 5 … Block 2 is a heightfield-format tree
  … root Y range 64.006..76.523" was the river's water surface, unrecognised.

### U7. The suspects that died, with their measurements

1. **Parent transform — NO.** (`probe_tungwater_refs.py`) The water partition
   `a0873001-e1eb-4532-b8ef-8a852f95a592` is referenced by exactly one
   partition in the level, `_layers_content/content.ebx`, instance [2]
   `LayerReferenceObjectData`, whose `BlueprintTransform` is IDENTITY with
   translation (0, 0, 0); nothing under the level imports content.ebx itself.
   There is no parent translation to lift the y=0 plane.
2. **A placed water/river mesh — NO.** A filename sweep of the level tree
   finds no `*water*`/`*river*`/`*creek*`/`*ocean*`/`*lake*`/`*stream*` mesh
   partition beyond the empty `WaterAsset` of §A1 (the hits are the known
   empty layers, prefab `pf_waterstationrural_01` — a building — and the
   shader-state lookup table).
3. **LakeData — NO** on tungsten (§A2's type-GUID byte scan over the level
   tree, unchanged).
4. **Simulation/VE placement — NO.** `WaterOceanSimulationEntityData`
   (water_shared_schematic.ebx) holds only `Resolution 64 / TileDimension
   24.0 / PhysicsSimulationEnabled false` — wave-sim parameters, no geometry,
   no height; the schematic around it is player_hub channel plumbing. The VE
   `OceanComponentData` remains shading-only (MAP-BATTERY.md A1).
5. **QueryBoxHalfExtent tiling — resolved by U2**: the full-map box is the
   correct authoring for a full-map terrain-conforming surface, not a tile
   generator.

### U8. Actions for the plugin, in priority order

1. **Render block-2 water** (`highpoly_gamesource.gd::water()` +
   `bf6_splat.gd`-side chunk access): when the streaming tree carries block 2,
   walk it with the existing block-0 heightfield walker, take each External
   node's payload at `chunk_len - trailer - 149,297` (validate by the
   in-AABB-band test), and mesh the surface where `block2 > block0` (+2 cm),
   using the material the existing water path already joins from the entity's
   depot StateKey. Verification numbers: level 66.05..76.52 m, wet area
   0.82 km², the T3 raster.
2. **Fix end-relative page slicing on block-2 maps** (`bf6_splat.gd::
   node_pages()` / the rewritten detect_layout): pages start at +149,297
   always; on the 99 two-payload chunks a back-slice reads the water
   heightfield as pages. Applies to eastwood and isolated too.
3. **Water diagnostic ladder** (G5 revision): "entity y 0.0 is 64.8 m below
   ground" AND "block 2 present: terrain-conforming water, level
   66.1..76.5 m" — never conclude dry from the entity alone.
4. **Eastwood lakes for free**: action 1 renders eastwood's ponds without a
   LakeData triangulator (MAP-EASTWOOD.md G2 alternative) — block 2 already
   carries them rasterised, dry-fill 50 m.
5. **Check mp_isolated** with `probe_tungwater_block2.py mp_isolated` when it
   gets its map study (block-2 root Y 100.49..109.12 says its river is there).
6. **Upstream to TERRAIN.md**: (a) block 2 is the water-surface heightfield
   (absolute world Y; the "Density" binder-slot label is at minimum
   misleading); (b) chunk internal order `[block0][pages][block2][tiles]`;
   (c) the 8k-maps claim -> the three-map census of U5 (+ isolated's
   block 10); (d) the block-5 co-occurrence note.
