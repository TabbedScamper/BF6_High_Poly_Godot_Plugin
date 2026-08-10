# MP_Badlands, end to end

Companion to `MAP-TUNGSTEN.md`, produced by applying its laws to MP_Badlands and
measuring where they hold and where they break. **Every claim is tagged MEASURED
or HYPOTHESIS**; a MEASURED claim names the resource/value and the probe that
reproduces it. Probes are read-only against the 2026-08-01 pull via
`bf6_paths.py`.

```
tools/probe_badlands_decomp.py       chunk decomposition + BC7 mode census (new)
tools/probe_badlands_colorrender.py  full BC7 colour-map assembly -> PNG (new)
tools/probe_badlands_decals.py       TerrainDecals with the badlands framing (new)
tools/probe_badlands_scatter.py      MeshScatteringTypes census, all levels (new)
tools/probe_tung_{terrain,layers,colormap,water,ecs,types,structure,basefield}.py
                                     reused unchanged with level=mp_badlands
```

---

## 0. The map in one paragraph

**MEASURED.** MP_Badlands is a 4,096 x 4,096 m world (block 0 root AABB
`x,z ∈ [-2048, 2048]`), ground from **y = 17.85 to y = 266.41**,
`WorldSizeY = 281.0`, 265 samples per heightfield node, **169 streaming nodes**
(5 Packed, 164 External). Its terrain palette is **46 layers, of which 29 bind
at least one texture** — including most of the painted ones. It carries 628
terrain-decal records in 44 texture-set groups, **no water entity of any kind**,
30 ShaderBlockDepots, 172 `LayerData` partitions of which 86 declare zero
Objects, and 29 `EcsRuntimePrefabAsset` partitions of which **one is populated**
(1,429 entities). The setting is US west-mountain chaparral: eroded canyon
country in the north and east, flat shrub plain with dirt roads, an airfield
strip, oil fields and a scrapyard in the south.

---

## A. Water

### A1. There is no water on this map — not buried, absent

**MEASURED.** `probe_tung_types.py mp_badlands --find "water|ocean|river"` scans
all 1,068 partitions under the level and matches **zero**. No
`WaterSurfaceEntityData`, no `WaterAsset`, no `WaterOceanSimulationEntityData`,
no `OceanComponentData`. This extends the Tungsten table:

| level | water y | terrain min y | water is |
|---|---|---|---|
| mp_aftermath | 49.70 | 0.11 | 49.6 m above floor (renders) |
| mp_tungsten | 0.00 | 64.77 | 64.8 m below floor (buried) |
| **mp_badlands** | **no entity** | 17.85 | **absent** |

So the water diagnostic needs three states, not two: above floor / below floor /
**no entity at all**. `_layers_content/water.ebx` exists but is a 416-byte
`LayerData` with `Objects = []`; `water_shared_schematic.ebx` holds only
schematic plumbing (MathOp/SchematicChannel/PropertyCast entities), no surface.

**MEASURED — what "water" the map does have is terrain-side.** Ground layer
**L39** is a map-global base layer binding exactly one texture,
`westuscoastal/terrain/terraindecals/waterpuddles_01/wum_waterpuddles_01_rgb`,
and the single largest decal texture group is 77 records of
`wum_waterpuddles_02_rgb` bound as `_op` only (§C). Badlands' water is puddles.

**Consequence for the plugin.** `highpoly_gamesource.gd::_water_partition()`
finds no partition here; whatever it does on a null result is the behaviour on
this map. The correct log line is "no water entity in level", distinct from
Tungsten's "authored 64.8 m underground".

### A2. ECS prefabs — 28 empty stubs and ONE populated

**MEASURED.** `probe_tung_ecs.py mp_badlands`: 29 prefabs, 28 x the boilerplate
`ent=1 arch=1 seg=1 edits=0 comps=[26]`, and one populated:

```
generated/ag_splinesfrommaskprefabasset_fc0b67ac_ecsprefab.ebx   887,218 B
    ent=1429  arch=3  seg=6  edits=2667  comps=[0, 50, 62, 66]
```

Same component profile family as dumbo/aftermath's populated prefabs
(MAP-TUNGSTEN §A2 control). "Splines-from-mask" + the empty
`_layers_world/generated/ag_procfences_output.ebx` layer beside it makes
**HYPOTHESIS:** these 1,429 entities are the procedural fence/spline props. A
placement walk that skips `EcsRuntimePrefabAsset` misses real geometry on this
map — badlands is a counterexample to "the ECS layer never matters", while
confirming that the *empty stub* is boilerplate (28 of 29 here).

