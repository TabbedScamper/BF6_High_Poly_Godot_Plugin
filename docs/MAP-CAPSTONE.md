# MP_Capstone, end to end

MP_Capstone read from the shipped 2026-08-01 pull, applying the laws established
in `MAP-TUNGSTEN.md` and recording where this map confirms, refines or
contradicts them. **Every claim is tagged MEASURED or HYPOTHESIS**; a MEASURED
claim names the resource/value and the probe that reproduces it.

Probes: the shared `probe_tung_*.py` set (they all take a level argument) run
with `mp_capstone`, plus three new capstone probes beside this document:

```
tools/probe_capstone_decomp.py       chunk decomposition table + BC7 trailer walk
tools/probe_capstone_colorrender.py  real BC7 colour-map assembly -> PNG + mean test
tools/probe_capstone_volumes.py      environment decal volumes + reflection volumes
```

Everything is read-only against the dump; nothing touched the plugin, its
shaders, or any `user://` cache.

---

## 0. The map in one paragraph

**MEASURED.** MP_Capstone is a 4,096 x 4,096 m world (block 0 root AABB
`x,z ∈ [-2048, 2048]`), ground from **y = 66.99 to y = 1622.66**, `WorldSizeY =
1705.0` — the coarsest height quantisation seen yet (2.60 cm per u16 step vs
1.59 on tungsten, 0.39 on dumbo). 197 streaming nodes, 31 compiled terrain
layers (of 47 authored — see B4), 546 terrain-decal records in 33 texture-set
groups, **zero water surfaces of any kind**, 218 `LayerData` partitions (129
with zero Objects), 22 ECS runtime prefabs of which **one is populated**. It is
the host level for King of the Hill (`kingofthehill*` partitions sit at the
level ROOT, not under `_layers_gameplay`), plus FreeRoam, Payload and
ModBuilderCustom0-3 content. Central-Asia asset library (`cas_`) with a
West-US-mountain (`wum_`) terrain palette: a mountain map with a village in the
central valley.

---

## A. Water

**MEASURED — MP_Capstone has NO water entity at all.**
`probe_tung_types.py mp_capstone --find "water|ocean|river"` over all 1,382
partitions finds no `WaterSurfaceEntityData`, no `WaterAsset`, no
`WaterEntityData`, and no `WaterLevelDescriptionComponent` (tungsten has all
four). The only hits are:

| partition | type |
|---|---|
| `lighting/ve_mp_capstone_base_01.ebx` | `OceanComponentData` (VE preset boilerplate) |
| `_layers_content/water.ebx` | `LayerData` with **`Objects = []`** (416 bytes) |
| `_layers_content/water_shared_schematic.ebx` | schematic plumbing, no surface |

**MEASURED.** Terrain floor is y = 66.99 (block 0 root AABB min). There is no
water height to compare it against — the A3 table of MAP-TUNGSTEN.md gets a new
row class: `mp_capstone | (no entity) | 66.99 | absent | nothing to draw`.

This confirms the tungsten finding from the other side: `OceanComponentData` in
the active VE preset is present on maps with, without, and now *entirely
without* any water surface, so it predicts nothing. The plugin's
`highpoly_gamesource.gd::water()` returns nothing here and that is CORRECT
behaviour for this map; the diagnostic log line proposed in MAP-TUNGSTEN G5
should distinguish "entity absent" (capstone) from "entity buried" (tungsten,
eastwood).

**MEASURED — the braided channels visible in the colour map are dry.** The
rendered colour map (C2) shows braided drainage in the valleys; no water layer,
no river layer, no water decal slot exists anywhere in the level.
`_layers_world` has no river/creek partitions at all (unlike tungsten's empty
ones).

---

## B. Terrain and ground layers

### B1. Palette: 31 layers; every albedo is on the base side, but painted
### layers CAN bind non-albedo textures here

