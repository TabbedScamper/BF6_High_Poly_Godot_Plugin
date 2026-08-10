# MP_Eastwood, end to end

One map read from the shipped data, following `MAP-TUNGSTEN.md`'s method and
verifying its laws here. **Every claim is tagged MEASURED or HYPOTHESIS**; a
MEASURED claim names the resource/offset/value and the probe that reproduces
it. Nothing here touched the plugin, its shaders, or any `user://` cache.

Probes: the `probe_tung_*.py` suite runs level-parameterised
(`probe_tung_terrain.py mp_eastwood` etc.); three new eastwood-specific probes
sit beside them:

```
tools/probe_eastwood_decomp.py       exact chunk decomposition + BC7 mode test
tools/probe_eastwood_water.py        LakeData census + buried ocean + WaterAsset
tools/probe_eastwood_decals.py       TerrainDecals census by property scan
tools/probe_eastwood_colorrender.py  real BC7 colour-map assembly -> PNG
```

---

## 0. The map in one paragraph

**MEASURED.** MP_Eastwood is a 4,096 x 4,096 m world (block 0 root AABB
`x,z ∈ [-2048, 2048]`), ground from **y = 174.825 to y = 518.0**
(`WorldSizeY = 518.0`), 157 streaming nodes, 275 chunks on disk. It is a
Los-Angeles-suburb golf-course map (`westusurban`/`westusmountain` texture
libraries, golf-fairway layers, tennis courts, a freeway in the backdrop). Its
terrain palette is **59 layers of which 34 bind textures — on BOTH the painted
and the base side**. It carries a 31.2 MB TerrainDecals resource (2,340
records), **42 LakeData water polygons**, one buried `WaterSurfaceEntityData`,
34 ShaderBlockDepots, 198 LayerData partitions (86 with zero Objects), and 50
EcsRuntimePrefabAssets of which **one — the backdrop — is populated**. Its
colour map is **real satellite imagery**.

---

## A. Water — what "water on Eastwood" means

### A1. The ocean plane is buried, as briefed — confirmed

**MEASURED** (`probe_eastwood_water.py`). The single `WaterSurfaceEntityData`
in `_layers_content/water.ebx` has Transform translation
**(-4.043, 3.076, 5.380)** — water height y = 3.08 — against a terrain floor of
**174.825**: authored **171.75 m underground**. The A3 law of MAP-TUNGSTEN.md
(water renders only where entity y > terrain floor) holds; this map's ocean
plane can never render anything.

**MEASURED — new wrinkle: the basis is ROTATED.** Eastwood's water transform is
the first non-axis-aligned one seen:

```
right    ( 4093.862,  0.000,  132.293)     |right| = 4096.0
up       (    0.000,  1.000,    0.000)
forward  ( -132.293, -0.000, 4093.862)     ~1.85 deg about Y
trans    (   -4.043,  3.076,    5.380)
QueryBoxHalfExtent (2048.0, 0.5, 2048.0)   TileOffset (0, 0, 0)
MaterialPair.Packed 367015049 = 0x15E03489
```

`QueryBoxHalfExtent` at +0x90 and `TileOffset` = (0,0,0) at +0xB0 both
reproduce the MAP-TUNGSTEN.md A4 correction on this map. A consumer that takes
the extent from `basis.x.x` gets 4093.86, not 4096 — harmless here (the plane
is buried) but wrong in principle; use the basis row length.

**MEASURED — the `WaterAsset` is empty**, exactly like Tungsten: 380 bytes,
one instance, `PhysicsResource = ResRef 0`, no MeshSet beside it.

### A2. The REAL water: 42 LakeData polygons — a type Tungsten does not have

**MEASURED** (`probe_eastwood_water.py`; type scan
`probe_tung_types.py mp_eastwood --find lake`). Eastwood ships **LakeData**
instances — closed spline polygons with a constant authored water level — in
six partitions:

| partition | LakeData |
|---|---|
| `mp_eastwood_terrain/.../mp_eastwood/decals.ebx` (the terrain build output) | **20** |
| `_layers_content/water.ebx` | 13 |
| `_layers_world/area_02.ebx` | 4 |
| `_layers_world/area_03.ebx` | 1 |
| `_layers_world/area_04.ebx` | 3 (one a degenerate 1-point spline) |
| `_layers_world/area_05.ebx` | 1 (degenerate 1-point spline) |

