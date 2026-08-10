# MP_Outskirts, end to end

One map read from the shipped data, following `MAP-TUNGSTEN.md`'s method and
verifying its laws here. **Every claim is tagged MEASURED or HYPOTHESIS**; a
MEASURED claim names the resource, value or probe that reproduces it. "Unknown"
is used where the data did not settle a question.

MP_Outskirts got the fleet's special assignment: it appears BOTH in the
corpus's verified BC7 tile-size table (`TERRAIN.md` §5.3: trailer 17,424 =
132² tile) AND in `bf6_splat.py`'s 4,356-byte raw-page list, and
`bf6_colormap.py` files it under "fit BOTH". §C settles the apparent conflict.

Probes: the shared `probe_tung_*.py` set run with the `mp_outskirts` argument,
plus three map-specific probes beside this document:

```
tools/probe_outskirts_decomp.py       the decomposition table + BC7 mode test
                                      + a simulation of detect_layout's scoring
tools/probe_outskirts_colorrender.py  full-BC7 colour-map assembly -> FIXED_MP_Outskirts.png
tools/probe_outskirts_decals.py       the (variant-format) TerrainDecals, what
                                      can and cannot be parsed of it
```

All reads go through `BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`
(dump root `A:\bf6pull\dump`), read-only. Nothing touched the plugin, its
shaders, or any `user://` cache.

---

## 0. The map in one paragraph

**MEASURED.** MP_Outskirts is a 4,096 x 4,096 m world (block-0 root AABB
`x,z ∈ [-2048, 2048]`), ground from **y = 12.941 to y = 177.270**,
`WorldSizeY = 206.0` (u16 step 0.31 cm — the finest of the maps measured so
far), 265 samples per heightfield node, **85 streaming nodes** (5 Packed, 80
External; the smallest node count seen yet — tungsten has 269). Terrain palette
**45 layers** (34 painted, 11 base), crater layer **L39** with L40–L44 linked
to it. It carries a variant-format `decals.TerrainDecals` (484 records, §D),
**no water entity of any kind** (§A), 227 `LayerData` partitions (146 with zero
Objects), 33 `EcsRuntimePrefabAsset` partitions **all empty stubs**, 32
ShaderBlockDepots, and a full gamemode fan-out including **payload** and
**teamdeathmatch** (no battle-royale content — that is tungsten's oddity, not a
level-directory universal). Terrain directory name: **`mp_outskirts_terrain4k`**
— a third naming convention after `terrain_mp_tungsten` and `mp_dumbo_terrain`.

---

## A. Water — there is none, and that is a new case

**MEASURED — zero water types in the whole level.**
`probe_tung_types.py mp_outskirts --find "Water|Ocean|River"` over all 1,035
partitions under `game/glaciermp/levels/mp_outskirts`: **0 partitions match**.
No `WaterSurfaceEntityData`, no `WaterOceanSimulationEntityData`, no
`WaterAsset`, no `OceanComponentData` in any `ve_*` preset, nothing.

**MEASURED.** `_layers_content/water.ebx` exists (418 B) but is one `LayerData`
with `Objects = []`. `_layers_content/water_shared_schematic.ebx` holds only
schematic plumbing (MathOp / PropertyDefaultValue / SchematicChannel /
AreaProximity / PropertyCast entities) — no water surface. There are no
`river*` or `creeks*` layers at all (`probe_tung_water.py mp_outskirts`).

This extends MAP-TUNGSTEN's water table with a third class:

| level | water y | terrain min y | water is |
|---|---|---|---|
| mp_aftermath | 49.70 | 0.11 | above floor — renders |
| mp_tungsten | 0.00 | 64.77 | buried — never visible |
| **mp_outskirts** | **no entity** | 12.94 | **absent** — nothing to draw, nothing buried |

The plugin's `highpoly_gamesource.gd::_water_partition()` will find no
partition containing the type on this map; whatever it does on "not found" is
the code path outskirts exercises. The correct log line here is "no water
entity in this level", not a height diagnostic.