**MEASURED.** `terrain_mp_capstone.VisualTerrain` (622 B): `layerCount = 31`,
`SurfaceShaderBlockKey 0x43DB1AAE19A710A9`, links **L26 -> L25** and
**L28, L29, L30 -> L27**. `probe_tung_layers.py mp_capstone`: the layer-graph
record table is at **offset 152 with 31/31 keys resolving** in the paired depot
(9,624 B; 31 keys over 26 content-deduplicated records, 51 texture parameters,
228 inline constants; the layer-graph RES itself is 1,164 B). The weak
"keys distinct" rule fires at offset 84 — 68 bytes earlier, exactly the same
delta as tungsten — and resolves nothing. MAP-TUNGSTEN's table-location law
verified.

Splat side (block 1): `LayerSlotCount = 6` (same as tungsten, vs 62 on dumbo —
meaning still unknown), 229 nodes, 16,341 records, slack 0. Painted vs base
split, with block-1 record counts (out of 916 node-records carrying base
entries) and textures from the depot join:

| L | side (records) | textures bound |
|---|---|---|
| 00 | BASE x916 | none |
| 01 | painted x125 | none |
| 02 | painted x171 | `t_com_asphaltdetail_02_ncs` (detail only) |
| 03 | painted x54 | `t_com_asphaltdetail_02_ncs` (detail only) |
| **04** | BASE x916 | `t_cas_asphaltedge_01_{cv,nhs,ao,op}` |
| **05** | BASE x916 | `t_cas_asphaltedge_01_{cv,nhs,ao,op}` |
| 06 | painted x211 | none |
| 07 | painted x208 | none |
| 08 | painted x916 | none |
| 09 | painted x699 | **no parameters at all** (empty depot record) |
| 10 | painted x100 | none — but carries tint `0x4FDCF6B1 = (1.364, 1.281, 1.025)`; **the background layer** |
| 11 | painted x97 | empty record |
| 12 | painted x92 | empty record |
| 13 | painted x888 | none |
| 14 | painted x18 | `t_com_asphaltdetail_02_ncs` (detail only) |
| 15 | painted x916 | `t_gen_breakupmask_02_rgba` (mask only), tint (0.732, 0.702, 0.681) |
| **16** | BASE x916 | `t_ter_defaulttexture_{cv,nhs,ao}` (placeholder set) |
| **17** | BASE x916 | `t_cas_asphaltedge_01_{cv,nhs,ao,op}` |
| 18 | BASE x916 | `t_ter_defaulttexture_ao` only + `0x7E604C6D = (0,0,0)`, `0x7AF79259 = 0.7` |
| 19 | painted x162 | empty record |
| 20 | painted x14 | none |
| 21 | painted x32 | none, tint (0.614, 0.598, 0.579) |
| 22 | painted x23 | empty record |
| 23 | painted x29 | empty record |
| 24 | painted x658 | none |
| **25** | BASE x916 | `hfd_debug` at slot **`0xAE16A5C0`** — the crater layer |
| **26** | BASE x916 | `t_wum_asphaltedge_01` + `t_wum_crackedconcrete_03` (6 tex) — links to L25 |
| **27** | BASE x852 | `t_wum_ls_gravel_02_a+b` + `t_wum_crackedconcrete_03` (9 tex) |
| **28** | BASE x916 | `t_wum_ls_gravel_01_a` + `t_wum_td_sand_01_ncs` — links to L27 |
| **29** | BASE x916 | `t_wum_dryrockygravel` + `t_wum_td_sand_01_ncs` — links to L27 |
| **30** | BASE x916 | `t_wum_concretedebris_01+02` (6 tex) — links to L27 |

**MEASURED — the refined law.** Every layer binding an ALBEDO (`_cv`) texture is
a BASE layer (L04, L05, L16, L17, L26-L30). But unlike tungsten (where the
split was absolute), **four painted layers bind textures — all non-albedo**:
detail `_ncs` (L02, L03, L14) and a breakup mask (L15). A consumer that treats
"painted layer has a texture parameter" as "painted layer has colour" will be
wrong here. The correct statement is: **albedo lives exclusively on the base
side; painted layers bind at most detail/mask textures.**

**MEASURED — crater structure confirmed with different link topology.**
`0xAE16A5C0` (crater/heightfield-decal slot, identified on tungsten) is bound by
exactly one layer, L25. But the link graph differs from tungsten's single hub:
capstone has **two** link groups — L26 -> L25 (crater), and L28/L29/L30 -> L27
(the wum gravel family). Tungsten had all four linked layers on the crater. So
"linked layers all point at the crater layer" is NOT a law; linked layers form
per-family groups.