---

## B. Terrain and ground layers

### B1. The palette is 46 layers — and the painted/textured split does NOT hold

**MEASURED.** `mp_badlands_terrain.VisualTerrain` (697 B): `layerCount = 46`,
`SurfaceShaderBlockKey 0x8A5516FF62EB584E`, links **L02→L01, L05→L04,
L41..L45→L40**. `layergraphslayergraphs` (1,704 B): `recordCount = 46`, record
table at **offset 212** with 46/46 keys resolving in the depot (8,262 B, 46 keys
over 37 records, 131 texture params, 307 constants). A decoy table that "looks
plausible" fires at offset 144 — **68 bytes earlier, the same trap and the same
delta as Tungsten (160 vs 92)**. The 100%-depot-resolve rule is load-bearing
here too.

**MEASURED — the headline difference from Tungsten:** on badlands **the painted
layers are textured**. Splat split (record flag bit8 at +20, `probe_tung_terrain`):
31 painted layers, 16 base layers (L01 appears on both sides, 163 painted /
753 base records; base set = L00,L01,L02,L05,L16..L20,L39..L45 at 916 nodes
map-global). Texture binding per layer (`probe_tung_layers`, condensed —
tiling = `0x5707A992` repeats/m):

| L | side | binds | tiling |
|---|---|---|---|
| 00 | BASE | wum_chap_gravelgrass_01_b_1 (cv/ao/nhs) | 0.125 |
| 01 | painted+BASE | wum_chap_distance_02_1 + scatternoises2 | 0.05 |
| 02 | BASE (→L01) | wum_chap_gravelgrass_01_b_2 | 0.05 |
| 03 | painted | wum_chap_driedgrass_04c + wum_chap_distance_05_b (6 tex) | 0.075 |
| 04 | painted | wum_distance_01_16 (+tint const (0.899,0.817,0.750)) | 0.05 |
| 05 | BASE (→L04) | wum_oakshrub_01 | 0.07 |
| 06 | painted | wum_redsoil_01 + wum_distance_01_20 | 0.10 |
| 07 | painted | wum_oakshrub_01 + wum_distance_01_24 + breakupmask (7 tex) | 0.05 |
| 08 | painted | **NONE** (consts 0x2F9990B7=50, 0xF7652FB3=20 only) | — |
| 09 | painted | wum_chap_gravel_03a | 0.05 |
| 10 | painted | wum_dirtroads_base_02 + wuu_sandnoise | 0.125 |
| 11 | painted | wum_m_sand_02 | 0.075 |
| 12 | painted | t_com_asphaltdetail_02_ncs only (no colour) | 0.025 |
| 13 | painted | breakupmask_02_rgba only | 0.05 |
| 14 | painted | wuu_desertcliff_01_a x2 slot-sets (8 tex) | 0.075 |
| 15 | painted | wum_distance_01_16 | — |
| 16-19 | BASE | t_ter_defaulttexture cv/ao/nhs (+sanddetail on 18) | 0.02-0.05 |
| 20 | BASE | t_ter_defaulttexture_ao only | 0.05 |
| 21 | painted | wum_ls_gravel_02_a (6 tex) | 0.25 |
| 22 | painted | wum_ls_gravel_02_b (6 tex) | 0.10 |
| 23,25,27-33,36-38 | painted | **NONE** | — |
| 24 | painted | wum_soilchurnup_03 | 0.15 |
| 26 | painted | scatternoises2 only | — |
| 34 | painted | wum_crackedconcrete_03 | 0.10 |
| 35 | painted | t_rst_sanddetail_01_nm only | 0.01 |
| 39 | BASE | **wum_waterpuddles_01_rgb** only | — |
| 40 | BASE | **hfd_debug at slot 0xAE16A5C0** — the crater layer | — |
| 41 | BASE (→L40) | ls_gravel_02_a + concreteedge + crackedconcrete (9 tex) | 0.135 |
| 42 | BASE (→L40) | ls_gravel_02_a/b + crackedconcrete (9 tex) | 0.25 |
| 43 | BASE (→L40) | wum_ls_gravel_01_a | 0.075 |
| 44 | BASE (→L40) | wum_dryrockygravel | 0.055 |
| 45 | BASE (→L40) | wum_concretedebris_01+02 (6 tex) | — |