**CONTRADICTION worth shouting:**
`findings/water-material-resolves-through-the-depot.md` lists **outskirts**
among the maps carrying the full "ocean" water-shader variant. **MEASURED:** a
recursive content search of every file under `levels/mp_outskirts/` finds zero
occurrences of `oceanmicrodetail`, and zero of `waterfoam`. Neither water
shader variant's fingerprint texture is bound anywhere in the level's own
bundles. Either that finding's per-map attribution came from a shared-mount
scan that assigned another bundle's depot to outskirts, or it is simply wrong
for this map. It needs re-verification upstream; on the level's own data the
claim is false.

---

## B. Terrain and ground layers

### B1. The palette: 45 layers, 34 painted / 11 base

**MEASURED** (`probe_tung_terrain.py mp_outskirts`, all blocks byte-exact:
block 0 slack 0, block 1 slack 0, block 7 node stream ends exactly 56 bytes =
its 12-pair footer before block end, 0 bad RLE rows):

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 85, PersistentNodeCount 80
block 0  heights      9,782 B  xs=265, WorldSizeY=206.0, 85 nodes (5 Packed, 80 External)
block 1  splat      806,781 B  LayerSlotCount=6, 213 nodes, 24,388 records
block 4  mask         1,421 B
block 7  material  7,039,896 B  dim=256, 405 declared / 304 walked, levelMax=5, 12 pairs
block 8  mask       274,575 B  dim=265, 101 nodes, levelMax=4, maskUnknown0=4
```

No block 2 (density) and no block 5 — the block set is per-map, as tungsten
already showed in the other direction. `LayerSlotCount = 6` again (tungsten 6,
dumbo/aftermath/eastwood 62); still not the layer count, meaning still unknown.

Base (no-page) layers: **L00, L05–L08, L39–L44** in all 852 base-bearing node
records — the map-global base palette. `VisualTerrain` (713 B, byte-exact to
EOF): `layerCount 45`, `SurfaceShaderBlockKey 0x43DB1AAE19A710A9` (same key as
dumbo — TERRAIN.md §9.2 confirmed), **L40–L44 all link to L39**.

**MEASURED — the layer-graph table-locating law bites again, 68 bytes earlier
again.** `probe_tung_terrain.py`'s weak rule ("45 non-zero distinct u64s")
locks onto a plausible-but-wrong record table at offset **140**;
`probe_tung_layers.py`'s strong rule (every ShaderBlockKey must resolve in the
paired depot) finds the true table at offset **208** with **45/45 keys
resolving** (depot: 45 keys over 36 content-deduplicated records, 52 texture
params, 344 inline constants). Same 68-byte trap as tungsten. The 100%-resolve
rule is load-bearing on every map.

### B2. The full layer table

`painted` = weight page in block 1 (count = node-records carrying the layer);
`BASE` = `Flags & 0x0100`, no page. Tiling = `0x5707A992` (repeats/m).

| L | side | textures bound | tiling |
|---|---|---|---|
| 00 | BASE x852 | none (8 constants) | 0.060 |
| 01 | painted x232 | none | 0.030 |
| 02 | painted x219 | `t_com_asphaltdetail_02_ncs` (detail slot `0xB6C7E795`) | 0.025 |
| 03 | painted x221 | none | 0.040 |
| 04 | painted x41 | none (tinted `0x4FDCF6B1`) | 0.040 |
| 05 | BASE x852 | `t_ter_defaulttexture_{cv,ao,ao,nhs}` (placeholder set) | 0.050 |
| 06 | BASE x852 | placeholder set | 0.050 |
| 07 | BASE x852 | placeholder set | 0.050 |
| 08 | BASE x852 | `t_ter_defaulttexture_ao` only — **key `958F2824AC0D7783`, byte-identical to tungsten's L10 record** (0.5-grey constants) | 0.050 |
| 09 | painted x852 | `t_wum_td_sand_01_ncs` (detail) | 0.150 |
| 10 | painted x15 | none; tint (1.669, 1.323, 1.094) — **BackgroundMaterialIndex layer** | 0.050 |
| 11 | painted x852 | `t_wum_td_sand_01_ncs` | 0.030 |
| 12 | painted x66 | `t_wum_td_sand_01_ncs`; tint (0.936, 0.859, 0.803) — **the sand: 39.8% of the base field** | 0.070 |
| 13–22 | painted x41..x851 | none (constants only; various tints) | 0.01–0.25 |
| 23, 24, 27–34 | painted x23..x852 | **no parameters at all** (10 layers share the empty depot record `04B2008FD98C1DD4`) | — |
| 25, 26 | painted x84/x49 | none (constants only) | 0.16 / 0.04 |
| 35–38 | painted x742..x822 | none (constants only) | 0.10–0.60 |
| **39** | BASE x852 | `hfd_debug` at slot **`0xAE16A5C0`** — **the crater layer** (18 constants incl. a float4) | — |
| **40** | BASE x852 | 9 textures: `t_naf_graveldusty_02_{cv,ao,nhs}` + `t_wum_concreteedge_01_cv` + `t_wum_asphaltedge_01_{ao,nhs}` + `t_wum_crackedconcrete_03_{cv,ao,nhs}` | 0.135 |
| **41** | BASE x852 | 9 textures: `t_naf_chunkydirt_02` + `t_naf_sandrough_01` + `t_naf_stonerubble_01` (full cv/ao/nhs sets) | 0.120 |
| **42** | BASE x852 | `t_naf_chunkydirt_02_{cv,ao,nhs}` + sand detail | 0.150 |
| **43** | BASE x852 | `t_naf_sandrough_01_{cv,ao,nhs}` + sand detail | 0.050 |
| **44** | BASE x852 | `t_naf_graveldusty_02` partial + `t_wum_concretedebris_01/02_ao` (6 textures, odd slot set) | — |

**MEASURED — the "materials live on the base side" law holds for COLOUR but is
not absolute for textures.** All layers binding a `_cv` albedo are base layers
(L05–L07 placeholders, L40–L44 real, L39 crater). But **seven painted layers DO
bind a texture** — always the same shared detail texture (`t_wum_td_sand_01_ncs`
or `t_com_asphaltdetail_02_ncs`) on slot `0xB6C7E795`, never an albedo.
Tungsten's "all 24 painted layers bind zero textures" is tungsten-absolute, not
universal; the safe universal statement is: **painted layers never bind
colour**.

**MEASURED — crater structure confirmed:** L39 is the only layer binding
`0xAE16A5C0` (`hfd_debug`), L40–L44 link to it — the third map confirming the
crater/heightfield-decal slot identification (tungsten L28/L29–32, dumbo
L41/L42–45).

**MEASURED — constants:** `0xCF3F97E0` is an integer here too (values 0, 2, 4);
`0xCBB9A946` is Vec2 (0,0) on every layer that has it — two maps now where the
UV pan is never used; `0x4C200FE0` spans -0.01..+0.10; `0x2F9990B7` is 0.33–100
on ordinary layers but **234.188 on L40 and 0.328 on L41** — the crater-linked
layers again carry the out-of-class magnitudes (tungsten's L19–L21 were
1268–1333). Whatever `0x2F9990B7` is, its outliers cluster on crater-material
layers on both maps. `0x4FDCF6B1` (float3 tint) appears on 14 painted layers
with plausible warm albedo values — consistent with the corpus's "linear albedo
tint" reading.

### B3. Block 7 — the material raster

**MEASURED** (`probe_tung_basefield.py mp_outskirts`: 304 nodes walked, 0 bad
rows, footer exact): `pairCount = 12`, `BackgroundMaterialIndex = 0x0660FA80` —
**the same value as tungsten's**, but here it resolves through list 0 low-nibble
10 to outskirts' L10 (a 15-record painted layer with a warm tint), where on
tungsten it resolves to tungsten's L10 (the river). Same encoded value, two
different layers — the pair value is meaningful only through the map's own
lists. Pair 7 `0x06623180` (X=0x31, list 2) resolves to L41's
`wum`/`naf` gravel family — the third map where X=0x31 lands on the shared
gravel materials (TERRAIN.md §8's cross-map observation again).

Texel share of the resolved base field (pooled over all levels):

```
L12  39.8%   sand        (detail tex only — no albedo)   <- TERRAIN.md's "41% sand" confirmed
L14  22.4%   textureless
L03  13.5%   textureless
L10  13.5%   textureless (background layer)
L41   8.1%   naf_chunkydirt + sandrough + stonerubble    <- the ONLY albedo
L00   2.7%   textureless (the highway/asphalt ribbons)
L08   0.03%  default AO only
L01   0.01%  textureless
```

**MEASURED — the honest albedo ceiling on MP_Outskirts is 8.1%** (L41), against
tungsten's 20.6%. Even the highway network (L00 — its black ribbons in the
rasterised base field match the colour map's highways one-for-one, which is the
spatial proof the resolution is right) has no albedo. **The colour map is
practically the whole ground look on this map.**

---

## C. The colour map and THE DECOMPOSITION TABLE

### C1. The decomposition — both corpus tables are right at once

**MEASURED** (`probe_outskirts_decomp.py`; page counts `m` taken from block-1
metadata, never inferred from size). All 85 primary chunks decompose exactly,
zero residual:

| chunks | decomposition | residual after `m x 4356` |
|---|---|---|
| 80 | `149,297 (one xs=265 height payload) + m x 4,356 + 1 x 17,424` | 166,721 = 149,297 + 17,424 |
| 5 | `m x 4,356` only (the 5 Packed-height nodes; no height payload, **no colour tile**) | 0 |

`m` spans 58..121. Distinct residuals under ps=4356: **{0, 166721}** — two.
Under ps=2592: 39 distinct residuals. Under ps=5184: negative residuals (5
chunks). All 64 paired chunks: `size1 - (Σ child m) x 4,356 = 69,696 =
4 x 17,424` exactly — four child colour tiles, reversed order, per §5.3.

**So the apparent table conflict dissolves:** outskirts' page size is **4,356**
(raw 66x66, as `bf6_splat.py` says) AND its trailer is **17,424 = one 132² BC7
tile** (as TERRAIN.md §5.3 says). The trailer byte size is *exactly four pages*
— `17,424 = 4 x 4,356` — which is why every size-only derivation files this map
as ambiguous ("fit BOTH" in `bf6_colormap.py`). The tile/page combination is
not unusual in structure, only in arithmetic: it is the worst case where the
two hypotheses coincide byte-for-byte and only a content test can separate
them.

**MEASURED — the content test separates them decisively.** BC7 mode histogram
over all 80 trailers: **100.00% of 87,120 blocks in modes 4–7**
(m6: 84,233, m7: 1,857, m5: 555, m4: 475); paired trailers 100.00% over 64
chunks; zero uniform/degenerate tiles. Raw weight-page bytes read as BC7 blocks
would land ~94% in modes 0–3/invalid. The trailer is one real BC7 colour tile.

**Unlike tungsten there is NO second degenerate tile** — first tile == last
tile. The plugin's "colour tile is the FIRST tile of the trailer" rule and the
old "last 17,424 bytes" rule coincide here; k=1 is the simple case.

**MEASURED — detect_layout verification row.** Simulating the plugin's current
`bf6_splat.gd::detect_layout` scoring (fewest-distinct-residuals page pick,
then prefix+tile decomposition) on this map's numbers:

```
ps=2592: 39 distinct residuals      ps=5184: eliminated (negative residuals)
ps=4356:  2 distinct residuals      -> picks page 4356, tile 17424   CORRECT
```

The expected-page-size table row **4356 for outskirts is confirmed**, by exact
decomposition against block-1 metadata, on all 85 chunks.

### C2. The rendered colour map

**MEASURED** (`probe_outskirts_colorrender.py`, full BC7 decode via
`bf6_colormap.decode_tile`, 80 primary + 64 paired chunks, pages-only chunks
excluded): written to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Outskirts.png`
(4096²). **It reads as a coherent aerial photo**: a town at the world centre, a
grade-separated highway interchange east of it with the highway running
west–east and a second highway sweeping south-east, field parcels around the
town, and dense dendritic erosion-gully networks over the whole desert — all
matching the base-field raster's L00 highway ribbons positionally. Mean RGB of
painted texels **(0.560, 0.548, 0.540)**, mean alpha 0.002 — near-0.5-neutral,
consistent with the corpus's "modulates the composite" reading (no SDK overhead
JPG ships for outskirts to compare against; only Aftermath/Capstone/Tungsten
have one under `addons/bf_portal/terrain_decal/textures/`).

