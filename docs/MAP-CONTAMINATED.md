# MP_Contaminated, end to end

Study of MP_Contaminated against the laws in `docs/MAP-TUNGSTEN.md` and
`BF6_Frostbite_Research/formats/TERRAIN.md`. **Every claim is tagged MEASURED or
HYPOTHESIS**; a MEASURED claim names the resource and the probe that reproduces
it. Probes are in `tools/probe_contaminated_*.py` (new, this study) plus reruns
of `tools/probe_tung_*.py <level>` (Tungsten's, parameterised). All reads go
through `BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`; read-only
throughout; the plugin, its shaders and `user://` caches were not touched.

```
probe_contaminated_decomp.py       chunk-size decomposition, detect_layout simulation
probe_contaminated_decomp2.py      the 936 law, paired-chunk tile census, BC7-vs-BC1
probe_contaminated_bc1.py          BC1 signature test (c0>c1) + endpoint means
probe_contaminated_colorrender.py  BC1 colour map assembled to PNG, both child orders
probe_contaminated_scatter.py      MSDB catalogue + the per-layer scatter join (fleet scan)
probe_contaminated_fx.py           placed FX by blueprint + blueprint graph shapes
probe_contaminated_decals.py       chain-anchored TerrainDecals walk (full 1053)
```

**Headline: three of the established laws break on this map** — the colour
raster is **BC1, not BC7**; it lives in the **paired** chunks, not the primary;
and the painted/base texture split is **inverted** (painted layers here are
texture-rich). Also: **there is no water entity at all**, and the per-layer
scatter join the fleet was asked to validate **has an empty right-hand side on
every level in the game** (17 checked, granite included).

---

## 0. The map in one paragraph

**MEASURED.** MP_Contaminated is a 4,096 x 4,096 m world (block-0 root AABB
x,z in [-2048, 2048]), ground **y = 17.428 to 785.0**, `WorldSizeY = 785.0`
(u16 step 1.2 cm), 265 samples per node, **341 streaming nodes** (105 height
nodes: 5 Packed, 100 External). Terrain palette **50 layers**; block 1 has
`LayerSlotCount = 62`, 865 nodes, 65,389 records; blocks shipped are 0, 1, 4,
7, 8 (**no block 2 density map, no block 5**). 1,053 terrain-decal records in
79 texture groups. **327 LayerData partitions, 162 with zero Objects**; 12
`area_NN` subworlds plus `world.ebx`; 39 ShaderBlockDepots; 98
EcsRuntimePrefabAssets of which **97 are the empty stub and one is populated**.
The biggest file is `lighting/enlighten_mp_contaminated_highend` (94.8 MB).
The level also carries `_layers_marketing` and an `fx_gasmodedisabled` layer —
the map's gas theme is switchable per mode.

Verification of the shared parsers on this map: block 0 walks slack 0, block 1
slack 0 (65,389 records), block 7 material rows decode with 0 bad rows, the
chunk directory consumes to the final byte (`probe_tung_terrain.py
mp_contaminated`, `probe_contaminated_decomp.py`). One deviation: the block-7
node stream ends **56 bytes past** the expected footer position (`slack=-56`
in `probe_tung_basefield.py`; Tungsten ends exactly at its 64-byte footer).
The footer itself self-locates and resolves, so the extra 56 bytes are between
stream and footer. Unknown what they hold.

---

## A. Water

**MEASURED — there is NO water entity in this level.** `probe_tung_types.py
mp_contaminated --find "water|ocean|river"` over all 1,471 partitions finds
exactly one hit: `mp_contaminated/description.ebx`
(`WaterLevelDescriptionComponent`). No `WaterSurfaceEntityData`, no
`WaterOceanSimulationEntityData`, no `WaterAsset`, no `OceanComponentData`.
`_layers_content/water.ebx` exists but is a `LayerData` with `Objects = []`;
`water_shared_schematic.ebx` holds only schematic plumbing (SchematicChannel /
MathOp / AreaProximity / PropertyCast entities), no surface.

**MEASURED — the only water is a backdrop MESH.**
`backdrop/water/water_contaminated_mesh.MeshSet` (+ its `.physics.
PhysicsResource`) ships under the level, and its object partition GUID is
imported by `_layers_world/world.ebx` — the level's own `SubWorldData`, which
carries a `StaticModelGroupEntityData` (probe: scratch `findrefs.py` logic,
GUID-in-imports scan). So whatever water the player sees is a static mesh in
the world subworld's model group, not a water surface.

Consequence for the established water law: the A3 table (water y vs terrain
floor) is *inapplicable* here — there is no y to compare. And
`highpoly_gamesource.gd::_water_partition()`'s stated assumption "the entity
is always somewhere; only its partition varies" is now **contradicted by a
shipped map**: on MP_Contaminated the search returns nothing and the code must
treat that as a normal outcome, not an error.

There is no river layer; nothing river-named ships (`probe_tung_water.py
mp_contaminated`: all six tungsten-style river/creek partitions MISSING).

---

## B. Terrain and ground layers

### B1. The palette: 50 layers, and the texture split INVERTS the Tungsten law

**MEASURED.** `terrain_mp_contaminated.VisualTerrain` (753 B): `layerCount =
50`, `SurfaceShaderBlockKey 0x408490A3CADE4129`, links **L07 -> L06** and
**L44, L45, L46, L47, L48 -> L43**; layer flags {0: 49, 1: 1}; record ends at
EOF. Layer-graph record table found at offset 228 by the all-keys-resolve rule
(50/50 in the paired depot, `probe_tung_layers.py mp_contaminated`); depot has
50 keys over 45 records, 183 texture params, 423 inline constants.

**MEASURED — the crater law holds with different indices.** L43 binds exactly
one texture, `hfd_debug`, in slot **0xAE16A5C0**; L44-L48 (five, not
Tungsten's four) link to it and carry the crater material sets
(`t_wum_crackedconcrete_03`, rockdark, gravel, concretedebris families).

**MEASURED — the painted/base texture split does NOT hold here.** From the
block-1 record flags and the depot joins:

- painted layers: 31 distinct indices; base layers: 19 (L0,L2 appear in both).
- **Most painted layers bind a full `_cv/_ao/_nhs` set**: L01 concretedamaged,
  L02 larger_rocks, L03 dirtroads, L04 rockdark, L05 rockgravel, L06+L08
  grasslawn+distance, L09 groundburnt, L10 soilchurnup, L11 gravelgrassmix,
  L12 oakshrub, L13 deadbranches, L15 deadleaves, L16 sidegravel,
  L17 gravelconstruction, L18 concreteground, L19 asphaltrough,
  L20 asphaltcracked, L30 hardsurfacecracked, L31/L32/L33 larger_rocks(+_op),
  L34 ashdebrisdark, **L39 `t_contamination_01`** (the theme layer).
- Only 8 layers bind nothing at all (L14, L35-L38, L40, L41, L49) and 6 more
  bind only default/mask textures (L21, L24, L26-L29).
- Base side: L00 dirtgravelsmooth, L07 grassfield_distanceslope, L22/L23/L25
  asphaltedge, L44-L48 crater materials, **L42 = `wum_waterpuddles_01_rgb`**
  (a puddle layer), the rest defaults.

On Tungsten the split was absolute (all painted textureless / all textured
base). Here it is nearly the opposite. **The "terrain materials live on the
base side" rule is a per-map outcome, not a format law** — readers must take
whatever the depot binds per layer, on either side.

Constants: `0xCF3F97E0` is again an integer (values 0 and 4 observed),
`0xCBB9A946` again (0,0) everywhere, `0x4C200FE0` in [-0.01, +0.01],
`0x2F9990B7` in {25, 50, 100}, `0xF7652FB3` in {2, 5, 6.5, 20} — all
consistent with the Tungsten readings. New constants seen here on grass-slope
L07: `0x00837219/0x1D6E8CDD/0x206A0156/0x46F2CB1F/0x6D1ADE42/0x7A0E1F83`
(floats 0.25..1.0), unidentified.

### B2. Block 7 — the resolved base field is ~100% textured

**MEASURED.** Footer: `pairCount = 12` (10 used), `BackgroundMaterialIndex =
0x0660FA80 -> L10` (same *value* as Tungsten's background pair, resolving via
list 0 low-nibble 10 on both maps — a nice cross-map regularity of the
encoding). Texel share pooled over all levels
(`probe_tung_basefield.py mp_contaminated`):

```
L02  46.2%   t_larger_rocks_01        (painted, textured)
L10  31.9%   t_wum_soilchurnup_03     (background; painted, textured)
L07  20.8%   t_grassfield_distanceslope_01_a  (base, textured)
L22   0.4%   t_cas_asphaltedge_01     L00 0.3%, L11 0.3%, L01 0.2%
```

**Every layer the base field resolves to has an albedo.** Against Tungsten's
20.6% ceiling, MP_Contaminated's ceiling is effectively 100% — this is the map
where fixing the splat/colour path pays the most visibly.

### B3. Splat metadata

**MEASURED.** `LayerSlotCount = 62` (like dumbo/aftermath/eastwood; Tungsten's
6 stays the outlier). 865 nodes, 65,389 records, slack 0. Base records: L7,
L21-L29, L42-L48 in all 3,032 base-carrying node-records, L0 in 3,008 — the
map-global base palette, matching the depot's base side exactly.

---

## C. The colour map — BC1, in the PAIRED chunks

This is the section that contradicts the established codec law.

### C1. THE DECOMPOSITION TABLE

**MEASURED** (`probe_contaminated_decomp.py`, `probe_contaminated_decomp2.py`;
341 directory nodes, 0 missing chunks, all on-disk sizes equal the directory's
declared sizes):

**Primary chunks (341):**

```
size = h x 149,297  +  pages x 2,592  +  936          h in {0 (x236), 1 (x89)}
```

exact on **325 of 341**. The 16 irregular nodes are the root, all four
depth-1 nodes (each +103 bytes over the law) and a cluster of 11 deep nodes in
two subtrees (keys 0x30220*, 0x31333*, 0x3200**; extras 30..106 bytes).
HYPOTHESIS: the variable extras are block-8 mask externals or RLE payloads;
not identified. There is **no 4,624- and no 17,424-byte tile in any primary
chunk** (k-histogram is all zero for both tile sizes).

- The **page size is 2,592** — confirming the derived table's "2592 for the
  rest" row for contaminated (`bf6_splat.py` agreement).
- The 936-byte trailer is present on every regular primary. 936 = 117 x 8-byte
  blocks; 99.5% of those blocks have BC1's `c0 > c1` endpoint order, endpoint
  mean RGB (0.480, 0.473, 0.467). It is BC1-compressed *something*, but 117
  blocks is no square tile. **What raster it carries is unknown.**

**Paired chunks (~215):**

```
size = [0 | 189,216 | 2 x 189,216]  +  pages x 2,592  +  [0 | 4 x 8,712]
```

136 paired chunks end with **34,848 = 4 x 8,712 bytes = four 132x132 BC1
tiles** (8,712 = 33x33 blocks x 8 B); 81 of them are exactly the four tiles
and nothing else. The rest are pages only. The two largest paired chunks
(480,672 / 498,816 — the root region) carry 189,216-type height prefixes too.

**Codec census, first vs last tile of the trailer (the BC7-mode test and the
BC1 test side by side):**

```
                          BC7 modes 4-7      BC1 c0>c1
paired FIRST 34,848 B         15.3%             70.1%     (mixture; short chunks overlap)
paired LAST  34,848 B         16.2%             99.2%     <- real BC1 stream
primary 936 trailer            n/a              99.5%     <- BC1-like
weight-page control            n/a              13.9%     <- not BC1
tungsten first tile (control) 98.2%             ~50%      <- real BC7
```

A BC1 stream read by the BC7-mode test comes out mode-0/1-dominated — i.e.
**the established "mode-0-3-dominated = not the colour raster" rule
misclassifies a BC1 colour map as garbage.** The codec must be identified
before the mode test is applied.

### C2. The rendered colour map

**MEASURED.** Decoding each paired chunk's last 4 x 8,712 bytes as four BC1
132x132 tiles and blitting tile j to child (3-j) of the node (the
MAP-TUNGSTEN paired-chunk law: colour tiles grouped in **reversed child order
[3,2,1,0]**) produces a fully coherent aerial photo — mountain drainage in
grayscale-brown, pale erosion channels, the central town/airbase with its road
grid, and a dark road/river line winding to the eastern edge. Rendering with
order [0,1,2,3] produces obvious horizontal seams. The reversed-order law
therefore holds here too, and it is load-bearing.

Saved to `%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/
FIXED_MP_Contaminated.png` (probe: `probe_contaminated_colorrender.py`;
1024px, 136 paired chunks). **One sentence: it reads as a coherent aerial
photo of an ashen mountain valley with a central settlement.** (No SDK
overhead JPG exists for this map — `addons/bf_portal/terrain_decal/textures/`
has only Aftermath, Capstone, Tungsten — so the check is coherence, not a
reference mean. The map-wide mean (0.48, 0.47, 0.47) is plausible for this
map's ash-gray art direction.)

Coverage note: some outer-corner regions render black — their nodes' paired
chunks are pages-only (no colour group). Colour tiles exist only where the
map has detail.

### C3. What the plugin currently does on this map

**MEASURED (simulation of `bf6_splat.gd::detect_layout` scoring).** All three
page sizes tie at score 341 with tile 4,624; the tie check is computed and
never read, so the pick is `(2592, 4624)`. The page size is right **by
tie-luck only**. The consequences:

- `color_tiles()` takes the primary's last 4,624 bytes = the 936-byte BC1
  trailer plus 3,688 bytes of the last weight page, and decodes them as
  BPTC_RGBA. Garbage twice over: wrong bytes AND wrong codec. The real colour
  map is unreachable from the primary chunk — it is **in the paired chunks**,
  which `color_tiles()` never opens.
- `node_pages()` slices pages from `size - 4624 - n*2592`; the true trailer is
  936, so every page window is shifted by 3,688 bytes — weight pages are
  misaligned garbage on this map even though the 2,592/BC4 codec choice is
  right.

---

## D. Decals and roads

**MEASURED — and the shared decal parser fails on this map.**
`decals.TerrainDecals` is 8,448,152 B, `slotCount = 49` (38 empty), 
`recordCount = 1,053`. `probe_tung_decals.py` (TERRAIN.md §10's
identity-transform anchor scan) parses **only 335 records and then stops**:
record 336's tail sits 0x10F8 bytes past its property block (beyond the 0x400
scan window) and its transform region does not contain the two 1.0 floats the
anchor requires. This is not a chain break — the FirstIndex chain is intact —
it is the *anchor heuristic* assuming an identity-scaled matrix.

`probe_contaminated_decals.py` re-anchors the walk on the chain invariant
itself (`FirstIndex == prev + prevTri*3`, + plausibility of TriCount and
tilings) and parses **1,053 of 1,053, no stops**:

```
slot 22  x299  20,838 tris      slot 23  x55
slot 42  x196   8,808 tris  <-  the waterpuddles layer L42
slot 28  x172  11,736 tris      slot 26  x24
slot 25  x163  20,668 tris      slot 29  x19
slot 27  x107   3,146 tris      slot 21  x18
all-record AABB  x -629..2048   z -495..1143   y 130.1..507.6
79 texture-set groups
```

Notes:

- Used slots 21-29 + 42 are exactly the base-side layers (asphaltedge,
  defaults, crater-adjacent) plus the puddle layer — consistent with
  Tungsten's "slot indices coincide with base layer indices" observation.
  196 records on slot 42 are the map's puddle decals.
- Decals cover only the centre/east; x < -629 and z > 1143 carry none
  (same "decals do not cover the whole world" shape as Tungsten's south).
- Texture groups mix libraries exactly as on Tungsten (cas/naf/seu/wum
  families, tungsten-named variants reused: `road_graveldirt_tungsten_01`,
  `naf_roadtracksdirtpacked_tungsten_01`); several groups are `_op`-only
  (`roadvariationmask`, `road_text`), one 65-record group binds no textures at
  all — the "no basecolor is not a failure" class.

**TERRAIN.md §10 needs the correction**: the record tail must be located by
the chain, not by an identity-transform anchor; on maps with
scaled/rotated decal transforms the anchor never matches and 68% of the
records silently vanish.

---

## E. Everything else notable

### E1. Scatter — the catalogue is rich; the join target is EMPTY, fleet-wide

**MEASURED.** `meshscatteringdatabaseasset.MeshScatteringDatabase` = 26,745
bytes, **43 records, exact parse** (cursor lands on the final byte;
`probe_contaminated_scatter.py`, layout per
`findings/meshscatteringdatabase-layout.md` — note the second-largest-known
figure is 26,745 *bytes*, not entries). Header budgets (20000, 20000, 30000,
30000), cellBudget 4096 (the largest of the four known). Content: 23
vegetation kits with point patterns (wheat x141 points, grasskits, lantana,
oakshrub, thorndry, deadbush), hard debris with n=0 (asphalt/concrete chunks,
desertrock, landslidegravel, pebbles), micro-debris at viewDistance 50, and a
`ms_wum_warpplane` at viewDistance 30. 0 wind shaders.

**MEASURED — the per-layer join cannot be validated because its right-hand
side does not ship.** The exe layout of `SingleTerrainLayerData` is size 0x20
with exactly ONE field: `MeshScatteringTypes` (+0x18, array). Deserialising
every level's TerrainData partition:

```
all 16 glaciermp levels + mp_granite:  786 SingleTerrainLayerData instances,
                                       non-empty MeshScatteringTypes: 0
```

The brief's premise (per-layer Density/MinScale/MaxScale/ScaleRandomness with
an `Identifier`) is not present in any shipped MP TerrainData. Whatever reads
the MSDB at runtime gets its per-layer densities elsewhere (HYPOTHESIS: the
compiled layer-graph programs, or engine defaults). **The plugin should build
its scatter list from the MSDB catalogue alone and stop waiting for the layer
join.** (mp_propaganda — a 17th level present in this dump — was not scanned;
its terrain dir does not match the name pattern. Also of note for the fleet:
the 16-map tables everywhere in our docs are now 17-map tables.)

### E2. FX — 487 placed effects, 99 blueprints, shallow graphs

**MEASURED** (`probe_contaminated_fx.py`). Placed FX are
`EffectReferenceObjectData` (full transform + Blueprint import):
`fx_global.ebx` x289, `fx_gasmodedisabled.ebx` x198 — the latter is the FX set
shown **when the gas mode is off** (burning cars, trash fires, smoke pillars);
gas-mode dust/vapour lives in fx_global (`fx_contam_gas_dust_spot` x32,
`smoke_billows_gas` x28, `cloud_spawn_point_cluster_*`). The per-area vfx
layers are empty. 99 distinct blueprints; heavy cross-map reuse (blueprints
imported from mp_subsurface, mp_tungsten, mp_battery, mp_abbasid, mp_badlands,
mp_eastwood, mp_capstone, mp_granite POIs, and two SP levels).

Graph shapes (instance histograms of the top blueprints):

- ambient spot: `EffectBlueprint + EffectEntityData + 1 EmitterGraphEntityData`
  (most common shape by far);
- fires: + up to 6 `EmitterGraphEntityData`, `LightEffectEntityData` +
  `PbrSphereLightEntityData` (**prop-light evidence: fire FX carry their own
  PBR sphere lights**), `CompareBoolEntityData` + `InterfaceDescriptorData`
  (an on/off interface — HYPOTHESIS: the gas-mode/destruction switch);
- animated leaks add `FloatCurve` and two unnamed types
  (`f1640f52-6c00-…`, `a76053ed-403c-…` — not in the type tables; likely
  sound-side).

Plus **11 `ParticipatingMediaVolumeEntityData`** (10 global, 1 gas-disabled)
with `ParticipatingMediaGraph` + `PmGraphParams` — the volumetric fog boxes.
An "FX marker" pass in the plugin could place named billboards from these two
layers alone: count, names and transforms are all statically readable.

### E3. Backdrop — meshes ship, and the empty backdrop layers are a decoy

**MEASURED.** All `_layers_world/backdrop*.ebx` layers (backdrop, mountains,
extension, placed_trees, ecs_splines) have **zero Objects**, and the generated
`ag_backdrop_*_output` partitions are empty too. The actual backdrop assets
live under `backdrop/`: 8 `bd_mountainfort_backgroundmesh_0N_main` MeshSets +
2 `bd_mountainfort_terrain_0N_lastlod` MeshSets + textures under
`backdrop/terrain/`, ~20 `bd_out_wuu_vegetationcontaminated_{inner,outer}_*`
MeshSets under `backdrop/vegetation/`, and the water mesh under
`backdrop/water/`. Placement: `_layers_world/world.ebx` (the level's
SubWorldData + StaticModelGroupEntityData) imports the mountainfort and water
objects; `mp_contaminated.ebx` imports the vegetation backdrop objects. The
assembly prefab `backdrop/terrain/pf_bd_mf_01.ebx` (8 identity-transform
ObjectReferenceObjectData) is referenced by nothing — an authoring leftover.
**If the plugin's placement walk skips `world.ebx`'s own static model group
(as opposed to the area subworlds), the skyline and the water mesh are what
goes missing.**

### E4. ECS, structure, oddities

- **MEASURED.** 98 ECS runtime prefabs: 97 empty stubs
  (`ent=1 arch=1 seg=1 comps=[26]` — the boilerplate law holds), and **one
  populated**: `area_11_architecture2` (`ent=6 arch=2 seg=4 edits=1
  comps=[0,42,46,50]`) — this map's specimen that populated prefabs are
  readable when they exist.
- **MEASURED.** Layer naming oddities for a placement walk: gameplay layers
  include `payload/`, `domination/`, `kingofthehill`, `obliteration/`,
  `escalation`, `mp_operations0` (note the `mp_` prefix, unlike tungsten's
  `escalation/mp_escalation0` nesting), `strikepoint/`, plus
  `_layers_marketing` (not seen on Tungsten) and `_layers_autotests`.
  Prefab layers under `prefabs/` include misspelled
  `pf_containmated_tunnel_*` (sic).
- **MEASURED.** Depot dedup across modes again:
  breakthrough/conquest/escalation/operations share
  `shaderblockdepot_9526102139013923511`; dom == kingofthehill.
- **MEASURED.** Biggest files: enlighten 94.8/43.4 MB, materialgrid 15.2 MB,
  TerrainDecals 8.4 MB, streaming tree 8.1 MB, area physics 1.8-7.5 MB.

---

## F. What generalises, and what this CONTRADICTS

| finding | scope | consequence |
|---|---|---|
| **Colour raster codec is per-map: BC1 (132x132, 8,712 B) here, BC7 elsewhere** | contaminated (first known BC1 map; screen the other 2592-maps) | Contradicts TERRAIN.md 5.3 / MAP-TUNGSTEN C2's implicit "the colour map is BC7". The BC7-mode test scores a real BC1 colour map as mode-0/1 "garbage"; codec identification (BC1 c0>c1 signature ~99% vs ~50% random) must come first. |
| **Colour tiles can live in the PAIRED chunk, not the primary** — 4 child tiles at the chunk end, reversed order [3,2,1,0] | contaminated; the reversed-child order itself confirms MAP-TUNGSTEN's paired law | `bf6_splat.gd::color_tiles` reads only primaries; on this map the colour map is unreachable from there. The trailer model is per-map: tungsten 2x17424-BC7-in-primary, dumbo 1x4624-BC7-in-primary, contaminated 936-in-primary + 4x8712-BC1-in-paired. |
| **Primary trailer here is a constant 936 B** (BC1-like, raster unknown); exact law `h*149297 + pages*2592 + 936` on 325/341 | contaminated | The detect_layout fix must allow a non-tile trailer; 16 nodes carry small variable extras (30-106 B) on top. |
| `detect_layout` ties 3-ways on page size at score 341 and the tie check is dead code | every map | The page size 2592 comes out right here **by luck**. Confirms MAP-TUNGSTEN G1 with a sharper failure: even the "right" answer is un-earned. |
| **Painted layers CAN be texture-rich** — 31 painted indices, most with full cv/ao/nhs; ~100% of block-7 texels resolve to textured layers | contaminated vs tungsten's absolute inverse | "Materials live on the base side" is a per-map outcome, not a law. `bf6_materialtree.gd`/layer binding must stay side-agnostic. |
| **A level can ship NO water entity of any type** | contaminated | `_water_partition()`'s "always somewhere" comment is wrong; absent water is a normal, detectable state. Water here is a plain backdrop mesh placed by `world.ebx`. |
| The TerrainDecals identity-transform anchor fails on non-identity records — walk stops at 335/1053 with zero chain breaks | at least contaminated | TERRAIN.md 10 must anchor on the FirstIndex chain. Any consumer using the old anchor silently loses 68% of this map's decals. |
| **SingleTerrainLayerData.MeshScatteringTypes is empty on all 17 levels checked** (exe layout: it is the type's ONLY field) | every map | The per-layer scatter join has no shipped right-hand side; build clutter from the MSDB catalogue (43 exact-parsed records here) + own placement logic. |
| Crater slot 0xAE16A5C0 bound by exactly one layer (L43), linked-from by the crater materials (5 here, 4 on tungsten/dumbo) | every map | Confirms the law; link count varies. |
| Empty-stub ECS prefab boilerplate; populated ones readable (area_11_architecture2) | every map | Confirms. |
| Background pair value 0x0660FA80 appears as BackgroundMaterialIndex on both tungsten and contaminated while resolving to different layers | every map | The pair *encoding* (list/level/nibble) is the invariant, not the value's layer. |
| A 17th level, `mp_propaganda`, exists in this dump | fleet | Every 16-map table (page sizes, screening lists) needs a propaganda row. |

---

## G. Next actions for the plugin, in priority order

1. **Make `detect_layout` decompose per map with a per-map trailer model** —
   `addons/highpoly_toggle/bf6_splat.gd`. For contaminated the verification
   row is: page 2592; primary trailer 936 (constant, NOT a colour tile);
   heights 149,297; colour = paired-chunk tail 4 x 8,712 BC1. Make the tie
   counter actually fail detection (3-way page-size tie here today).
2. **Add the paired-chunk BC1 colour path** — `bf6_splat.gd::color_tiles` /
   `assemble_colors`: source = paired chunk's last `4*8712` bytes when the
   paired size decomposes that way; decode `Image.FORMAT_DXT1`; blit tile j to
   child (3-j). Codec identification by the BC1 c0>c1 signature (>95%) before
   any BC7-mode test. Verification: assembled map must match
   `_cmapprobe/FIXED_MP_Contaminated.png`.
3. **Fix `node_pages` to subtract the true trailer (936), not `tile_bytes`** —
   `bf6_splat.gd`. Today every weight page on this map is read 3,688 bytes
   off even though the BC4 codec pick is right.
4. **Treat absent water as a normal state** —
   `highpoly_gamesource.gd::_water_partition()` / `water()`: when no
   `WaterSurfaceEntityData` exists (this map), log "no water entity in level"
   and continue; optionally pick up `backdrop/water/*_mesh` via the world
   subworld walk instead.
5. **Walk `_layers_world/world.ebx`'s own StaticModelGroup** —
   `highpoly_mapcontext.gd` / `highpoly_gamesource.gd`: that is where this
   map's 10 mountainfort/lastlod skyline meshes and the water mesh are placed;
   the `backdrop*` layers are empty decoys here.
6. **Chain-anchor any decal reading** (and push the TERRAIN.md §10 fix
   upstream): the identity-transform anchor loses 718 of 1,053 records on this
   map. `probe_contaminated_decals.py` has the working walk.
7. **Build the scatter catalogue from the MSDB now** — the layer join is a
   dead end (empty on 17/17 levels). 43 mesh names + viewDistance + kit point
   patterns are statically readable; combine with the block-7 layer field
   (grass layers L06/L07/L08 cover 21%+ of this map) for placement masks.
8. **FX markers (optional, cheap)** — fx_global + fx_gasmodedisabled give 487
   transforms with human-readable blueprint names (fires, gas, steam,
   dripping); fire blueprints embed PbrSphereLightEntityData for prop lights.
