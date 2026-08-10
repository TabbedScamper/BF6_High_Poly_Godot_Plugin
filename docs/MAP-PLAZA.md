# MP_Plaza, end to end

Deep study of MP_Plaza against the laws established in `MAP-TUNGSTEN.md`. Every
claim is tagged **MEASURED** (with the number, bytes, or EBX name behind it) or
**HYPOTHESIS**; "unknown" is used where the data does not answer. Probes are in
`tools/probe_plaza_*.py`, all read-only against the 2026-08-01 pull through
`impl/pipeline/bf6_paths.py`. The generic `probe_tung_*.py` probes were run with
`mp_plaza` as the level argument wherever they work; plaza-specific probes exist
where plaza's data broke them (see §C — that break is itself a finding).

```
tools/probe_plaza_decomp.py       THE decomposition table + paired-chunk law
tools/probe_plaza_bc7mean.py      BC7 mode-4/5/6/7 block-mean RGBA decoder + alpha stats
tools/probe_plaza_colorrender.py  colour + ALPHA planes assembled to PNG
tools/probe_plaza_decals.py       plaza's DIFFERENT TerrainDecals record format
```

## 0. The map in one paragraph

**MEASURED.** MP_Plaza is a 4,096 x 4,096 m world (block 0 root AABB
x,z ∈ [-2048, 2048]), ground from **y = 0.125 to y = 178.003**,
`WorldSizeY = 1024.0`, xs = 265, 77 chunk-directory nodes (73 height nodes: 5
Packed, 68 External), splat tree of 297 nodes / 22,023 records,
`LayerSlotCount = 6` (same value as Tungsten; meaning still unknown). Terrain
palette is **43 layers**. Blocks present: 0, 1, 4, 7, 8 — **no block 2
(density) and no block 5**, unlike Tungsten which ships both. It is a dense
North-African souk town (naf_* material families, SoukHouse/PlazaBuilding
prefabs) in the map centre with dry braided river channels and mountains as the
out-of-bounds ring. It hosts no battle-royale content.

---

## A. Water

**MEASURED — there is NO water surface entity anywhere in the level.**
`probe_tung_types.py mp_plaza --find "water|ocean|river"` over all 1,727
partitions finds exactly one hit: `mp_plaza/description.ebx`
(`WaterLevelDescriptionComponent`). There is no `WaterSurfaceEntityData`, no
`WaterOceanSimulationEntityData` carrier with a surface, no `WaterAsset`:

- `_layers_content/water.ebx` — 414 B, one `LayerData`, `Objects = []` (empty).
- `_layers_content/water_shared_schematic.ebx` — six schematic logic entities
  (PropertyCast / MathOp / AreaProximity …), no surface geometry.
- `_layers_world/backdrop_ocean.ebx` — 420 B, empty layer.

So the water-height-vs-terrain-floor diagnostic from MAP-TUNGSTEN.md §A3 is
**not applicable — plaza is the first studied map with zero water entities.**
Its braided river bed (clearly visible in the colour-tile alpha, §C) is dry
terrain. The plugin's `highpoly_gamesource.gd::water()` will find no partition
containing the type on this map; that zero-match path should log the fact
rather than being indistinguishable from a read failure (action list, §G).

---

## B. Terrain and ground layers

### B1. THE DECOMPOSITION TABLE (the detect_layout verification row)

MP_Plaza is the **only** map in the derived table with page size **5184**
(= 72 x 72 raw bytes), so this section is the sole cross-check of that branch.
`probe_plaza_decomp.py`, with the page count per node KNOWN from block 1's
painted-record count (not fitted):

```
77 chunk-directory nodes, directory walk byte-exact (consumes 2,091,511 of 2,091,511)

PRIMARY chunks, residual = size - pages*5184:
   residual      0  x9    pages only (packed-height nodes, no trailer)
   residual 216897  x68   = 149297 (height, xs=265) + 1 x 67600 (colour tile)

67600 = 4225 x 16 = 65^2 BC7 blocks = ONE 260 x 260 BC7 tile.
BC7 mode histogram of that tile over all 68 chunks:
   first half   modes 4-7  99.99%   {m4: 80845, m6: 36730, m5: 24996, m7: 1033, m1: 12}
   last  half   modes 4-7 100.00%   {m4: 79645, m6: 37170, m5: 25648, m7: 1153}

PAIRED chunks (52): every one an exact multiple of 5184, and equal to
   sum(weight pages of all block-1 DESCENDANT nodes of the chunk-dir node): 52/52.
```