The decals.ebx set of 20 equals the union of the authored layer copies minus
the two 1-point degenerates — same polygons, same Y, same bounds — so the
terrain partition's 20 records are the deduplicated render set and the layer
copies are the authoring sources.

**MEASURED — every lake is far ABOVE the terrain floor, i.e. visible water:**
water level Y runs **215.89 to 237.28** (41.1 – 62.5 m above the 174.825
floor). The 20 real ponds: one 11,894 m² lake (x 110..252, z 337..513,
y = 221.70 — it is the dark blob in the assembled colour map), four
1,500–4,000 m² ponds (golf-course water hazards), and ~15 small 150–310 m²
rectangles at y ≈ 230–237 (backyard swimming pools — 4-point quads in the
residential grid). Fields: `IsClosed = true`, `SplitToMatchHeightfield = true`,
`DrawOrderIndex 100`, `Shader3d` imports partition
`59a25324-4223-11df-93bd-9514142d4105` (a shared water shader asset;
unresolved name — not in the dump's `_af` subset).

Point struct (`bac217bd-e5ec-2302-320d-f681ba6c1763`): field hashes
X = 956422932, Y = 1123815262, Z = 849976220 (decimal), Y constant per lake.

**MEASURED — no other map checked has LakeData.** A byte scan for the LakeData
type GUID over the whole level trees of mp_tungsten, mp_dumbo and mp_aftermath
finds zero partitions. Lakes are eastwood's own water representation (of the
maps studied so far).

### A3. The supporting water cast

**MEASURED**, all in `_layers_content/water.ebx` unless noted:

- **42 `EnvironmentDecalVolumeData`** instances sit in the water layer — one
  per LakeData instance by count — wet-ground decal volumes ringing the ponds.
  (Open-task note: this is the environment-decal-volume evidence the fleet
  brief asks for, and it lives in the WATER layer, not a decal layer.)
- **1 `WaterInteractTurbulenceDisturbEntityData`** at (36.65, 223.86, 242.96)
  with `DisturbFreq 100, AreaSizeX 37.5, AreaSizeZ 43.75` — a fountain-style
  disturbance sitting on the 3,973 m² pond at x -4..62, z 195..299
  (y 225.10 ≈ its 223.86).
- **1 `TerrainQuadDecalData`** in the water layer.
- Terrain layer **L52** (base, in all 852 base records) binds exactly one
  texture: `westuscoastal/terrain/terraindecals/waterpuddles_01/
  wum_waterpuddles_01_rgb` — a shader-driven **puddle layer**.
- The TerrainDecals resource binds `wum_waterpuddles_02_rgb` as `_op`-only in
  **61** records (§D) — puddle decals.
- Layers `area_01_puddles.ebx`, `area_09_puddles.ebx` exist as authored layers.
- `ve_mp_eastwood_base_01` has `OceanComponentData` (present on maps with and
  without visible ocean; not evidence either way — same caveat as Tungsten).

### A4. Is there a river / terrain-drawn water like Tungsten's L10?

**MEASURED — no.** Block 7's `BackgroundMaterialIndex` is `0x00000080` (the
dumbo-style value; mechanically it resolves through list 0 low-nibble 0 to
L00, the gravel-grass base — MAP-TUNGSTEN.md reads this value as the
"no background" sentinel). The block-7 texel table (§B) contains no
channel-shaped layer; the rasterised base field and the assembled colour map
show canyons and a freeway but no river in the playable space. No layer named
river/creek exists in `_layers_world`. **"Water on Eastwood" therefore means:
20 LakeData polygon ponds/pools, their 42 wet-ring decal volumes, the L52
puddle layer, and the puddle decals — and nothing else.** The buried ocean
plane and the empty WaterAsset are the same unused defaults Tungsten has.

### A5. ECS stubs — law confirmed, with one exception worth having