---

## D. Decals and roads — a DIFFERENT TerrainDecals record format

**MEASURED — the dumbo-verified parser fails completely on this map.**
`decals.TerrainDecals` is 11,788,880 bytes, header parses fine (slotCount 45 =
layerCount, 5 slots with a GUID: 5, 6, 7, 8, 39 — none of the GUIDs resolve in
the `_af` store), declared recordCount **484**. `probe_tung_decals.py`
(TERRAIN.md §10.2 layout: `[u32 propSize][props][pad][0x90 tail]`) parses **0
of 484 records** — the first record does not begin with a propSize.

**MEASURED — what the variant looks like** (`probe_outskirts_decals.py`,
first-record annotation): the record begins with a **16-byte identifier**
(12 significant bytes + 4 zero) + 16 zero bytes + counts + a tiling-like f32
(0.0099) + world AABBs at +0x40/+0x50 ((62.40, 97.07, -48.95)..(67.72, 97.07,
-43.62) on record 0 — a flat quad at constant y), with the **property stream
moved to the record's end**, carrying the SAME u64 slot hashes and typeId
`0xCC84D53D` texture refs as TERRAIN.md §10.3. Property-hash occurrence counts
over the whole blob:

```
_op  (0x3810287D4CE70B49)  484   == the declared record count exactly
_cv / _nhs / _ao           433 each
```