**MEASURED — plaza's numbers for the detect_layout fix:** page **5184**, tile
**67600** (side 260), height prefix **149297 only** (no 39919, no 189216, no
sums), trailer tile count k ∈ {0, 1}. The old scoring's `(2592, 4624)` pick on
this map put the page slice inside the single colour tile and handed
`assemble_colors` the last 4,624 bytes of it — real BC7 colour data, but a
68x68 read of the bottom strip of a 260x260 image.

**MEASURED — two contradictions of Tungsten-derived generalisations:**

1. **There is no second degenerate tile.** Plaza's trailer is one tile, 100%
   modes 4-7 throughout. "Colour tile first of two" is Tungsten-shaped;
   "single tile" (like dumbo) is what plaza ships at a new size.
2. **Paired chunks contain NO colour tiles and no heights** — only descendant
   weight pages. 67600 mod 5184 = 200, so no count of colour tiles can hide in
   an exact 5184-multiple; the identity `paired = descendant pages` is exact on
   all 52. This contradicts the paired-chunk reading in MAP-TUNGSTEN.md §C1
   ("children's pages, then colour tiles grouped first") as a universal law.
   Consequence for `bf6_splat.gd::color_tiles`: its paired-chunk pass picks the
   best mode-4-7 group with **no absolute threshold**, so on plaza it can slice
   raw weight pages and ship them as colour tiles for sub-chunk node keys. See
   §G item 1.