**This contradicts the absoluteness of the "materials live on the base side"
law.** Tungsten: 24/24 painted layers textureless. Badlands: roughly 20 of 31
painted layers bind real albedos. The law's safe form is "*base layers are
always textured; painted layers may or may not be*" — the plugin must composite
weight-page layers with their textures when they have them, which on this map is
most of the ground detail (dirt roads L10, sand L11, cliffs L14, gravels
L21/L22, red soil L06...).

**MEASURED — crater family confirmed.** L40 binds `hfd_debug` at slot
`0xAE16A5C0`, L41-L45 link to it — the Tungsten/dumbo structure exactly
(different indices). **But note L02→L01 and L05→L04:** links are used for
plain material variants too, not only the crater family.

### B2. Blocks

**MEASURED** (`probe_tung_terrain.py mp_badlands`):

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 169, PersistentNodeCount 164
block 0  heights    12,638 B  xs=265, WorldSizeY=281.0, 169 nodes (5 Packed, 164 External), slack 0
block 1  splat     763,530 B  LayerSlotCount=6, 229 nodes, 23,073 records, slack 0
block 4  mask        2,765 B
block 7  material 1,440,520 B dim=256, 105 nodes declared, levelMax=5, 16 pairs
block 8  mask      251,097 B  dim=265, 101 nodes, levelMax=4, maskUnknown0=4
```

No block 2 (density) and no block 5, unlike Tungsten. `LayerSlotCount = 6`
(same as Tungsten's 6, against dumbo's 62 — still meaning unknown, still not
the layer count). One oddity: the block-7 walk (`probe_tung_basefield`) visits
79 nodes and ends **72** bytes before block end (badrows 0, picture coherent)
where Tungsten ended exactly 64 (its footer); the declared nodeCount is 105.
Unknown, benign for rendering, flagged for the block-7 reader.

### B3. Block 7 — the base-material field

**MEASURED.** `pairCount = 16`, `BackgroundMaterialIndex = 0x00000080` — the
same "no background" sentinel dumbo and eastwood use (a naive resolve gives L0).
Lists: list1 (base) = [0,1,2,5,16,17,18,19,20,39..45], list2 (linked) =
[2,5,41..45]. Texel share of the resolved field, pooled over levels:

```
L05  51.1%  wum_oakshrub_01          (textured)
L00  17.6%  wum_chap_gravelgrass     (textured)
L14  15.7%  wuu_desertcliff_01_a     (textured)  <- the canyon walls
L01   8.1%  wum_chap_distance_02     (textured)
L12   4.8%  asphaltdetail ncs only   (no colour) <- the airfield strip
L16   2.6%  t_ter_defaulttexture     (generic)
L11   0.2%  wum_m_sand               (textured)
```

**~93% of the block-7 field resolves to a layer with a real `_cv` albedo**,
against Tungsten's 20.6%. The rasterised field is a recognisable picture
(canyons, shrub plain, road threads, the airfield as L12 rectangles) matching
the colour map spatially. The "honest ceiling" is map-specific and badlands'
ceiling is high — the shader-computed-layer problem barely exists here.

**MEASURED — a Tungsten cross-map claim breaks.** TERRAIN.md §8 noted pair
`X = 0x31` resolving to the shared `wum_ls_gravel` family "on dumbo AND
tungsten". On badlands pairs 12/13 have `X = 0x31`, list 2, and resolve to
**L05 = oakshrub** (list2[1] = 5). The X-value→family match was a coincidence of
two maps' list orderings, not a constant.

### B4. Layer-graph constants

**MEASURED values on badlands** for the unidentified constants
(fleet-brief list): `0x4C200FE0` = 0.0 on every layer that carries it;
`0xCBB9A946` = (0.0, 0.0) everywhere; `0xCF3F97E0` = 0 everywhere observed
(integer type 0x34791132, confirming the not-a-float correction);
`0x2F9990B7` ∈ {50, 100} (textureless L08 = 50); `0xF7652FB3` ∈ {2, 20};
`0xE68B2B10` = 1.0. Two constants not in the Tungsten list appear on L04:
**`0xD8576C4B` = 0.3 (float)** and **`0xDE3589AF` = 1 (uint)**, alongside a
float3 (0.899, 0.817, 0.750) — a plausible tint triple on the layer whose
texture is a distance map. Badlands adds no discriminating evidence for
`0x4C200FE0`/`0xCBB9A946` (all zero here).

---

## C. The colour map and THE DECOMPOSITION TABLE

### C1. Decomposition (the detect_layout verification row)

**MEASURED** (`probe_badlands_decomp.py`): all **169/169** primary chunks
decompose with **zero residual failures** as

```
size = prefix + k x 4,356
prefix = 149,297 (one 265-sample height payload)   x164 chunks
prefix = 0       (the 5 Packed-height nodes)       x5 chunks
```

No 39,919, no 189,216, no 2x149,297 prefix occurs — badlands ships one height
LOD per external node. Distinct residuals mod 4356: {1193 x164, 0 x5}.

- **Page size = 4,356** (raw 66x66, no BC4) — confirming the derived table's
  badlands row and the expected value in the fleet brief.
- **Trailer = 17,424 bytes = ONE 132x132 BC7 tile** (k=1). Where Tungsten has
  two tiles (colour first, degenerate second), badlands has only the colour
  tile, so "first tile of the trailer" and "last 17,424 bytes" coincide.
- **Paired chunks:** 127 exist; **111 of them are exactly 4 x 17,424 with zero
  weight pages** — pure colour-tile groups for the four children (reversed
  child order [3,2,1,0] per bf6_colormap.py); the other 16 are pages + 4 tiles,
  tiles at the END (all four trailing segments read as image data).

BC7 mode census, by depth, of the (single) trailer tile vs the 17,424 bytes
before it:

```
depth 0   1,089 blocks   0.1% modes 4-7   99.2% zero-byte0   <- blank tile
depth 1   4,356 blocks   0.5% modes 4-7   96.5% zero-byte0   <- blank tiles
depth 2  17,424 blocks  64.6% modes 4-7   0.0% zero          m6+m1 dominant
depth 3  52,272 blocks  64.3% modes 4-7   0.0% zero
depth 4  47,916 blocks  64.2% modes 4-7   0.0% zero
depth 5  60,984 blocks  71.2% modes 4-7   0.0% zero
pre-tile control: 179,685 blocks, 6.7% modes 4-7, 76.6% zero-byte0  <- pages
distinct blocks per tile: 1,089/1,089 (all distinct) on 164 of 169 nodes
```

**This contradicts the BC7 mode test as stated.** "Image tiles decode ~100%
modes 4-7" holds for dumbo/tungsten's encoder output; badlands' *real, verified*
colour tiles are only **64-71% modes 4-7** — mode 1 carries 20-30% of the
blocks. The robust discriminator is **distinct-block count + zero-block
fraction** (real tile: ~all 1,089 blocks distinct, ~0% zeros; degenerate tile:
one block repeated; pages: 76% zero lead bytes), with the mode histogram as a
secondary signal. Any detect/verify code hard-coding ">= 95% modes 4-7" will
reject badlands' correct colour map.

The depth-0/1 tiles (the 5 shallow nodes) are ~97-99% zero bytes: authored
blank, not a layout error — deeper nodes cover the world.

### C2. The rendered colour map

**MEASURED.** `probe_badlands_colorrender.py` decodes every primary tile plus
the 127 paired chunks' child tiles as BC7 and assembles them; output saved to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Badlands.png`.
**It reads as a fully coherent aerial photo** — eroded drainage networks in the
north and east, the road net, a small compound and airfield mid-map, dark
shrub/chaparral masses to the south, field parcels at the edges — consistent
with the block-7 field feature-for-feature. Mean RGB of painted texels
**(0.676, 0.631, 0.590)**, mean alpha **0.992**. Note the alpha: Tungsten's
colour tile alpha was ~0.002; alpha semantics are per-map (plaza carries AO
there per bf6_colormap.py). There is **no SDK overhead JPG for badlands** to
diff against (`addons/bf_portal/terrain_decal/textures/` ships only Aftermath,
Capstone, Tungsten), so the check is the internal spatial match, which is
unambiguous.