**MEASURED** (`probe_tung_ecs.py mp_eastwood`): 50 EcsRuntimePrefabAssets, 49
the identical empty stub (`ent=1 arch=1 seg=1 edits=0 comps=[26]`) —
including `water_ecsprefab` — and **one populated**:
`_layers_world/backdrop_ecsprefab_ecsprefab.ebx`, `ent=41 arch=3 seg=6
edits=41 comps=[0,42,50,54,58]`. The stub-is-boilerplate law holds; eastwood
adds the first populated WORLD-layer prefab seen (dumbo/aftermath's populated
ones are gameplay layers).

---

## B. Terrain and ground layers

### B1. The palette: 59 layers, textures on BOTH sides

**MEASURED** (`probe_tung_terrain.py mp_eastwood`,
`probe_tung_layers.py mp_eastwood`): terrain dir is **`mp_eastwood_terrain`**
(naming law confirmed: not `terrain_<level>`). `VisualTerrain` layerCount 59;
layer-graph record table at offset 264 located by the all-keys-resolve rule
(59/59 in the paired depot; 48 content-deduplicated records, 159 texture
params, 423 constants). Links: L02→L01, L05→L04, **L54..L58→L53**; L53 binds
`hfd_debug` at slot `0xAE16A5C0` — **the crater-layer law confirmed** (L53 is
the crater layer, L54-L58 its materials: `wum_ls_gravel_02_a/01_a`,
`wum_dryrockygravel`, `wum_concretedebris`).

**MEASURED — the headline contradiction: eastwood's PAINTED layers bind
textures.** Split from block 1 (25,955 records over 213 nodes, flag bit at
record +20):

- 38 painted layers, of which **22 bind textures** (L01 wum_chap_distance_02,
  L03 wum_ls_gravel_02, L04 wum_distance_01_16, L06 wum_redsoil_01,
  L07/L10 wuu_grass_fairway_01, L08 wum_oakshrub_01, L09 wum_chap_gravel_03a,
  L11 wuu_desertcliff_01, L12 wum_ls_gravel_01, L16 wum_m_sand_02,
  L21 wuu_grasspatchy_02, L23 cas_pebbles_01, L24 wum_distance_01_16,
  L41 wuu_asphaltrubblepile, L48 wum_hardsurfacecracked_01,
  L49 wum_crackedconcrete_03, L50 wum_oakshrub_01, L51 sanddetail, and
  mask-only L35/L42/L45);
- 23 base layers, of which 12 bind textures (L00/L02 wum_chap_gravelgrass_01,
  L05 wum_oakshrub_01, L19 wuu_golffairwayedge_02, L26-L28/L30-L32
  default-texture sets, L52 waterpuddles, L53-L58 crater family).

MAP-TUNGSTEN.md's generalisation "terrain materials live on the base side"
(absolute on Tungsten, 11-of-16 on dumbo) is **NOT a law**: on eastwood the
majority of textured layers are painted. A renderer that only samples albedo
for base layers forfeits most of this map's texture detail.

**MEASURED — streaming blocks:**

```
block 0  heights    12,230 B  xs=265 WorldSizeY=518.0  157 nodes (5 Packed, 152 External), slack 0
block 1  splat     858,492 B  LayerSlotCount=62, 213 nodes, 25,955 records, slack 0
block 2  density     8,685 B  57 nodes (5 Packed, 29 Empty, 23 External), root Y 50.0..237.6
block 4  mask        2,573 B      block 5  mask  211 B
block 7  material  931,661 B  dim=256, 109 nodes declared, levelMax=5, 16 pairs
block 8  mask      322,136 B  dim=265, 101 nodes, levelMax=4, maskUnknown0=4
```