Also note the tile-resolution law implied by Tungsten ("tile side = 2 x page
side", 66→132) is dead: plaza pages are 72 wide and its tile is 260 — full
node resolution (265 samples), i.e. plaza's colour map is ~2x the linear
resolution per node of Tungsten's.

### B2. The layer palette — 43 layers

**MEASURED.** `layergraphslayergraphs` (1,596 B) declares 43 records; the true
record table is at offset **200**, located by the "all 43 ShaderBlockKeys must
resolve in the paired depot" rule (43/43 at 200). A wrong-but-plausible table
("keys distinct") exists at offset **132 — exactly 68 bytes earlier, the same
68-byte trap MAP-TUNGSTEN.md §B1 documents.** The trap reproduces map-for-map;
the 100%-resolve rule is load-bearing everywhere.

Depot: 43 keys over 33 content-deduplicated records, 75 texture params, 312
constants, 0 parse failures. Split from block-1 record flags (bit8 at +20):
**27 painted layers, 17 base layers** — L36 appears on BOTH sides (painted x66
and base x786), like Tungsten's L01/L04.

Highlights (full table: `probe_tung_layers.py mp_plaza`):

| L | side | binds |
|---|---|---|
| 00 | BASE | detail `t_com_asphaltdetail_02_ncs` only — **the road network** (block 7) |
| 01 | painted | no texture; **tint const `0x4FDCF6B1` = (0.796, 0.796, 0.796)** |
| 04, 09, 16 | painted | detail `t_bld_asphaltutility_01_noh` (no colour) |
| 06, 07, 08, 12, 14 | BASE | `t_ter_defaulttexture_*` placeholders only |
| 10 | BASE | **`t_naf_tileshexagon_01_{cv,ao,nhs}`** — the town plaza paving |
| 15, 21, 24 | painted | detail/ncs textures + tint float3 |
| 25 | BASE | `wum_waterpuddles_01_rgb` at the default slot — a **puddle/wetness layer** with its own constant set (`0x5227ADCF` 1.8, `0xE4A89FCF` 0.5 …) |
| 26–36 | painted | **empty depot records** (11 layers, shared contentHash `04B2008FD98C1DD4`) |
| 37 | BASE | `hfd_debug` at slot **`0xAE16A5C0`** — **the crater layer** |
| 38–42 | BASE | real `_cv` texture sets: naf_chunkydirt / naf_sandrough / naf_stonerubble / wum_crackedconcrete / naf_graveldusty — **all five link to L37** |

**MEASURED — the "textured layers are all base" law is WEAKENED on plaza.**
Several *painted* layers bind textures — but every one of them binds only a
detail/normal-class texture through slot **`0xB6C7E795`** (a slot not seen on
Tungsten: `_ncs` / `_noh` / `_nm` detail maps). Every **colour (`_cv`)**
texture is still on a base layer (L06, L10, L38-L42) or the L25 puddle mask.
Refined law: *colour* lives on the base side; detail may live anywhere.

**MEASURED — constants:**

- **`0x4FDCF6B1` is a float3 per-layer TINT** (new since Tungsten, where it did
  not appear): (1.0, 0.896, 0.766) on L09, (0.575, 0.567, 0.515) on L21,
  (0.737, 0.702, 0.659) on L15, (1,1,1) on defaults. Values are plausible
  albedos — this is very likely the flat colour of a textureless layer and is
  actionable for the plugin (§G item 5). HYPOTHESIS on the exact semantics.
- `0xCF3F97E0` — integer, values 0/2/4 only, again. Confirms MAP-TUNGSTEN.md.
- `0xCBB9A946` — Vec2 (0,0) on every layer that has it, again.
- `0x2F9990B7` — 0.328 .. 234.19 (crater-adjacent L38 reads 234.19, echoing
  Tungsten's out-of-class 1333.5 on crater-adjacent layers).
- New unidentified crater-material constants: `0x37984D1E/1F`, `0xD46383AC/AD`.

**`0xAE16A5C0` crater law CONFIRMED:** exactly one layer (L37) binds
`hfd_debug` in that slot, and the five real-texture layers L38-L42 all link to
it (`VisualTerrain` link table).

### B3. Block 7 — the material raster

**MEASURED.** `pairCount = 16` (14 used), `BackgroundMaterialIndex =
0x00000080` — the "no background" sentinel (like dumbo/eastwood; Tungsten had a
real background). Node stream ends exactly 72 bytes (= its footer) before block
end; 0 bad RLE rows. Texel share of the resolved base field:

```
L07  70.8%   base, default placeholders only (textureless)
L01  21.2%   painted, textureless, tint (0.796 grey)
L00   5.5%   base, asphalt detail          <- the ROAD NETWORK (reads as the map's street plan)
L10   1.4%   naf_tileshexagon_01 (_cv!)    <- town plaza paving
L12   0.9%   base, default placeholders
L39   0.1%   naf_* (_cv)
L14   0.1%   base
```

**So ~1.5% of plaza's ground resolves to a layer with a colour texture**
(L10 + L39) — against 20.6% on Tungsten. The rasterised field is a
recognisable street map of the town (`scratchpad plaza_basefield.png`), but
essentially all large-scale ground COLOUR on this map must come from the colour
map (and its alpha, below), the per-layer tints, and the decals.

---

## C. The colour map — and what its ALPHA holds (map-specific focus)

The corpus claim under test: *plaza's colour-tile alpha carries baked overhead
AO/shadow; the plugin currently ignores colour-map alpha entirely.*

**MEASURED — the encoder itself signals a live alpha channel.** Plaza's tile
decodes 56% mode 4, 18% mode 5, 26% mode 6, 0.8% mode 7. Modes 4 and 5 are the
two BC7 modes with an INDEPENDENT alpha plane (own endpoints, own index bits) —
Tungsten's tile is ~90% mode 6 (alpha welded to the colour indices) with a dead
alpha. Rotation bits are 0 on **all 211,188** mode-4/5 blocks (so "alpha" is
really the alpha plane, not a rotated colour channel).

**MEASURED — alpha statistics** (`probe_plaza_bc7mean.py`, endpoint-midpoint
decode over all 287,288 blocks):

```
mean RGBA (0.470, 0.466, 0.464, 0.501)
alpha mean 0.501   std 0.103   (dumbo: mean 0.012 std 0.069; tungsten: 0.007 std 0.032)
alpha histogram: 82% of blocks in 0.44-0.62, deep tail to 0, thin tail to 1
```

**MEASURED — the pictures** (`probe_plaza_colorrender.py`, written to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/`):

- `FIXED_MP_Plaza.png` (RGB): **does NOT read as a coherent aerial photo** —
  it is near-uniform neutral grey (mean 0.47) over the whole 4 km footprint,
  with real warm colour only in the central souk town's street grid.
- `ALPHA_MP_Plaza.png`: **DOES read as a coherent aerial image** — the braided
  river channels (dark), mountain-relief shading in the southern ranges, the
  town's street grid with per-building shadow detail and a bright open plaza.

**Verdict: the corpus claim is CONFIRMED as measured structure** — plaza's
colour-tile alpha carries a spatially coherent, monochrome overhead shading
layer, and it is where most of this map's large-scale ground detail lives
(the RGB being ~neutral). That it is specifically *AO/sun-shadow* (rather than,
say, a wetness or height proxy) is **HYPOTHESIS** — supported by dark alleys
between buildings, dark channel beds and hillshade-like relief, and by the
0.5-centred distribution matching the colour map's own 0.5-neutral modulation
convention (2x multiplier: <0.5 darkens, >0.5 brightens).

**Cross-map scope: plaza-specific among maps measured.** Dumbo (0.012) and
Tungsten (0.007) alphas are dead. Any plugin use of colour-map alpha MUST be
gated per map (e.g. only when the mean alpha lands in ~[0.3, 0.7]) — a naive
`* 2*alpha` would black out every dead-alpha map.

---

## D. Decals and roads

### D1. Plaza ships a DIFFERENT TerrainDecals record format

**MEASURED — the dumbo-verified §10.2 layout parses 0 of plaza's 485 records**
(`probe_tung_decals.py mp_plaza`: anchor scan never fires on record 1).
Plaza's records are GUID-headed and tail-FIRST (`probe_plaza_decals.py`):

```
+0x00  16 B  header value (NOT a slot GUID: 0x00.. on 407 recs, 7386dd64deb6f8ae7a3dfdee.. on 66,
             7386dd64deb6f8ae00.. on 12)
+0x20  u32   FirstIndex          chain FirstIndex == prev + prevTri*3 HOLDS: 485/485, 0 breaks
+0x24  u32   TriCount
+0x28  f32   ~0.0476 on every record (unknown)
+0x2C  f32   Tiling0     +0x30  f32  Tiling1
+0x40  f32x3 AabbMin     +0x50  f32x3 AabbMax
+0x60/+0x70  node-aligned AABB pair    +0x80  f32x4 (minX minZ maxX maxZ repeat)
+0x90  render params (f32 1.0, 01 01 01 01, vb fields)
+0xB0  u32   propSize
+0xB4  property stream (same §10.3 entry grammar and _cv/_nhs/_ao/_op hashes)
next record at +0xB4 + propSize; record stream ends 0x375D9, vertex data follows
```

So the *semantic* laws survive (chain invariant, prop-entry grammar, the four
texture slot hashes, slotCount == layerCount = 43) but the *record framing* is
a second format. A decal reader keyed to §10.2 silently reads zero decals here.

**MEASURED — the texture references do not resolve.** Every prop GUID
(payload +33, per §10.3) is a **v1 time-based UUID** (`…-11ef-…`, `…-11f1-…`)
absent from the dump — the same authoring-GUID shape as Tungsten's
`SourceAsset` dead ends — unlike dumbo/tungsten where decal texture GUIDs are
shipped partition GUIDs. 65 distinct texture-set groups over 485 records (407
with full `_cv/_nhs/_ao/_op` sets, 26 `_op`-only); their material *identity* is
currently unresolvable from the shipped data. The slot table carries GUIDs at
slots 6, 7, 8, 10, 11, 12, 14, 20, 25, 37, but no record joins them by value.
**Unknown:** how the runtime binds these records to materials.

### D2. Coverage

**MEASURED.** All 485 records sit inside x ∈ [-212, 251], z ∈ [-276, 376] —
the town core, ~460 x 650 m of a 4,096 m world. The entire wilderness, river
system and mountain ring carries **zero** terrain decals (same shape as
Tungsten's decal-free south). Roads outside town are block-7 L00 texels plus
the colour map.

### D3. Roads in ECS

**MEASURED — plaza has three POPULATED ECS runtime prefabs** (of 51; the other
48 are the standard empty `ent=1 arch=1 seg=1 comps=[26]` stub):

```
_layers_world/area_04_roads_ecsprefab   ent=94 arch=3 seg=9 edits=196   <- ROADS as ECS content
_layers_world/area_01_props_ecsprefab_2 ent=7
_layers_world/area_07_props_ecsprefab   ent=3
```

Tungsten had zero populated prefabs; dumbo/aftermath had them only for props.
A roads-carrying ECS prefab is new — worth decoding when the ECS component
tables are attacked.

---

## E. Everything else notable

- **MEASURED — structure.** 296 `LayerData` partitions, 141 with zero Objects.
  World content is `_layers_world/area_01 … area_08` + `world` (per-area
  physics 5.0-11.0 MB, per-area meshvariationdb and ShaderBlockDepot), plus
  populated backdrops: **`backdrop_a.ebx` = 39 SpatialPrefabReferenceObjectData
  + 4 ObjectReferenceObjectData; `backdrop_b.ebx` = 88 prefab refs + 1
  EnvironmentDecalVolumeData + TerrainQuadDecalData + 2 TerrainFillDecalData**
  (authoring decal instances surviving in a backdrop layer). Skyline/backdrop
  meshes for the open task list are behind those 127 prefab references.
- **MEASURED — 29 ShaderBlockDepots.** Largest is
  `_layers_gameplay/portal_gameplay…` at **18.7 MB** (vs 8.2 MB on Tungsten).
  conquest / domination / kingofthehill / payload share one depot
  byte-for-byte (`shaderblockdepot_9526102139013923511`).
- **MEASURED — lighting.** `enlighten_mp_plaza_highend` 171.4 MB (the map's
  biggest file). **Nine `ve_*` presets**: `base_01_02_12`, `alleyways`,
  `mainalleyway`, `soukpassages`, `soukpassages2`, `interior`, `lessfog_01`,
  `abandonedrd` — an unusually interior-heavy set. District lighting layers:
  `lighting_boulevard`, `lighting_marketarea`, `lighting_northhq`,
  `lighting_southhq`, `lighting_plaza`, `lighting_wartornroad` (135 objects).
  Prop lights: `lf_*` fixture assets with `PbrSpotLightEntityData` (street
  lamps, wall lamps, fluorescents, several `_flicker` variants), and
  `fx_light_vehicleprop_headlight{halogen,led}_{left,right}_plaza` — vehicle
  headlight FX-lights authored per-map. Reflection:
  `PbrBoxReflectionVolumeEntityData` + `PbrDistantReflectionVolumeEntityData`
  in `_layers_content/lighting*`; `EnvironmentDecalVolumeData` inside building
  prefabs.
- **MEASURED — scatter is a dead end on plaza.** The level ships a 12,745-byte
  `meshscatteringdatabaseasset.MeshScatteringDatabase`, but **all 47
  `SingleTerrainLayerData` instances have `MeshScatteringTypes = []`** — the
  Identifier->catalogue join cannot be validated on this map, and plaza
  effectively uses no terrain scatter.
- **MEASURED.** No block 2 / block 5 in the streaming tree. `WorldSizeY =
  1024.0` (u16 step 1.56 cm). Terrain directory is `mp_plaza_terrain`
  (level-suffixed — the inconsistent-naming law holds; `terr_dir()`'s search
  handles it). `minimaproads.ebx` exists with its own (stub) ECS prefab.

---

## F. Generalisation — what holds, what breaks

| finding | scope | notes |
|---|---|---|
| Page size **5184** verified by exact decomposition with per-node page counts KNOWN from block 1 | plaza (the only 5184 map) | The verification row for the `detect_layout` fix: (5184, 67600), prefix 149297, k ∈ {0,1}. |
| Trailer = ONE 67600-byte 260x260 BC7 tile; no degenerate second tile | plaza | New tile size; "two tiles, colour first" is Tungsten-shaped, not a law. The "tile side = 2 x page side" pattern (66→132) is dead: 72→260 (full node res). |
| **CONTRADICTION: paired chunks hold ONLY descendant weight pages** — no colour tiles, no heights; `paired = Σ(block-1 descendant pages) × 5184` exact on 52/52 | plaza (test other maps) | Breaks MAP-TUNGSTEN §C1's paired-chunk generalisation. The plugin's paired-chunk colour pass has no absolute mode-4-7 threshold and WILL emit weight pages as colour tiles here. |
| **CONTRADICTION: the TerrainDecals record format is not universal** — plaza ships a GUID-headed, tail-first, props-last variant; the §10.2 parser reads 0 of 485 records | plaza (test other maps) | Chain invariant, prop grammar, slot hashes, slotCount==layerCount all survive inside the new framing. |
| Decal texture refs are unresolvable v1 authoring UUIDs | plaza | Unlike dumbo/tungsten (partition GUIDs). Decal material identity is an open question here. |
| **Colour-tile ALPHA carries a live overhead shading layer** (mean 0.501, std 0.103, coherent aerial image); RGB is near-neutral except the town | plaza-specific (dumbo 0.012, tungsten 0.007 dead) | The corpus claim confirmed. Free AO for the plugin — but it MUST be gated per map or dead-alpha maps go black. |
| Layer-graph table trap: plausible-but-wrong table exactly 68 bytes before the true one (132 vs 200) | every map | Reproduces MAP-TUNGSTEN §B1 independently. "All keys resolve" is the only safe locator. |
| "All textured layers are base" WEAKENED: painted layers bind detail textures via new slot `0xB6C7E795`; **colour (`_cv`) textures remain base-only** | plaza | Refines the law rather than breaking it. |
| `0xAE16A5C0` = crater slot, one layer per map (L37), linked-to by the real-texture layers | every map | Third confirmation (tungsten L28, dumbo L41, plaza L37). |
| `0x4FDCF6B1` = float3 per-layer tint with albedo-plausible values | new, plaza | Not present on Tungsten's layers. Actionable colour source for textureless layers. |
| `0xCF3F97E0` integer 0/2/4; `0xCBB9A946` (0,0) everywhere | every map | Confirmed again. |
| Pair value X=0x31 (`0x06623180`) resolves to the wum_ls_gravel family on tungsten but to L39 (naf_* family) on plaza | cross-map | The §8 cross-map note "X=0x31 → shared wum family" is coincidence of list-2 slot 1, not a global material identity. |
| A map can have ZERO water entities | plaza | The water diagnostic needs a third state: above-floor / buried / **absent**. |
| Populated ECS prefabs exist per-map and can carry ROADS (94 entities) | plaza | Tungsten's "all stubs" is Tungsten-specific, as MAP-TUNGSTEN already showed for dumbo/aftermath. |

---

## G. Next actions for the plugin, in priority order

1. **Guard the paired-chunk colour pass** — `addons/highpoly_toggle/bf6_splat.gd::color_tiles`.
   Require an absolute mode-4-7 fraction (image tiles measure 0.86-1.00; raw
   pages ~0.06) before accepting any paired-chunk tile, and skip the pass
   outright when `paired_size == descendant_pages * page_size` (plaza: all 52).
   Without this, the detect_layout fix makes plaza's SPLAT right and then the
   paired pass injects garbage colour tiles for sub-chunk keys.
2. **Use the colour map's alpha as a baked-AO multiplier, gated per map** —
   `addons/highpoly_toggle/highpoly_mapcontext.gd` + the terrain shader. The
   data is already in the decoded BPTC_RGBA image; the shader ignores .a.
   Gate: enable only when the map's mean tile alpha is in ~[0.3, 0.7]
   (plaza 0.501; dumbo 0.012 and tungsten 0.007 must NOT multiply). On plaza
   this single change adds the river beds, hillshade and per-building street
   shadows that its near-neutral RGB cannot provide.
3. **Add plaza to the detect_layout verification set** with this doc's numbers:
   page 5184, tile 67600/260, residuals {0, 216897}, prefix 149297 only —
   `bf6_splat.gd` (the constants are already present in the current rewrite;
   this table is their proof for the only 5184 map).
4. **Report "no water entity" explicitly** —
   `highpoly_gamesource.gd::water()`: three states (above floor / buried /
   absent). Plaza is the test case for absent.
5. **Feed textureless layers their tint** — `bf6_terrainlayers.gd`: read
   `0x4FDCF6B1` (float3) as the layer's flat albedo where no `_cv` is bound;
   92% of plaza's ground resolves to L07/L01/L00, all colour-textureless.
   Also add detail slot `0xB6C7E795` to the known-slot table.
6. **Second decal record format** — the decal reader needs auto-detection:
   if the §10.2 anchor scan fails on record 1, try the plaza framing
   (`probe_plaza_decals.py`). Texture GUIDs will still not resolve (v1 UUIDs);
   fall back to untextured geometry rather than dropping 485 records.
7. **Backdrop walk** — `backdrop_a`/`backdrop_b` carry 127
   SpatialPrefabReferenceObjectData for the skyline; verify the placement walk
   picks these layers up on plaza.
8. **Push upstream to BF6_Frostbite_Research** — TERRAIN.md §5.2/5.3 (plaza:
   page 5184, single 260-tile trailer, paired chunks = descendant pages only),
   §10 (second record format, plaza), §8 (X=0x31 note is per-map), and the
   colour-alpha finding.