**Mechanical consequence for the plugin today:** with the (2592, 4624) pick,
`color_tiles()` takes the last 4,624 bytes — a horizontal slice of the real
132x132 tile decoded at 68x68 — and `node_pages()` slices weight pages
misaligned and BC4-decodes raw planes. Badlands is one of the nine wrong-page
maps; both fixes in MAP-TUNGSTEN §G1/G2 are verified by this map's table, with
the addendum that the tile count k can be **1** (badlands) or 2 (tungsten) and
the mode-test threshold must be loosened (§C1).

---

## D. Decals and roads — a SECOND TerrainDecals record framing

**MEASURED.** `decals.TerrainDecals` is 13,745,896 bytes, slotCount 46
(= layerCount), recordCount 628 — and `probe_tung_decals.py` parses **0** of
them. The records here are framed **geometry-first**:

```
+0x00 u64 material-group hash    (nonzero; tungsten's rec 0 has 0 here)
+0x20 the block tungsten's probe calls `t` (FirstIndex, TriCount, tilings)
+0x40/+0x50 AabbMin/AabbMax      +0x80 2D box
+0x90 the anchor row              +0x98 slot
+0xB0 u32 propSize, u32 nProps, property stream (same grammar, same type ids,
      same four slot hashes _cv/_nhs/_ao/_op), record ends at +0xB4+propSize
```