So every record carries exactly one `_op` prop (an independent record count),
and 433 of 484 carry a full texture set — the other 51 are op-mask-only, the
same class as tungsten's 14 mask-only records. A record-boundary signature scan
was tried and is **unreliable** (the id+zero-pad pattern recurs inside
records); the full record layout is **unknown** — flagged, not guessed.

**MEASURED — the leading u64 joins the authoring assets.** Record 0's leading
u64 is `0xAEF8B6DE64DD8673` = **12608028223114937971**, byte-identical to
field `0x4A98C1F8` on the level's runtime `TerrainQuadDecalData` instances.
But it is not a per-record identity: the level ships **546 authored
`TerrainQuadDecalData` instances** across 9 partitions (273 in the terrain
dir's `decals.ebx`, 121 in `_layers_world/area_06_terraindecals.ebx`, the rest
in `area_0N.ebx`) carrying only **2 distinct** `0x4A98C1F8` values, and those
two u64s occur 6,391 times in the blob. HYPOTHESIS: `0x4A98C1F8` is the quad-
decal *shader/material* key and this RES is the compiled **quad-decal**
variant (record 0 is a 5.3 x 5.3 m flat quad), distinct from dumbo/tungsten's
spline-fill variant; the per-record material lives in the trailing prop
stream, not the slot table.