**MEASURED — six layers share one contentHash.** L09, L11, L12, L19, L22, L23
all have `contentHash 04B2008FD98C1DD4` and empty depot records: six painted
layers whose appearance is entirely in the compiled layer-graph program (same
class as tungsten's L22-L27).

Constants (verify of MAP-TUNGSTEN B2): `0xCF3F97E0` is again integer-typed with
values **0/2/4 only**; `0xCBB9A946` is again **(0,0) on all 31 layers**;
`0x4C200FE0` values here: 0.0, +0.005, +0.010, +0.015 (no negatives on this
map); `0x2F9990B7` spans 0.328..150 (no 1300-class values — tungsten's
crater-adjacent magnitude class does not recur); `0xF7652FB3` spans 2.0..45.0.
**HYPOTHESIS:** `0x4FDCF6B1` (float3, per-layer, e.g. background L10 =
(1.364, 1.281, 1.025), L15/L21 = grey-browns) is a per-layer albedo tint for
textureless layers — it only appears on layers with no or partial texture sets,
and its values are plausible ground colours. Not proven; worth testing in
`bf6_terrainlayers.gd` as a fallback colour source.

### B2. Streaming tree and blocks

**MEASURED.** `probe_tung_terrain.py mp_capstone` — all blocks walk byte-exact
(slack 0; block 7's node stream ends exactly 56 bytes = its 12-pair footer
before block end; 0 bad nibble-RLE rows):

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 197, PersistentNodeCount 192
block 0  heights    13,590 B  xs=265, WorldSizeY=1705.0, 197 nodes (5 Packed, 192 External)
block 1  splat     541,374 B  LayerSlotCount=6, 229 nodes, 16,341 records
block 4  mask        2,189 B
block 7  material 4,999,561 B dim=256, 12 pairs, bg=0x0660FA80
block 8  mask      272,187 B  dim=265, 93 nodes, levelMax=4, maskUnknown0=4
```

No block 2 (density) and no block 5 — tungsten ships both. The block set is
per-map; readers must not assume any optional block.

### B3. Block 7 — pairs and the honest ceiling, inverted

**MEASURED.** `probe_tung_basefield.py mp_capstone`: `pairCount = 12` (5 unused),
`BackgroundMaterialIndex = 0x0660FA80` -> **L10** — numerically identical to
tungsten's background pair value, resolving to the same index 10, on a
completely different palette. **HYPOTHESIS:** `0x0660FA80`-as-background is a
tooling default, not map-specific authoring.

Pair -> layer: p0->L02, p1->L04, p2->L12, p3->L05, p4->L00, p5->L01, p6->L04,
p7-p11 unused. Texel share of the resolved base field (pooled all levels):

```
L05  42.9%   t_cas_asphaltedge_01 (textured base)
L04  36.4%   t_cas_asphaltedge_01 (textured base)
L02  11.6%   detail ncs only
L12   7.8%   empty depot record
L01   0.9%   textureless
L00   0.4%   textureless
```

**MEASURED — 79.3% of decoded block-7 texels resolve to a layer with an
albedo** (L04+L05). Tungsten's honest ceiling was 20.6%; capstone is the
opposite extreme. The two asphaltedge layers covering 4/5 of the base field
cannot literally be asphalt everywhere — **HYPOTHESIS:** their `_op` opacity
texture gates the asphalt detail and the layer's shader computes the ground
beneath, i.e. "has an albedo" still does not mean "the albedo is the ground
colour". The colour map (C) remains the dominant colour source.

### B4. 47 authored layers vs 31 compiled

**MEASURED.** `terrain_mp_capstone.ebx` holds a `TerrainData` with
**`TerrainLayers = [47 items]`** — 47 `SingleTerrainLayerData` instances — while
the compiled `VisualTerrain`/layer-graph carries 31. The authored list is not
index-aligned with the compiled palette; anything joining authored-side data to
compiled layer indices needs an explicit mapping (not derived here — the 47
instances carry no name and no distinguishing field in this level).

**MEASURED — the scatter join can NOT be validated on this map.** All 47
`SingleTerrainLayerData.MeshScatteringTypes` are **empty**. The level's
`MeshScatteringDatabase` RES exists but is only 14,869 bytes. Capstone gives
zero leverage on the Identifier-join question from the brief; it stays
UNVALIDATED.

---

## C. The colour map and THE DECOMPOSITION TABLE

### C1. Decomposition (probe_capstone_decomp.py) — the detect_layout verification row

**MEASURED.** Every one of MP_Capstone's 281 streaming chunks (197 primary + 84
paired) decomposes exactly, with zero residual, page size **4,356**:

```
192 primary   size = 149,297 + N x 4,356 + 1 x 17,424     (N = 16..42)
  5 primary   size =       0 + N x 4,356 + 0              (keys 0x3, 0x30..0x33 — the 5 Packed nodes)
 84 paired    size =       0 + N x 4,356 + 4 x 17,424     (69,696 = pure 4-tile chunks when N=0)
```

- Height prefix is always exactly **one** 149,297-byte payload (xs=265) — no
  doubled prefixes here (tungsten has 2x149297 chunks).
- The trailer is **ONE** 17,424-byte tile = 132x132 BC7, and it is the **LAST**
  thing in the primary chunk. There is **no second degenerate tile** on this
  map. Paired chunks end with **four** child tiles (reversed child order per
  MAP-TUNGSTEN / bf6_colormap.py), also last.
- Expected page size from the brief's table: 4,356 — **confirmed**.

BC7 mode histogram, first vs last trailer tile (identical — there is only one),
pooled over 189 image-bearing primaries:

```
colour tile: 205,821 blocks   modes 4-7: 99.60%   m6:198,913  m4:3,309  m5:1,732  m7:1,048  m3:752
bytes immediately before it:  modes 4-7 ~2-6%, ~35% zero/invalid first bytes  -> BC4 weight pages, not a tile
```

**MEASURED — a threshold warning for the detect fix.** Three depth-5 colour
tiles score 0.86-0.90 on the modes-4-7 test (still mode-6 dominated: e.g.
0x320022 at 86.0% with m6=829 of 1089). A >= 0.98 or even >= 0.95 cut would
misclassify real colour tiles on this map; discriminate degenerate tiles by
their tungsten signature (ONE distinct block repeated 1,089x, mode-3 dominated)
rather than by a high modes-4-7 bar alone.

Consequence of the current `bf6_splat.gd::detect_layout` pick of (2592, 4624)
(MEASURED cross-map in MAP-TUNGSTEN C3, capstone included): on this map the
weight pages are sliced misaligned and decoded with the BC4 codec although
capstone's 4,356-byte pages are raw 66x66, and `color_tiles()` hands the last
4,624 bytes — a misaligned tail window of the real 132x132 tile — to the BC7
decoder as a 68x68 image. Wrong page codec, wrong page size, wrong tile size:
three faults from one detector.

### C2. The rendered colour map

**MEASURED.** `probe_capstone_colorrender.py` decodes each primary chunk's last
17,424 bytes as 132x132 BC7 (via `bf6_colormap.py`'s DDS wrap), crops the 2px
apron, and blits coarse-first over the root AABB. Output:

```
%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Capstone.png
189 of 197 primaries contributed; 8 skipped (5 packed no-trailer + 3 below the 0.90 cut)
assembled mean RGB (0.464, 0.411, 0.377)   SDK overhead mean (0.563, 0.513, 0.456)
depth-3 tiles, full BC7 decode: mean RGB (0.449, 0.396, 0.363), mean ALPHA 0.011
```

**It reads as a fully coherent aerial photo** — mountain ridges with dark rock
faces, pale braided drainage in the valleys, the central village clearly
resolvable, roads traceable — same warm ordering R>G>B as the SDK overhead, no
channel swap; the level offset vs the overhead (~0.10/channel) is consistent
with the overhead including lit props and buildings. Alpha near zero matches
tungsten's colour-tile signature.

---

## D. Decals, roads, volumes

### D1. Terrain decals

**MEASURED.** `probe_tung_decals.py mp_capstone`: `decals.TerrainDecals` is
6,164,616 bytes — **546 records, all parsed, 0 chain breaks** (the FirstIndex
chain invariant holds map #2 for 2). `slotCount 31` = the compiled layerCount
(law holds). **5 asset slots used — including sentinel 65535:**

```
slot 17   301 recs  34,134 tris     slot  5    82 recs
slot  4    95 recs  12,512 tris     slot 18    42 recs
slot 65535 26 recs     828 tris     <- EMPTY guid, sentinel slot
```

Slots 4, 5, 17, 18 are exactly the four cas/default textured BASE layers (L04,
L05, L17, L18) — the tungsten pattern (decal slots = textured base-layer
indices) confirmed. **New:** the 65535 sentinel slot with 26 real records, and
one texture-set group that binds NOTHING at all (27 records with an empty set).
A reader keying decals by slot -> layer must accept 65535, and one keying
materials by texture set must accept the empty set.

33 texture-set groups; largest: `t_cas_erosiongravel_02` x73,
`t_cas_dirtroad_03` x46, `t_cas_roadvariationmask_01_rgb` (**`_op`-only mask
group, x41** — the no-basecolor class again, 3x bigger than tungsten's),
`t_cas_ridgemudrock_05` x39, `t_cas_groundroadtrack_01` x37,
`t_cas_concretecracked_01` x29. Mixed-library groups recur (naf_ tiretracks
_cv over cas_ ao/nhs; seu_ asphalt patches) — group by whole texture set, never
by one slot.

**MEASURED — coverage box.** All 546 records live in x -1,323..1,806,
z -1,156..1,287, y 68.2..181.5 (above the 66.99 floor — no below-floor AABBs
here, unlike tungsten). The outer ~700 m ring of the world square carries no
terrain decal.

### D2. Environment decal volumes — capstone's share of task #52

**MEASURED.** `probe_capstone_volumes.py`: **88 `EnvironmentDecalVolumeData`
instances** under the level:

| where | count |
|---|---|
| `_layers_world/area_01.ebx` | 53 |
| `_layers_world/area_02.ebx` | 7 |
| `_layers_world/area_05.ebx` | 4 |
| `_layers_world/area_04_decals.ebx` | 2 |
| `prefabs/pfw_cas_houseruralsmall_02_a_propsb(.+autogen)` | 10 + 10 |
| `lighting/lightfixture/pf_lf_naf_fluorescentlamp_tube_01_deco_wedv(_blue)` | 1 + 1 |

Every instance carries: `Enable`, `Alpha` (1.0), `InstanceParams` (1,1,1),
`OverrideTemplateCullingDistance` (10.0 typical), a full 3x4 `Transform`
whose basis vectors have the volume's extents baked in as scale (world-layer
max-axis lengths 0.7..11.8 m, median 3.9), and a `Template` import that
resolves through the dump guid index to a shipped template partition:

```
x22  common/environment/textures/decals/sootdecals_01/decalvol_sootnoisy_triprojected_c
x15  .../decalvol_sootnoisy_triprojected_b        x12  .../decalvol_sootnoisy_triprojected_d
x4   .../props/decals_01/edv_cas_graffitischoolhouse_01_{c,d,e}   (x4 each of c,d,e)
x3   .../decals/ashdust_01/decalvol_ashdust_triprojected_c
x2   common/lighting/volumedecals/edv_gobolight_fluorescentlamp   (the light-gobo pair)
     + 12 more singletons (graffiti, soot, ash variants)          = 25 distinct templates
```

The 66 world-layer instances sit at x -215..220, y 131..171, z 67..322 — the
central village only. **The placer join is: instance Transform (world, in the
world layers; prefab-local in prefabs) + Template partition GUID -> guid index
-> `decalvol_*` / `edv_*` template EBX, which carries the projected texture.**
The Transform's row field hashes are unnamed in the field tables (0xC478CC3B /
0xBF151EF9 / Forward / 0xBC4B07B4 = right/up/forward/trans by position);
**HYPOTHESIS:** basis lengths are the box half-extents of a unit cube — matches
the 0.7-11.8 m magnitudes but unverified against the renderer.

### D3. Reflection volumes — capstone's share of task #51

**MEASURED.** **57 `PbrBoxReflectionVolumeEntityData`** + **1
`PbrDistantReflectionVolumeEntityData`**:

- **53 box volumes in `_layers_content/lighting.ebx`** — world transforms,
  basis-vector lengths 3.5..38.5 m per axis, positions bounded x -251..356,
  y 127..200, z 0..552: the playable town, one volume per interior/courtyard
  scale space. Examples: ext(26.3, 4.0, 10.2) @ (-162, 139, 169);
  ext(38.5, 10.9, 14.8) @ (-26, 136, 125).
- **4 in the hescotower prefab family** (`pf_cas_mil_hescotower_01*`) —
  prefab-local, one per variant.
- **1 distant volume**: ext (4096, 4096, 4096) @ (0, 200, 0) — whole-world,
  with `CaptureSky`/`CaptureFog`/`BakedTexture`/`ObjectLayers` fields decoded
  and readable (probe prints them; `Mode`, `CaptureDistance`,
  `InfluenceFadeNormal` etc. all present by name).

So the map's reflection lighting is: one world-sized distant capture + 53
hand-placed interior boxes, all in ONE partition (`_layers_content/lighting.ebx`)
— a placer can read a single file to get all of them.

### D4. Prop lights, gobo decals

**MEASURED.** `lighting/lightfixture/` ships 5 fixture prefab/mesh sets (22
files: `lf_ind_walllamp_rect_01`, `lf_ind_warninglamp_bulb_01`,
`pf_lf_naf_fluorescentlamp_tube_01_deco_wedv{,_blue}` + meshes/physics). The
`_wedv` fixtures each embed an `EnvironmentDecalVolumeData` bound to
`edv_gobolight_fluorescentlamp` — a light-shaped projected decal, i.e. fake
light splash shipped as a decal volume. Relevant to the prop-lights task: on
this map some "lights" are decal volumes, not light entities.

---

## E. Everything else notable

**MEASURED — backdrop/skyline meshes exist and are complete.** The
missing-skyline task has real data here:

- `backdrop/terrain/`: **8 terrain skirt sectors, each in near+far variants**
  (`bd_cas_terraincapstone_0N_{near,far}` with `.MeshSet`, near variants also
  `.physics.PhysicsResource`), each with its own baked texture triplet
  `t_bd_cas_terraincapstone_0N_{near,far}_{rgb,cs,na}` — per-sector baked
  colour, so backdrop terrain needs no splat pipeline at all.
- `backdrop/buildings/`: 6 `bd_cas_vegetationcapstone_0N_mid` vegetation-card
  meshes + `bd_tr_com_*` tree backdrop meshes (oliverussian, poplarwhite in
  l/m sizes), all with MeshSets.
- `lighting/backdrop/`: a `backdrop_mesh.MeshSet` dome with `t_backdrop_cs/nea`
  textures (the sky/mountain dome).

**MEASURED — one populated ECS prefab.** `probe_tung_ecs.py mp_capstone`: 22
prefabs, 21 the empty `ent=1 arch=1 seg=1 edits=0 comps=[26]` stub, and
`_layers_world/area_02_ecsprefab_ecsprefab.ebx` = **ent=3 arch=3 seg=6 edits=2
comps=[0,42,54,58]** (3,366 B). So capstone joins dumbo/aftermath as a map
shipping populated ECS content, at small scale; the stub-is-boilerplate law
holds (the other 21 coexist with full layers).

**MEASURED — cloud-shadow mask.** The map ships
`lighting/t_mp_capstone_cloudshadow_05.Texture` and
`t_mp_capstone_secondarycloudshadow_05.Texture`; both are imported by
`lighting/ve_mp_capstone_base_01.ebx` (import-table join, exactly one
referencing partition). Its `OutdoorLightComponentData` decodes with
`CloudShadowSize = 4096.0`, `CloudShadowCoverage = 0.3`,
`CloudShadowExponent = 8.0`, `CloudShadowSpeed = (0,0)`,
`CloudShadowIsTopDown = true`, `SecondaryCloudShadowSize = 40000.0`.
`CloudShadowTexture` prints as null in the deser while the partition imports the
texture — **HYPOTHESIS:** the deser renders this texture ref as null (the
blueprint instance [0] fails to decode; the binding may live there). VE preset
set is small: `base_01`, `interiors_01`, `thermal`.

**MEASURED — naming oddities that would confuse a placement walk:**

- `kingofthehill*` partitions (incl. its own `win32_shaderstate` depot) sit at
  the LEVEL ROOT, not under `_layers_gameplay` — a walker keyed on
  `_layers_gameplay` misses an entire game mode.
- `decals.TerrainDecals` lives at the doubled path
  `terrain_mp_capstone/terrain_mp_capstone_game/glaciermp/levels/mp_capstone/mp_capstone/decals.TerrainDecals`.
- `_layers_world` contains non-area layers: `world.ebx`, `roads.ebx`,
  `proceduralroads/` (own subworld + shaderstate), `predestruction.ebx`,
  `asphalt`, `dirtroads`, `shared_cq_esc_subworld.ebx`, and per-gamemode
  `*_subworld` partitions (payload/rush/squaddeathmatch/teamdeathmatch/
  strikepoint) — subworlds are not only `area_NN`.
- `_layers_gameplay` carries `area_0N_name_blockout_{blueprints,destruction}`
  (zero-Object placeholders) and generated `dd_modbuildercustom0-3_volumes`.
- `_layers_world/generated/ag_aftermathscatter_aftermathentities_0652cbde.ebx`
  is the single busiest LayerData in the level (380 Objects) — a *generated*
  scatter layer named "aftermath" on a map that is not mp_aftermath.
- `area_01hq_ecsprefab_3_ecsprefab.ebx` (note the `_3`).

**MEASURED — structure.** 218 LayerData partitions (129 zero-Object). Busiest:
the generated scatter layer (380), `area_06` (278), `area_02` (221),
`fx_global` (220), `occluders` (188), `area_04` (170). Eight
`area_0N_subworld`s + backdrop_subworld with per-subworld physics
(1.2-8.3 MB) and meshvariationdbs. 43 ShaderBlockDepots; ten gamemode depots are
byte-identical (`shaderblockdepot_9526102139013923511`, 1,988,880 B — KOTH,
breakthrough, conquest, domination, escalation, operations, payload, rush,
squaddeathmatch, strikepoint, teamdeathmatch). Biggest files are lighting:
enlighten highend 85.8 MB / lowend 47.0 MB, materialgrid 15.3 MB.

---

## F. Generalisation — what holds, what this refines, what it contradicts

| finding | scope | notes |
|---|---|---|
| Page size 4,356 / tile 17,424, exact decomposition with prefix 149,297 | capstone row CONFIRMS the brief's table and the detect_layout fix design | C1 |
| **CONTRADICTS a tungsten generalisation: the trailer is ONE colour tile here, and it is LAST.** "Take the first tile of the trailer" is wrong on capstone; "take the last" is wrong on tungsten. The rule must be: count the trailer's tiles and pick the IMAGE one by BC7 signature | every map | C1; also the 0.90-threshold warning — real tiles score as low as 0.86 |
| No second degenerate tile exists on this map | capstone (and by bf6_colormap's survey, the other single-tile maps) | C1 |
| Albedo textures live exclusively on base-side layers — but painted layers CAN bind detail/mask textures (4 do here) | every map (refines tungsten's "absolute" split) | B1 |
| `0xAE16A5C0` = crater slot, exactly one layer binds it | confirmed | L25 |
| Linked layers do NOT all point at the crater layer — two link groups here (L26->L25, L28/29/30->L27) | contradicts a possible tungsten generalisation | B1 |
| `0xCF3F97E0` integer 0/2/4; `0xCBB9A946` = (0,0) everywhere | confirmed | B1 |
| `BackgroundMaterialIndex = 0x0660FA80` on BOTH tungsten and capstone, resolving to index 10 on different palettes | HYPOTHESIS: tooling default | B3 |
| Decal slots = textured base-layer indices | confirmed, PLUS sentinel slot 65535 with real records and an all-empty texture-set group | D1 |
| Water diagnosis needs a third state: entity ABSENT (capstone), not just buried vs above-floor | every map | A |
| Empty-stub ECS prefab is boilerplate; populated ones ship where authored | confirmed (21 stubs + 1 populated) | E |
| Layer-graph table located ONLY by 100%-depot-resolution; weak rule fires 68 bytes early | confirmed — same 68-byte delta, twice now | B1 |
| `LayerSlotCount = 6` again (tungsten 6, dumbo 62) | still unknown meaning; now two 6-maps | B2 |
| Optional streaming blocks are per-map (capstone: no block 2, no block 5) | every map | B2 |
| Authored TerrainLayers (47) != compiled layerCount (31) | new; joins to authored data need a mapping | B4 |
| Scatter Identifier join: UNVALIDATED — capstone's MeshScatteringTypes are all empty | unchanged | B4 |

Plugin failures this explains: capstone's ground currently decodes weight pages
as misaligned BC4 and its colour map as a misaligned 68x68 window of the real
132x132 tile (C1) — the same detect_layout root cause as tungsten, with the
*same* fix verified by a different decomposition. Water: nothing was ever going
to render and nothing should. High ceiling (79% albedo texels) plus a coherent
colour map means capstone should look GOOD once detect_layout and the colour
path are fixed — a strong before/after showcase map.

---

## G. Next actions for the plugin, in priority order

1. **`addons/highpoly_toggle/bf6_splat.gd::detect_layout`** — same fix as
   MAP-TUNGSTEN G1; capstone's verification row: page 4,356, trailer exactly
   `1 x 17,424` after a single `149,297` prefix on 192/197 primaries, 5
   pages-only chunks with zero prefix. Add capstone to the fix's test set.
2. **`bf6_splat.gd::color_tiles` / `node_pages`** — implement "count trailer
   tiles, choose the image tile by signature". Use a mode-6-dominance /
   distinct-block test, NOT a >= 0.95 modes-4-7 bar (three real capstone tiles
   sit at 0.86-0.94). On this map the answer is simply the last 17,424 bytes.
3. **`addons/highpoly_toggle/highpoly_mapcontext.gd`** — enable the colour map
   here once 1-2 land; capstone is the showcase (assembled map is a clean
   aerial photo; FIXED_MP_Capstone.png is the reference output, mean
   (0.464, 0.411, 0.377)).
4. **`addons/highpoly_toggle/highpoly_gamesource.gd::water()`** — three-state
   log: entity absent (capstone) / buried (tungsten) / above floor (dumbo).
   Capstone must not report an error for finding nothing.
5. **Reflection volumes (task #51)** — read
   `_layers_content/lighting.ebx` only: 53 box volumes + 1 distant volume with
   world transforms, one file per map on this evidence. Placer join is direct;
   prefab-embedded ones (4 here) come free with prefab expansion. Touches the
   placement walker (`highpoly_gamesource.gd` or its successor).
6. **Environment decal volumes (task #52)** — 88 here, 66 world-placed with
   full transforms; Template GUID -> guid index -> `decalvol_*`/`edv_*`
   template EBX carries the texture. Worth a `bf6_decalvolumes.gd` reader;
   verify the basis-length = half-extent hypothesis against one known volume
   in the editor first.
7. **Backdrop (skyline task)** — capstone's backdrop is fully shipped and
   self-textured (8 near/far skirt sectors + vegetation cards + dome, E).
   The per-sector `_rgb/_cs/_na` bake means no terrain pipeline is needed to
   draw it; a loader that just places `bd_cas_terraincapstone_*_far` +
   `lighting/backdrop` gets the whole horizon. Touches the mesh spawner.
8. **`bf6_terrainlayers.gd`** — try `0x4FDCF6B1` as textureless-layer tint
   (B1 HYPOTHESIS); background layer L10's (1.364, 1.281, 1.025) over the
   colour map is directly testable against the SDK overhead.
9. **Gamemode walker** — handle root-level gamemode content (`kingofthehill*`
   at level root) and non-area subworlds (`proceduralroads`, per-mode
   `*_subworld`) — wherever the layer/subworld enumeration lives.