`probe_badlands_decals.py` parses **628/628 with 628/628 anchors valid and the
FirstIndex chain unbroken (628/628)**. The tungsten probe enters the stream
expecting [props][geometry] and reads the leading hash as a propSize.
**HYPOTHESIS:** the two layouts are one format and the tungsten parse succeeds
by phase accident (its rec-0 "props" are 32 zero bytes of geometry header);
if so, its per-record prop/geometry association may be shifted by one record.
Worth one re-check on tungsten with this framing before trusting per-record
texture-to-AABB joins there.

**MEASURED — content.** 6 of the 7 GUID-bearing slots are used (16,17,18,19,20,
39 — exactly textured base-layer indices), 44 texture-set groups:

- Slot 18 is the road system: 260 records, 86,444 tris, spanning the whole map.
- The biggest group is **77 records binding only `_op` =
  `wum_waterpuddles_02_rgb`** — the puddle class again (mask-only, no colour;
  the "no basecolor is not a failure" gotcha).
- One group of **30 records binds no textures at all**.
- Groups mix libraries exactly as on Tungsten: `naf_roadtracksdirtpacked`
  (north-africa) beside `wum_dirtroad_midgravel` (west-us-mountain) beside
  `cas_footprints_01` (central-asia), `wuu_stains`, `wuu_asphaltsingleline`,
  `patches_seam_01`. Group by the whole texture set, never one slot.
- Coverage: x -2048..2041, z **-1146..2048** — the northern band z < -1146
  (the deep canyon third) carries no terrain decal; decal Y spans 4.5..123.8,
  AABB minima below the terrain floor 17.85 as expected for draped decals.

---

## E. Everything else notable

**MEASURED — scatter, the fleet's open join question (this map's extra focus).**
The level ships `meshscatteringdatabaseasset.MeshScatteringDatabase` (36,663 B):
**71 entries, 29 vegetation kits, 0 wind shaders**, budgets
(12000, 12000, 16000, 16000), cell 4096 — parsed byte-exact by `msdb.py`. The
EBX side of the join, however, is **empty: all 48 `SingleTerrainLayerData`
instances in `mp_badlands_terrain.ebx` have `MeshScatteringTypes = []`** — and
`probe_badlands_scatter.py` extends this to a census: **all 16 terrain-bearing
levels, 781 SingleTerrainLayerData instances, ZERO populated
MeshScatteringTypes**, while every level ships a populated MSDB (22..85
entries). No partition in the level declares any `*scatter*` EBX type either.
**The per-layer scatter assignment (Density/MinScale/MaxScale/Identifier) is
stripped from the shipped EBX game-wide, like the authored layer graph. The
join cannot be validated from shipped data on any map**, and the plugin should
stop planning around it: real clutter needs MSDB (which meshes + per-mesh view
distance) plus a placement heuristic from the splat/density masks. This
retires the fleet-brief item negatively but definitively.