**CONTRADICTION with TERRAIN.md §10:** it says "spline points are stripped
from runtime EBX". **MEASURED:** outskirts' runtime `TerrainQuadDecalData`
instances keep their full `Points` arrays (world-space spline points,
`StickToTerrain = true`, `IsOnlyForTweaking = true`, `DrawOrderIndex`,
atlas-tile fields). At minimum the stripping claim does not hold for quad
decals on this map — and those authored instances are a practical decal source
for the plugin that bypasses the unparsed compiled RES entirely.

---

## E. Everything else notable

**MEASURED — structure.** 227 `LayerData` partitions, 146 with zero Objects.
Busiest: `_layers_content/fx_global` (270), `_layers_content/lighting` (239),
`_layers_world/backdrop` (223), `area_07` (204), `area_03`/`area_02` (166
each). World content: 8 `area_0N` subworlds + `backdrop_subworld` (5.95 MB
physics, own 676 KB meshvariationdb, own 2.45 MB depot). 32 ShaderBlockDepots;
domination / escalation / kingofthehill / squaddeathmatch / strikepoint share
one byte-identical depot (`shaderblockdepot_9526102139013923511`).

**MEASURED — backdrop/skyline (open-task item).** Backdrop is a full subworld
here: `_layers_world/backdrop.ebx` (223 objects) + `backdrop_subworld` +
four spline layers (`backdrop_splines`, `_autopaint`, `_edgedetail`,
`_roadlines`). This is the map the corpus flagged as "335 backdrop entries vs
dumbo's 11" (`findings/level-root-smg-carries-backdrops.md` open item) — the
backdrop mass is real and lives in a dedicated subworld, so a placement walk
that skips non-`area_*` subworlds drops the entire skyline.