`LayerSlotCount = 62` (as on dumbo/aftermath; Tungsten's 6 is the outlier).
Note block 2's root Y range (50.0 .. 237.6) overlaps the lake levels — density
data exists exactly over the low, wet part of the map. (Correlation only.)

**MEASURED — parser deviation to record:** `probe_tung_basefield.py`'s block-7
node stream ends 72 bytes before the block end on eastwood (tungsten: exactly
the 64-byte footer). All 16 pairs still resolve and the raster is coherent;
the 8 extra bytes are unexplained. levelMax is 5 here (4 on tungsten).

### B2. Block 7 — resolved base field

**MEASURED** (`probe_tung_basefield.py mp_eastwood`): 16 pairs; lists:
list1 (base) = [0,1,2,5,15,18,19,20,24,25,26,27,28,30,31,32,52..58],
list2 (linked) = [2,5,54..58]. Texel share pooled over levels:

```
L05  42.8%  wum_oakshrub_01        (textured)   <- chaparral hillsides
L01  19.9%  wum_chap_distance_02   (textured)
L00  13.0%  wum_chap_gravelgrass   (textured)
L02  11.3%  wum_chap_gravelgrass_2 (textured)
L15  11.2%  NONE                   (textureless base)
L10   1.1%  wuu_grass_fairway_01   (textured)
L12   0.7%  wum_ls_gravel_01       (textured)
```

**88.8% of eastwood's base-field texels resolve to a layer with an albedo**
(Tungsten: 20.6%). The "honest ceiling" is map-specific and eastwood's is
high — with the painted-side textures on top of that. Pair `X=0x31 -> list 2`
resolves into the `wum_ls_gravel` family here too (pairs 11/12), the third map
confirming that cross-map observation.

### B3. Scatter join — cannot be validated here

**MEASURED.** `mp_eastwood_terrain.ebx` holds 65 `SingleTerrainLayerData`
instances and every one deserialises to an **empty** `MeshScatteringTypes`
list, while `mp_eastwood/meshscatteringdatabaseasset.MeshScatteringDatabase`
(46,192 B) ships anyway. The Identifier-to-catalogue join the fleet brief asks
about has nothing to join on this map. Eastwood's visible clutter ships
instead as a **generated placement layer**:
`_layers_world/generated/ag_aftermathscatter_aftermathentities_6b8da36b.ebx` —
3,045 instances (3,044 of placement type `2a85e577-3a79-ef4d-...`), each
importing its own `aftermathasset<guid>` partition. A placement walk CAN read
these.

---

## C. The colour map — the decomposition table

### C1. Chunk decomposition (the detect_layout verification row)

**MEASURED** (`probe_eastwood_decomp.py`): 275 chunks (157 primary + 118
paired), all sizes matching the directory. **Page size 2592 decomposes every
chunk exactly; 4356 and 5184 do not** — confirming the derived table's
eastwood row and the `bf6_splat.py` cross-check.

```
primary (157):  133 x  [149297 heights][pages x 2592][ONE 17424 tile]
                 19 x  [2 x 149297    ][pages x 2592][ONE 85024 mip pair]
                  5 x  [   no heights ][pages x 2592][   no trailer   ]   (Packed nodes)
paired  (118):  101 x  [4 x 17424 child tiles, nothing else]
                 17 x  [pages x 2592][4 x 17424 child tiles]
```

- Height prefixes seen: 149297 and 2x149297 — from the established set.
- **The trailer tile size varies BY NODE within this one map**: 17,424
  (132² BC7) on most nodes, **85,024 = 260² + 132² mip pair** on 19 interior
  nodes (depths 2-4). 85,024 is in `bf6_colormap.py`'s TILE_SIZES as a mip
  pair, largest first; the BC7 mode scan of chunk 0x302 shows the clean
  modes-4-7 region spanning exactly the first 68,912 bytes of its 85,024-byte
  trailer (the 260² tile plus the top of the mip), the rest degenerate.
- BC7 mode histogram pooled over all primary trailers: 83.0% modes 4-7
  (m6 44%, m4 27%, m3 17% — the m3 share is the mip-pair tails and uniform
  suburb blocks). Per-node checks (`probe_tung_colormap.py mp_eastwood`):
  depth>=2 nodes are 100% modes 4-7; the root/depth-1 nodes' last bytes are
  mode-0/invalid — those are the 85024-trailer nodes whose LAST 4,624 bytes
  are mip tail, not colour.
- 25 chunks have a second, aliasing decomposition (189,216 = 73 x 2592
  aliases pages against a height payload; k=0 rows are tile-blind). A
  detect_layout that requires a UNIQUE decomposition per chunk must therefore
  vote per level, not per chunk.

**Consequence for the plugin** (mechanically, from
`bf6_splat.gd::detect_layout` picking (2592, 4624) here): the page size is
RIGHT on eastwood, but `color_tiles()` slices the last 4,624 bytes — the
bottom quarter of the 132² tile (or mip tail on 19 nodes) — and decodes it as
68². Right codec, right palette, wrong raster: eastwood's colour map comes out
as a mis-tiled strip collage. `node_pages()` is likewise shifted by
17,424-4,624 = 12,800 bytes (not a 2592 multiple), so **every weight page on
this map is read 4.94 pages early** — page-aligned garbage into the splat.

### C2. The rendered colour map

**MEASURED** (`probe_eastwood_colorrender.py`, real BC7 decode through
`bf6_colormap.py`): written to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Eastwood.png`
(152 tiles, 5 trailerless nodes skipped), mean RGB **(0.396, 0.416, 0.398)**.

**It reads as a fully coherent aerial photo** — literal satellite imagery of a
Los-Angeles-foothill suburb: canyon ridges, street grids, a freeway
interchange crossing the south, ball fields — with the playable golf-course
core sitting as a near-neutral grey patch (the 0.5-neutral modulation law:
inside the playable space the colour map only modulates layer albedos, while
the vista ring carries the photo as the only colour there is) and the big
LakeData pond visible as a dark shape at the right coordinates.

---

## D. Decals and roads

**MEASURED** (`probe_eastwood_decals.py`): `decals.TerrainDecals` is
**31,159,232 bytes** (5.7x Tungsten), slotCount 59 (= layerCount, law holds;
46 empty / 13 with GUID), recordCount 2,340.

**MEASURED — the record framing is NOT Tungsten's.**
`probe_tung_decals.py mp_eastwood` parses 0 of 2,340 records: eastwood records
open with a geometry header (tiling floats at ~+0x24, a world AABB at ~+0x40)
BEFORE the property stream, where tungsten's records open with the property
stream. 154 records open with magic u64 `0xAEF8B6DE64DD8673` and all 154 carry
a plausible world AABB at +0x40 (Y 220.0..248.3 — draped on the playable
ground); the magic is not universal (154 of 2,340), so it is a per-material
constant, not a record delimiter. Full framing: **unknown** (not decoded
here). TERRAIN.md §10's record layout is per-map, not universal.

**MEASURED — the property-entry encoding IS identical**, so a whole-file scan
of the four slot hashes gives the census without the framing: 1,676 `_cv` /
1,684 `_nhs` / 1,627 `_ao` / 1,331 `_op` bindings, 297 distinct textures.
Top materials (suburb, not steppe): `wum_m_concreteplain_01` x290,
`wuu_dirt_line_01` x158, `wuu_pavement_concrete_06` x84,
`wuu_vertical_pavers_02` x78, `wuu_concretetile_02` x77,
`seu_asphaltrough_02` x76, `wuu_stains_01_a/b` (op-only) x166,
`wum_airfield_trackwear_01` (op-only) x72, and **`wum_waterpuddles_02_rgb`
(op-only) x61** — the puddle-decal class from
`findings/water-and-decal-reader-gotchas`, well represented here.

---

## E. Everything else notable

**MEASURED — structure** (`probe_tung_structure.py mp_eastwood`): 198
LayerData partitions, 86 with zero Objects. Nine `area_0N_subworld`s plus
`sabotage_subworld` and `world`. Busiest layers: the generated
aftermathscatter (3,044), `backdrop` (484), `area_03` (341), `area_02` (292),
`debrispiles` (195), `fx_global` (195), `occluders` (188). Biggest files are
lighting again: `enlighten_mp_eastwood_highend` 74.6 MB + lowend 44.5 MB;
`materialgrid_win32.ebx` 16.1 MB. 34 ShaderBlockDepots;
breakthrough/domination/strikepoint/kingofthehill/sabotage/teamdeathmatch
share one depot byte-for-byte (`shaderblockdepot_9526102139013923511`),
conquest and obliteration another — the mode-depot-sharing pattern again.

**MEASURED — the backdrop/skyline exists and is COMPLETE, but it hangs off the
level ROOT, not a layer.** Level-local backdrop assets under
`levels/mp_eastwood/backdrop/`:

- `buildings/`: 23 `bd_wuu_buildingseastwood_NN_mid` clusters + 25
  `bd_wuu_vegetationeastwood_NN_mid` clusters + 6 backdrop tree species
  (`bd_tr_com_*`: broadleaf, cypress, eucalyptus, canary palm, boxwood), each
  with its `.MeshSet` shipped, plus a baked vegetation atlas
  (`t_bd_vegetationeastwood_atlas_{cu,nts,sdf}`);
- `terrain/`: 8 vista terrain skirt tiles in `_near` AND `_far` variants
  (`bd_wuu_terraineastwood_0N_{near,far}`) with per-tile baked `_cs`/`_na`
  textures — the painted mountains around the playable square;
- plus `bd_wuu_stormdrain_eastwood_0N` (the concrete LA storm-drain channel,
  as backdrop meshes).

**`mp_eastwood.ebx` (the level root partition, 44 instances) imports 134 of
these backdrop partitions directly** — `_layers_world/backdrop.ebx` (481
`ObjectReferenceObjectData` + the one populated ECS prefab) imports only the
prefab and one shared vegetation asset. A placement walk that only visits
subworld/layer partitions **misses the entire skyline of this map**; the
backdrop placements resolve through the level root's static model group and/or
the populated `backdrop_ecsprefab` (41 entities). Exact join: **unknown**
(not decoded here).

**MEASURED — root-level oddities that would confuse a placement walk:**
`ag_roads.ebx` (+ its own shaderstate), `road_residential_9m.ebx`,
`ww_conc_black_paver_2m_01.ebx`, `ww_conc_plain_3m.ebx`,
`ww_conc_red_paver_2m_01.ebx`, `area_3_props.ebx` (inconsistent naming vs
`area_03_*`) all sit at the level root beside `mp_eastwood.ebx`; `_layers_world`
carries per-area decoration micro-layers (`area_01_{cracks,dirt,lines,puddles}`,
`area_02_cables`, `area_0N_volumedecal`, `roadsglobal_{details,lines}`,
`predestruction`, `debrispiles`) — 12 micro-layer families that are all
ECS-stub + real Objects. Gamemode layers include **`freeroam0`** and
`customportal` with importsublevel — eastwood carries a free-roam mode the
older maps lack. `_layers_autotests` and `_layers_tools` exist (empty-ish).

**MEASURED — height quantisation**: `WorldSizeY 518.0` -> one u16 step =
0.79 cm (between dumbo's 0.39 and tungsten's 1.59).

---

## F. What generalises, what contradicts

| finding | scope | contradicts / explains |
|---|---|---|
| Page size **2592** exact on all 275 chunks; 4356/5184 fail | eastwood row of the fleet table | Confirms the derived per-map page table and detect_layout fix target. |
| **Trailer tile size varies PER NODE**: 17,424 on 133 nodes, **85,024 (260²+132² mip pair)** on 19, none on 5 | at least eastwood; bf6_colormap.py says abbasid/aftermath/badlands/capstone/outskirts/subsurface share the 17424 residual | **CONTRADICTS a per-map (page, tile) model.** `detect_layout` returning one tile size per map cannot be right here; the trailer must be decomposed per chunk. |
| Colour tile is the FIRST thing in the trailer; mip/degenerate data last | eastwood (85024 nodes), tungsten (2x17424) | Same law, third form. The plugin's last-4624 slice reads mip tail on 19 nodes and a quarter-tile on the rest. |
| **Painted layers bind textures — 22 of 38** | eastwood (and partially dumbo) | **CONTRADICTS "terrain materials live on the base side" as a law.** It is a per-map tendency; Tungsten's absoluteness was the outlier. Base-side-only albedo sampling loses most of eastwood's texture detail. |
| 88.8% of base-field texels have an albedo (vs Tungsten 20.6%) | per-map magnitude | The "honest ceiling" varies enormously; eastwood will actually look textured once decode is right. |
| Crater slot `0xAE16A5C0`: one layer per map binds `hfd_debug` (here L53; L54-58 link to it) | every map (3rd confirmation) | Law holds. |
| `QueryBoxHalfExtent` at +0x90, `TileOffset` = 0 at +0xB0 | every map (3rd confirmation) | Law holds. |
| Water y (3.08) below floor (174.82) -> buried | every map | Law holds; eastwood is the extreme case (-171.7 m). |
| **Water basis can be ROTATED** (~1.85° about Y) | eastwood | New: don't read extent from basis.x.x; use row length. |
| **LakeData polygon water exists, 42 instances, deduped to 20 in the terrain decals partition**; absent on tungsten/dumbo/aftermath | eastwood (check per map) | New water representation class. "No visible WaterSurface" does NOT mean "no water". |
| ECS stub law (49/50 identical empties) | every map | Holds; plus the first populated WORLD prefab (backdrop, 41 entities). |
| Terrain dir naming inconsistent (`mp_eastwood_terrain`) | every map | Law holds. |
| Layer-graph table located only by all-keys-resolve (offset 264 here) | every map | Law holds. |
| TerrainDecals **record framing differs per map** (tungsten parser: 0 of 2,340); property entries identical | eastwood vs tungsten/dumbo | TERRAIN.md §10 framing is not universal; only §10.3's property encoding is. |
| block-7 stream ends 72 B (not 64) before block end; levelMax 5 | eastwood | Minor format drift; 8 bytes unexplained. |
| Backdrop meshes shipped complete but placed from the LEVEL ROOT partition | eastwood (check others) | Explains missing skylines for any walk that skips `mp_<level>.ebx` itself. |
| Scatter join unvalidatable: all 65 SingleTerrainLayerData have empty MeshScatteringTypes, yet the 46 KB catalogue ships; clutter is a generated 3,044-object layer | eastwood | The fleet's scatter-join question needs a different map; here scatter is walkable placements. |

---

## G. Next steps for the plugin, in priority order

1. **Make trailer decomposition per-chunk, not per-map**
   (`addons/highpoly_toggle/bf6_splat.gd::detect_layout/color_tiles/node_pages`).
   Detect the page size per map by exact decomposition (eastwood verifies
   2592), then decompose each chunk's trailer against the tile catalogue
   {4624, 17424, 67600, 85024} with prefixes {0, 39919, 149297, 189216} and
   sums of two. Take the FIRST tile (85024 -> the 260² tile). Verification:
   eastwood must yield 133 x 17424 + 19 x 85024 + 5 x none, and weight pages
   must land on 2592-byte boundaries (today every eastwood page is read
   12,800 bytes early).
2. **Render LakeData water** (`addons/highpoly_toggle/highpoly_gamesource.gd`,
   new `lakes()` beside `water()`): read the 20 polygons out of the terrain
   `decals.ebx` partition (or `_layers_content/water.ebx` + area layers),
   triangulate each closed spline at its constant Y, give them the existing
   water material. This — not the buried ocean plane — is what water means on
   eastwood, and it is 20 real meshes for a few hundred points. Check other
   maps for LakeData while there.
3. **Sample albedo for painted layers too**
   (`addons/highpoly_toggle/bf6_terrainlayers.gd` / `bf6_materialtree.gd`):
   22 of eastwood's textured layers are painted-side; base-only sampling
   throws away most of this map's ground detail.
4. **Include the level-root partition in the placement walk**
   (`highpoly_gamesource.gd` / `highpoly_mapcontext.gd`): `mp_eastwood.ebx`
   imports all 134 backdrop mesh partitions (buildings, vegetation, vista
   terrain skirts, storm drains). Whatever walks layers/subworlds must also
   walk `mp_<level>.ebx` or eastwood has no skyline.
5. **Water-buried diagnostic** (same as MAP-TUNGSTEN.md G5): log
   "water surface at y 3.1 is 171.7 m below the lowest ground — not drawn",
   and when that fires, ALSO report whether the level ships LakeData so the
   log names the real water. Use basis-row length, not basis.x.x, for extent.
6. **Adapt the decals reader per map** (research repo
   `impl/pipeline/bf6_decals.py`, plugin decal path): eastwood's record
   framing differs; the property-entry scan (probe_eastwood_decals.py) is a
   robust interim census. 61 puddle decals + 42 environment decal volumes are
   water-adjacent content worth surfacing once decodable.
7. **Colour map on eastwood is high-value**: the vista ring is literal
   satellite imagery — once (1) lands, enabling
   `MapContext.colormap_enabled` transforms this map's backdrop ground for
   free. Verify mean ≈ (0.40, 0.42, 0.40) and the neutral-grey playable core.
8. **Push upstream to BF6_Frostbite_Research**: TERRAIN.md §5.2/5.3 (trailer
   tile size varies per node within a map; 85024 mip pair on eastwood),
   §10 (record framing per-map), and note eastwood's rotated water basis in
   the water findings file.