**MEASURED — the "AftermathScatter" generated layer is not scatter data.**
`generated/ag_aftermathscatter_5317b368.ebx` (285 objects) holds 285 instances
of an unnamed type (`2a85e577-...`), each a bare Vec3 position + an `Asset`
import to a per-level `generated/aftermathasset<guid>.ebx` + a tag import
(`tools/aftermathmeshscattering/tags/aftermathmeshscattering_{concrete,wood}`).
Every `aftermathasset` inspected is an **empty container** (empty arrays, zero
AABB). Battle-debris authoring records, shipped hollow.

**MEASURED — structure.** 172 LayerData partitions, 86 empty. Busiest:
`fx_global` (451 — largest FX layer seen so far), `area_07` (406), the
generated scatter layer (285), `lighting` (201), `occluders` (119),
`area_02_new` (98), `sabotage/mp_sabotage0` (96), `sound` (88), `conquest0`
(74), `debrispiles` (69). World content sits in **area_01..area_07 subworlds**
(plus `area_02_new`; `area_00`, `area_06`, `area_08` exist and are EMPTY), each
with its own physics + meshvariationdb + shaderblockdepot. Gamemode layers
include **sabotage, payload, kingofthehill, domination, freeroam0,
customportal** alongside the usual set; six modes share
`shaderblockdepot_9526102139013923511` byte-for-byte. Placement-walk hazards:
`scrapyard_smallmodesonly.ebx` (20 objects — mode-conditional world content,
with its own `_scrapyard_extracover` physics), an empty `mp_badlands2.ebx`
stray root-level layer, and the dev-named `backdropworkdaniel.ebx`.

**MEASURED — backdrop/skyline (open task).** The generated backdrop layers
shipped EMPTY (`backdropterrain_output`, `backdropbuildings_output`,
`backdroptrees_output`, `backdrop_cables`). Actual backdrop content is
`_layers_world/backdropworkdaniel.ebx`: 23 `SpatialPrefabReferenceObjectData`
whose blueprints resolve to `dwpf_watertank_01_badlands`,
`pfw_mil_barrack_01_a`, `fxpf_ind_silomedium_01`,
**`bd_ind_oilpumpjacknearskinned_03`** (a real `bd_` backdrop-class mesh),
`gra_puddles_01_r`, `whitedecal2d`. `backdrop.ebx` itself holds 2 references to
`cratermaker_medium_soft`. So badlands' skyline is terrain plus a handful of
distant industrial props — there is no backdrop mesh ring to miss.

**MEASURED — lights / volumes (open-task census).** Prop lights are nearly
absent: 4 `PbrSphereLightEntityData`, 1 spot, 1 rectangular. 5
`EnvironmentDecalVolumeData`, 3 `PbrBoxReflectionVolumeEntityData` + 1
`PbrDistantReflectionVolumeEntityData`, 3 `LightProbeVolumeData`, 4
`ParticipatingMediaVolumeEntityData`, 2 `DistantShadowCacheVolumeEntityData`.
No cloud-shadow-named type and no livery-named type appears in the census.