**MEASURED — lights / reflections / env decals (open-task items).**
`_layers_content/lighting.ebx` (239 objects) carries
`PbrBoxReflectionVolumeEntityData`, `PbrDistantReflectionVolumeEntityData`,
`PbrRectangularLightEntityData`, `PbrSphereLightEntityData`,
`PbrSpotLightEntityData`; `lighting/pfls_mp_outskirts_light_intbnc.ebx` adds
prop-light sphere lights. `EnvironmentDecalVolumeData` sits in `area_02/03/04/
05/07`, `area_05_decalvolumes.ebx` and `backdrop.ebx`. All are addressable EBX
in known partitions — no blocker beyond reading them.

**MEASURED — gamemode layout oddities (placement-walk hazards).**
`_layers_gameplay/` contains sixteen `area_0N_name_blockout_blueprints.ebx` /
`_destruction.ebx` files — the literal string **"name"** left in the filenames
by a template. Also `rooftopexclusions*.ebx`,
`sharedcollision_dom_tdm_sdm_stp_koth.ebx`, `sharedcollision_nonairmodes.ebx`
(gameplay-only collision that must not become visible geometry), a full
**payload** mode (`payload/mp_payload0`), `teamdeathmatch`, and a
`shared_cq_esc` layer shared by conquest/escalation. No `granite*`/BR content.

**MEASURED — ECS.** All 33 `EcsRuntimePrefabAsset` partitions are the identical
empty stub (`ent=1 arch=1 seg=1 edits=0 comps=[26]`), including
`generated/ag_generateroadsplinesprefabasset_*` and
`ag_loadhoudinifileprefabasset_*`. Tungsten's law holds: the stub is build
boilerplate, nothing is waiting at runtime.

**MEASURED — scatter join (open-task item): cannot be validated here.** The
level ships a `MeshScatteringDatabase` RES (9,208 B,
`mp_outskirts/meshscatteringdatabaseasset.MeshScatteringDatabase`), but all 46
`SingleTerrainLayerData` instances in `mp_outskirts_terrain4k.ebx` have
`MeshScatteringTypes = []`. No per-layer scatter is authored on the terrain
side, so the Identifier->catalogue join has no data on this map. (Also note 46
`SingleTerrainLayerData` vs `layerCount` 45 — one extra instance.)

**MEASURED — the biggest files are lighting again.**
`enlighten_mp_outskirts_highend.EnlightenDatabase` 105.3 MB, lowend 39.0 MB,
`materialgrid_win32.ebx` 15.5 MB; the TerrainDecals RES (11.8 MB) is #4 —
proportionally the largest decal resource of the studied maps.

**MEASURED — paths.** The terrain directory is `mp_outskirts_terrain4k`, and
the TerrainDecals RES hides at the doubled path
`mp_outskirts_terrain4k/mp_outskirts_terrain4k_game/glaciermp/levels/mp_outskirts/mp_outskirts/decals.TerrainDecals`.
`terr_dir()`'s "any dir containing 'terrain' that holds a .TerrainStreamingTree"
heuristic works; name-format assumptions do not.

---

## F. What generalises, what is outskirts-specific, what it contradicts