**MEASURED — big files.** Enlighten highend 146.1 MB / lowend 33.4 MB,
`materialgrid_win32.ebx` 15.5 MB, TerrainDecals 13.7 MB (2.5x Tungsten's),
area_07 physics 7.4 MB. Height quantisation: `WorldSizeY = 281` → one u16 step
= 0.43 cm (fine, near dumbo's 0.39).

---

## F. Generalisation — what badlands confirms, and what it CONTRADICTS

| finding | scope | verdict on the law |
|---|---|---|
| Page size 4,356; every chunk = prefix + k x 4356, zero residuals; prefixes {0, 149297} | badlands | **Confirms** the per-map page-size table and the detect_layout fix row (4356 set). |
| Trailer = ONE 17,424 B tile; paired chunks end with 4 child tiles ([3,2,1,0]), 111/127 paired chunks are tiles-only with zero pages | badlands | **Confirms** tile-not-last-4624; **extends**: k can be 1, and paired chunks can be pure colour groups. |
| Real colour tiles are only 64-71% BC7 modes 4-7 (mode 1 heavy), yet all-distinct and spatially correct | badlands | **CONTRADICTS the mode test as a threshold.** Use distinct-block count + zero-block fraction; treat the mode histogram as advisory. |
| 20 of 31 painted layers bind textures; ~93% of the block-7 field has a real albedo | badlands | **CONTRADICTS the absolutised** "painted layers are textureless" reading. Safe form: base layers are always textured; painted layers vary per map. The 20.6% ceiling is Tungsten-specific, not the genre. |
| `X = 0x31` pair resolves to oakshrub here, not wum_ls_gravel | badlands | **CONTRADICTS** TERRAIN.md §8's cross-map X-value observation — coincidence of list order. |
| TerrainDecals parses geometry-first here; tungsten probe reads 0 records | badlands (at least) | **New format variant** (or the true framing everywhere — flagged for re-check on tungsten). Slot table, prop grammar, slot hashes identical. |
| No water entity at all | badlands | **Extends** the water law: the diagnostic needs an "absent" state, not just above/below floor. |
| One populated ECS prefab (1,429 ents) under generated/, 28 empty stubs | badlands | **Confirms** stubs are boilerplate; **warns** that populated prefabs occur outside dumbo/aftermath and hold real content a placement walk misses. |
| MeshScatteringTypes empty on ALL SingleTerrainLayerData of ALL 16 levels; MSDB populated on all | **every map** | **Closes the fleet's scatter-join question negatively**: the per-layer side is stripped from shipped data; the Identifier join is unvalidatable and should be abandoned as a plan. |
| Crater layer L40 = `hfd_debug` at `0xAE16A5C0`, L41-45 linked | badlands | **Confirms.** Also: links are used for plain variants (L02→L01, L05→L04), not only craters. |
| Layer-graph decoy table 68 bytes before the true one (144 vs 212) | badlands | **Confirms** the 100%-depot-resolve rule; the 68-byte decoy delta recurs. |
| `0xCF3F97E0` integer (value 0 here); `0xCBB9A946` (0,0); `0x4C200FE0` 0.0 | badlands | Consistent; badlands adds no new leverage. New unknowns seen: `0xD8576C4B` (0.3f), `0xDE3589AF` (uint 1). |

---

## G. Next steps for the plugin, in priority order

1. **Land the detect_layout fix with badlands as a verification row** —
   `addons/highpoly_toggle/bf6_splat.gd::detect_layout`. Expected on this map:
   page 4,356, prefix set {0, 149297}, trailer 17,424, zero residuals over 169
   chunks (`probe_badlands_decomp.py` reproduces the row).
2. **Make the colour-tile validity test distinct-block/zero-block based, not
   mode-threshold based** — `bf6_splat.gd::color_tiles` (and any BC7 "is this
   an image" check). A >= 95% modes-4-7 gate rejects badlands' correct tiles
   (64-71%). Accept: ~1,089 distinct blocks, ~0% zero-lead-byte; reject:
   one-block-repeated or zero-dominated. Handle k=1 (badlands) and k=2
   (tungsten) trailers; treat the depth-0/1 blank tiles as authored-blank.
3. **Composite textured PAINTED layers** — the splat path must not assume
   base-side-only materials (`bf6_materialtree.gd` / splat compositing). On
   badlands most ground detail (dirt roads, sand, cliffs, gravels) lives on
   painted layers with real albedos; block 7 alone leaves that on the floor.
4. **Water diagnostic: add the "no entity" state** —
   `highpoly_gamesource.gd::water()`. Badlands has no water partition; log
   "level ships no water entity" instead of failing silently or building
   nothing without explanation.
5. **Drop the MeshScatteringTypes/Identifier plan; scatter = MSDB + masks** —
   wherever the scatter TODO lives (highpoly_scatter path). The per-layer EBX
   data is stripped game-wide (16/16 levels measured). Badlands' MSDB: 71
   entries, 29 veg kits, per-mesh view distances — that plus splat masks is the
   whole shipped truth.
6. **Support the geometry-first TerrainDecals framing** — any future decal
   reader (and re-run tungsten's decal stats with it: `probe_badlands_decals.py`
   framing vs `probe_tung_decals.py` association may be off by one record
   there).
7. **Placement walk: include populated EcsRuntimePrefabAssets** — badlands'
   `ag_splinesfrommaskprefabasset` holds 1,429 entities (likely the procedural
   fences). Detection is cheap: any prefab whose shape is not the
   `ent=1/comps=[26]` stub.
8. **Note the mode-conditional layers** — `scrapyard_smallmodesonly`,
   `_scrapyard_extracover`, empty `area_00/06/08`, stray `mp_badlands2.ebx` —
   in whatever governs the gamemode/subworld walk, so they neither surprise nor
   double-load.