| finding | scope | notes |
|---|---|---|
| Page 4,356 + trailer = ONE 17,424 B BC7 tile; `17,424 = 4 x 4,356` makes size-only detection ambiguous — the BC7 mode test (100.00% modes 4–7) is the discriminator | outskirts (and the other "fit BOTH" maps: abbasid, aftermath, badlands, capstone, eastwood, subsurface) | Resolves this map's special assignment: both corpus tables are right simultaneously. `detect_layout`'s metadata-driven page pick already lands (4356, 17424) here — this is its verification row. |
| No degenerate second colour tile | outskirts | Tungsten's two-tile trailer is not universal; k must be counted per map (already the plugin's design). |
| Water can be entirely ABSENT — empty water layer, no entity, no ocean VE component | outskirts (first observed case) | The water diagnostic needs a third branch: above-floor / buried / **no entity**. |
| `findings/water-material-resolves-through-the-depot` lists outskirts as an ocean-variant map | CONTRADICTED on the level's own data | zero ocean/foam texture references anywhere under `levels/mp_outskirts/`. Needs upstream re-check. |
| TerrainDecals has (at least) TWO record formats; the dumbo layout parses 0/484 here | outskirts (likely other maps too) | TERRAIN.md §10 is dumbo-verified only, and its §14 risk flag was justified. The `_op`-hash count == recordCount is a format-independent record counter. |
| Runtime EBX keeps full `TerrainQuadDecalData` spline `Points` (546 instances) | outskirts | Contradicts §10's "spline points are stripped from runtime EBX" as a universal. Practical alternative decal source. |
| Painted layers CAN bind textures — but only shared detail `_ncs` textures, never colour | outskirts | Refines tungsten's absolute split: the universal law is "painted layers never bind COLOUR". |
| `0xAE16A5C0` = crater slot, one layer per map, linked layers | third map confirmed (L39 here) | |
| `0xCF3F97E0` int {0,2,4}; `0xCBB9A946` Vec2 (0,0); `0x2F9990B7` magnitude outliers sit on crater-linked layers | second map confirmed | |
| `BackgroundMaterialIndex 0x0660FA80` appears on BOTH tungsten and outskirts but resolves to different layers | every map | The pair value is only meaningful through the map's own layer lists — never compare raw pair values across maps. |
| Layer-graph table must be located by 100% depot-key resolution; the weak rule finds a wrong table exactly 68 bytes earlier | second map confirmed | The 68-byte offset delta repeating suggests a fixed-size header field difference, still unidentified. |
| Albedo ceiling 8.1% (vs tungsten 20.6%) | outskirts | The colour map is effectively the entire ground look here; colormap_enabled matters more on this map than any studied so far. |
| Terrain dir naming: third convention (`<level>_terrain4k`) | every map | |

---

## G. Next actions for the plugin, in priority order

1. **Keep the metadata-driven page detection and land the colour-map path on
   this map** — `addons/highpoly_toggle/bf6_splat.gd`. Verified here: page
   4,356 / tile 17,424 / k=1, colour tile first==last, paired = 4 tiles. The
   17,424 = 4 x 4,356 coincidence means any future "pages from size" fallback
   MUST NOT exist — pages must always come from block-1 metadata (they do in
   the current detect_layout; keep it that way and add outskirts' row to its
   verification comment).
2. **Add the "no water entity" branch to the water diagnostic** —
   `addons/highpoly_toggle/highpoly_gamesource.gd::water()` /
   `_water_partition()`. On outskirts the type search finds nothing; log "level
   has no water entity" instead of failing quietly. One line, third water class.
3. **Turn the colour map on for outskirts early** —
   `addons/highpoly_toggle/highpoly_mapcontext.gd` (`colormap_enabled`). With
   an 8.1% albedo ceiling, this single change is most of this map's ground
   appearance. `FIXED_MP_Outskirts.png` is the reference: town centre, highway
   interchange, gully networks.
4. **Do not ship a TerrainDecals reader that assumes the dumbo record layout**
   — whatever consumes `decals.TerrainDecals` (future roads work) must detect
   the variant (first u32 as propSize walks vs not) and fall back to skipping;
   on outskirts consider reading the 546 authored `TerrainQuadDecalData`
   instances (with `Points`) instead — `probe_outskirts_decals.py` documents
   both formats' evidence. New reader work would live beside
   `bf6_materialtree.gd` as a `bf6_terraindecals.gd`.
5. **Skyline: include `backdrop_subworld` in the placement walk** —
   `addons/highpoly_toggle/highpoly_gamesource.gd` (or wherever subworlds are
   enumerated). 223 backdrop objects + a 5.95 MB physics resource exist; if the
   plugin's walk only visits `area_*` subworlds, outskirts loses its entire
   horizon.
6. **Exclude `_layers_gameplay` collision/blockout layers from any future
   visual walk** — the `area_0N_name_blockout_*` and `sharedcollision_*`
   layers are gameplay-only; rendering them would poison the scene.
7. **Push two corrections upstream to `BF6_Frostbite_Research`** —
   `formats/TERRAIN.md` §10 (second TerrainDecals record format exists; quad
   `Points` NOT stripped from runtime EBX on outskirts) and
   `findings/water-material-resolves-through-the-depot.md` (outskirts carries
   no ocean variant in its own bundles — re-derive the per-map attribution).
