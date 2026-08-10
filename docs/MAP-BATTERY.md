# MP_Battery, end to end

Gibraltar. The coastal map of the fleet study — water is the headline layer here,
and battery turns out to be one of the two levels (with mp_capstone) that
`TERRAIN.md` §14.11 leaves open: **no `WaterSurfaceEntityData` anywhere**. This
document closes that question for battery: the sea is a placed backdrop mesh.

**Every claim is tagged MEASURED or HYPOTHESIS**, per the fleet brief. Probes are
in `tools/probe_battery_*.py` (new) plus the level-parameterised
`tools/probe_tung_*.py` run with `mp_battery`; all read the extracted 2026-08-01
pull through `BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`, read-only.

```
tools/probe_battery_decomp.py       chunk decomposition table + BC7 mode histograms
tools/probe_battery_colorrender.py  colour map assembled to FIXED_MP_Battery.png
tools/probe_battery_water.py        the no-water-entity proof + the ocean-plane mesh
tools/probe_battery_backdrop.py     backdrop/skyline census (task #36)
probe_tung_terrain|layers|basefield|decals|ecs|types|structure.py mp_battery
```

Cross-checks: `probe_tung_terrain.py mp_battery` walks every typed block
byte-exactly (block 0 slack 0, block 1 slack 0, block 7 node stream ends exactly
64 bytes — its footer — before block end, 0 bad RLE rows), and the chunk
directory consumes the resource exactly.

---

## 0. The map in one paragraph

**MEASURED.** MP_Battery is a 4,096 x 4,096 m world (block 0 root AABB
`x,z ∈ [-2048, 2048]`), ground **y = 0.112 to 435.077**, `WorldSizeY = 458.0`,
xs = 265, **81 streaming nodes** (5 Packed, 76 External) — a quarter of
tungsten's 269. Terrain palette **42 layers**; splat `LayerSlotCount = 6` (same
as tungsten, vs 62 on dumbo); typed blocks **0, 1, 4, 7, 8** (no block 2 density,
no block 5 — tungsten ships both). 772 terrain-decal records in 66 texture-set
groups, 294 `LayerData` partitions (113 with zero Objects), 39 ShaderBlockDepots,
54 `EcsRuntimePrefabAsset`s of which exactly one is populated, and **zero water
entities**. Terrain directory: `mp_battery_terrain4k` — a THIRD naming pattern
(vs `terrain_mp_tungsten`, `mp_dumbo_terrain`); anything that builds that path
from the level name silently finds nothing here.

---

## 1. THE DECOMPOSITION TABLE (detect_layout verification row)

**MEASURED** (`probe_battery_decomp.py`). 81 directory nodes -> 80 primary + 4
paired chunks on disk (1 primary missing from the pull), every on-disk size equal
to the directory's declared size.

Page-size pick, by the rewritten detect_layout's own rule (fewest distinct
residuals, none negative, using real per-node page counts from block 1):

```
page 2592   ok, 34 distinct residuals
page 4356   ok,  2 distinct residuals      <- winner
page 5184   NEGATIVE residual
```

**Page size = 4,356 (raw u8 66x66), exactly as the fleet brief's derived table
predicts.** The two residuals decompose under tile 67,600 ONLY:

```
residual       0 = prefix      0 + 0 x 67600     (4 pages-only chunks)
residual 216,897 = prefix 149,297 + 1 x 67600    (76 chunks: height payload
                                                  (xs=265) + ONE 260^2 BC7 tile)
tile 4624:  1/2 residuals decompose   tile 17424: 1/2   tile 67600: 2/2
```

BC7 mode histogram of the (single) trailer tile, all 76 chunks pooled:

```
first tile   321,100 blocks   modes 4-7  100.0%   (m6 88.5%, m5 6.4%, m7 3.5%, m4 1.6%)
```

There is **no second tile** on battery — the trailer is exactly one colour tile,
so tungsten's degenerate-second-tile hazard does not arise, and "first tile of
the trailer" and "last 67,600 bytes" coincide here.

**Paired chunks carry NO colour tiles.** All 4 paired chunks decompose as
children's pages ONLY (8,712 / 87,120 / 130,680 / 283,140 bytes = exactly the
four children's summed page counts x 4,356; residual 0). This is a variant the
laws don't state: *"paired chunks: colour tiles grouped first in reversed child
order"* is true where tiles exist (tungsten), but **k = 0 is legal** and battery
ships it on every paired chunk. A consumer that unconditionally slices four child
tiles off a paired chunk's tail reads weight pages as BC7 here.

What the OLD permissive detect_layout did on battery: picked (2592, 4624) like
everywhere else — both wrong — so weight pages were BC4-decoded from offsets
landing inside the colour tile, and the "colour tile" was the last 4,624 bytes of
the real 67,600-byte tile. Everything MAP-TUNGSTEN.md §C3 says, with battery's
numbers.

---

## 2. The colour map — a satellite photo of Gibraltar, sea included

**MEASURED** (`probe_battery_colorrender.py`). All 76 tiles decode as BC7
(`FORMAT_BPTC_RGBA`, no channel swap), assembled to
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_Battery.png`.

**It reads as a fully coherent aerial photo of Gibraltar** — harbour moles,
marina, the airport runway crossing the isthmus, the old town's orange roofs, the
Rock's quarry scar, the beaches, and the sea in deep blue-green with visible
shallows. One sentence verdict: **yes, a coherent aerial photo, and on this map
the OCEAN itself is painted into the terrain colour map.**

- Canvas mean RGB **(0.333, 0.362, 0.401)** — blue-dominant because roughly half
  the world square is sea.
- Per-tile mean RGBA **(0.484, 0.483, 0.486, 0.002)** — the RGB sits at the
  0.5-neutral of the modulate convention; alpha ~0.002 as on tungsten (not
  plaza's baked-AO alpha).
- Probe pitfall, recorded so nobody re-hits it: Pillow **premultiplies alpha when
  resampling RGBA**; with tile alpha ~0.002 any mean taken after an RGBA resize
  collapses to ~0.07. Convert to RGB before resizing.

---

## A. Water — no entity; the sea is a backdrop mesh (answers TERRAIN.md §14.11)

### A1. There is no water entity, anywhere

**MEASURED** (`probe_battery_water.py`). A type scan of all **3,131** partitions
under `levels/mp_battery` finds exactly ONE water/ocean-typed instance:
`OceanComponentData` in `lighting/ve_mp_battery_base_01.ebx`. No
`WaterSurfaceEntityData`, no `WaterAsset`, no `WaterOceanSimulationEntityData`,
no `WaterLevelDescriptionComponent` (tungsten has all four).
`_layers_content/water.ebx` is a LayerData with `Objects = []`;
`water_shared_schematic.ebx` holds only proximity/schematic logic
(AreaProximity/MathOp/PropertyCast) wired to the common
`schematicchannels/player_hub` channel — no geometry.

**MEASURED — the VE `OceanComponentData` is shading only.** Decoded via
`ve_dump.py`: identity Transform, `Albedo (0.600, 0.937, 0.949)`,
`IndexOfRefraction 1.03`, `WaterAbsorption RGB (0.2, 0.5, 1.0)`,
`ShoreFadeDistance 0.3`, `SunShadowScale 0.093`. No height, no extent — it
parameterises water shading, it does not place water.

### A2. THE SEA: `bd_seu_oceanplane_01`, placed by `_layers_world/world.ebx`

**MEASURED.** Exactly one StaticModelGroupMemberData in `world.ebx`'s 251-member
group references
`common/environment/europe/southerneurope/backdrop/ocean/bd_seu_oceanplane_01`
(partition `ea6fe8de-6554-4140-94ee-f0071d1d1aed`, mesh `e4047073-...`):

```
basis    right (0, 0, 499.646)  up (0, 499.646, 0)  forward (-499.646, 0, 0)
trans    (3326.647, 22.991, -6646.533)
mesh box (-171.92, 0.0, -91.03) .. (122.91, 0.0, 134.54)   <- FLAT at local y=0
```

90-degree yaw, uniform scale 499.646, so the plane spans roughly **147 x 113 km**
— an ocean to the horizon — and the surface sits at exactly one height:

**SEA LEVEL y = 22.991 m, which is 22.88 m ABOVE the terrain floor (0.112).**
The seabed terrain lies under it and the colour map paints it; the land decals'
lowest AABB Y is 23.6, immediately above the waterline. Unlike
tungsten/eastwood's buried `WaterSurfaceEntityData`, battery's sea is real,
visible, and **not water-typed at all** — it is a vista mesh with an ocean
texture (`seu_bd_oceantexture_01`), shaded through the VE ocean component's
parameters. A `bd_seu_oceanplane_01_noterrain.ebx` variant also ships (v1 UUID,
later-minted) but is not referenced by the level.

**HYPOTHESIS.** With no `WaterInteract`/physics water anywhere, battery's sea is
visual-only — the playable space never lets a soldier swim. Untested (needs the
combat-area polygon, out of scope).

### A3. Law verifications

- **MEASURED.** The exe layout law holds: `WaterSurfaceEntityData` size
  **0x280**, `+0x20 Transform`, `+0x90 QueryBoxHalfExtent`, `+0xB0 TileOffset`
  (`probe_battery_water.py` prints OK for all three) — verified even though
  battery has no instance to read.
- **The water-height-vs-terrain-floor diagnostic must not be inverted here.**
  On maps WITH the entity, "water y < terrain floor => buried" holds; battery
  shows the complement: no entity does NOT mean no sea. The plugin's `water()`
  returning null on battery is *correct data*, not a failure — but the sea it
  should still show arrives through the ordinary prop path (A4).

### A4. What this means for the plugin

`highpoly_gamesource.gd::water()` finds nothing on battery — fine. The sea
arrives (or should arrive) through the **placement walk** as a plain
StaticModelGroup member of `world.ebx`. Two traps:

- the member's `InstanceObjectSubVariation = [0]` and rendering overrides
  (shadows off, reflection off) are ordinary; nothing excludes it — if the walk
  covers `world.ebx` the ocean is one more prop with a 500x scale. If battery
  shows no sea in the plugin, the bug is in the walk or in a scale cap, not in
  the water reader.
- a consumer looking for "the water" by type will conclude battery is dry.
  `mp_capstone` is documented by the corpus as the same shape — whoever studies
  capstone should look for its own vista-water mesh by the same route
  (`probe_battery_water.py` works unchanged on any level).

---

## B. Terrain and ground layers

### B1. The palette: 42 layers, and the painted/textureless law has an exception

**MEASURED** (`probe_tung_layers.py mp_battery`). `VisualTerrain`: 42 layers,
`SurfaceShaderBlockKey 0x5C4EEEA3CD20B64C`, links **L37..L41 -> L36**. Depot: 42
keys over 30 content-deduplicated records, 69 texture params, 259 constants,
**42/42 keys resolve**; 37 distinct textures — battery binds far more textures
than tungsten's 8.

**The layer-table locator trap reproduces exactly.** The weak rule ("42 u64s
non-zero and distinct") fires at offset **128** and prints garbage rows
(`probe_tung_terrain.py`'s output for battery shows L00/L01 as degenerate
all-ones rows); the load-bearing rule (every ShaderBlockKey resolves in the
depot) finds the true table at offset **196** — 68 bytes later, the same delta
as tungsten. The 100%-resolve rule is not optional.

Layer table (painted = weight page in block 1; BASE = flag 0x0100, counts over
532 base-carrying node records):

| L | side | binds |
|---|---|---|
| 00 | BASE x482 | `t_com_asphaltdetail_02_ncs` (detail only) |
| 01 | painted x36 + BASE x428 | none |
| 02 | painted x36 | none |
| 03 | painted x26 | asphaltdetail (detail only) |
| 04 | painted x86 + BASE x47 | none |
| 05 | painted x150 | none |
| **06** | **painted x50** | **`t_wuu_grass_fairway_01_{cv,ao,nhs}` — real albedo on a PAINTED layer** |
| 07, 08 | painted x98, x161 | none |
| 09, 10 | painted x57 each | breakupmask_rgb + asphaltdetail (masks only) |
| 11 | painted x23 | none |
| 12, 13 | BASE x529 | **`roadblockout_01_{cv,ao,nhs}` — a DEBUG blockout texture** + defaulttexture_ao + breakupmask |
| 14 | BASE x529 | t_ter_defaulttexture set (grey placeholders) |
| 15 | painted x86 + BASE x3 | breakupmask + asphaltdetail |
| 16, 17 | painted x32, x22 | breakupmask + asphaltdetail |
| 18 | BASE x532 | t_ter_defaulttexture set |
| 19 | BASE x532 | t_ter_defaulttexture_ao only |
| 20-35 | painted x12..x64 | none (L25-L35 share contentHash `04B2008FD98C1DD4`) |
| **36** | BASE x532 | `hfd_debug` at slot **0xAE16A5C0** — the crater layer |
| 37, 38 | BASE x532 | `wum_ls_gravel_02` a/b + `wum_crackedconcrete_03` (9 textures) |
| 39 | BASE x532 | `wum_ls_gravel_01_a` + `t_wum_td_sand_01_ncs` |
| 40 | BASE x532 | `wum_dryrockygravel` + sand ncs |
| 41 | BASE x532 | `wum_concretedebris_01/02` (6 textures) |

**CONTRADICTION (say it loudly): the "painted layers bind zero textures" law is
NOT absolute.** Tungsten's split was total; battery's **L06 is a painted layer
with a real albedo set** (golf-fairway grass), and six more painted layers bind
mask/detail textures. The base-side law remains the right default (all *heavy*
texture sets are base-side), but `bf6_materialtree.gd`-style logic must not
*assume* painted == textureless — it must read the depot per layer.

**MEASURED — the crater law verifies: L36 binds `hfd_debug` at `0xAE16A5C0` and
L37..L41 link to it** — battery's exact analogue of tungsten L28<-L29..L32 and
dumbo L41<-L42..L45. Third map, same structure.

**MEASURED — battery's base palette contains debug/placeholder textures.**
L12/L13 bind `common/environment/common/debug/roadblockout_01` and L14/L18/L19
bind `t_ter_defaulttexture_*`. "Textured" does not mean "production art".

Constants (verifying MAP-TUNGSTEN.md §B2 on battery): `0xCBB9A946` = Vec2 (0,0)
on all 28 layers that carry it; `0xCF3F97E0` = integer 0/2/4 (never a float);
`0x4C200FE0` = 0.0 x22 / +0.01 x4; `0x2F9990B7` = 50..100 (battery lacks
tungsten's 1333 class); `0xF7652FB3` = 2.0..15.56. All consistent; nothing new
identified.

### B2. Block 7 — the material raster

**MEASURED** (`probe_tung_basefield.py mp_battery`). 244,944 B, dim 256, 49
nodes declared, levelMax 5, 0 bad RLE rows, footer `pairCount = 14` (11 used),
`BackgroundMaterialIndex = 0x00000080` — the "no background" **sentinel** (dumbo
and eastwood's value; tungsten had a real background). Lists resolve:
list1 (base) = [0,1,4,12,13,14,15,18,19,36..41], list2 (linked) = [37..41].

Texel share, pooled: **L10 50.6%** (masks only — the sea floor / undetailed
ground), L00 29.3% (detail only), **L13 10.2% (the DEBUG roadblockout — this is
the town's street grid)**, L02 7.0% (textureless), **L38 1.7%** (wum gravel —
the only real albedo in the raster), L01 0.9%, L04 0.4%. The rasterised field is
spatially coherent: the Rock and nature reserve resolve as the L00/L02 region,
the town as L13, the quarry scar as L38.

**The honest ceiling: ~1.7% of battery's ground resolves to a production albedo**
(L38), plus 10.2% debug blockout. Battery is the extreme end of tungsten's 20.6%
observation — **the colour map is not a nice-to-have here, it is essentially all
the colour this map's terrain has**, including the entire sea.

Pair `X = 0x31` resolving through list2 to the `wum_ls_gravel` family reproduces
TERRAIN.md §8's cross-map observation a third time (dumbo, tungsten, battery).

### B3. Splat/streams

**MEASURED.** Block 1: `LayerSlotCount = 6` (== tungsten's 6, vs 62 on
dumbo/aftermath/eastwood — still meaning unknown, still not the layer count),
133 nodes, 8,262 records, byte-exact. Base entries L18/L19/L36..L41 appear in
all 532 base-carrying records — the map-global base palette. Battery ships
block 4 (381 B) and block 8 (532,817 B, dim 265, 341 nodes, maskUnknown0 = 4)
but **no block 2 and no block 5**.

### B4. Scatter — the Identifier join CANNOT be validated here

**MEASURED.** Battery ships a 69-entry `MeshScatteringDatabase` (budgets
20,000 x 4 tiers, cellBudget 4096) but **all 46 `SingleTerrainLayerData`
instances in `mp_battery_terrain4k.ebx` have EMPTY `MeshScatteringTypes`**. The
join stays unvalidated on this map; the catalogue-without-users state is itself
evidence for "catalogue, not placement". Small upstream nit: `msdb.py`'s header
docstring says `reserved[4] = 0`, but battery reads (512, 1024, 1536, 2048)
there — those words carry something.

---

## C. Decals and roads

**MEASURED** (`probe_tung_decals.py mp_battery`). `decals.TerrainDecals` is
3,904,244 B: `slotCount 42` (== layerCount), **772 records, 0 chain breaks**, 66
texture-set groups. Stored under the naming oddity
`mp_battery_terrain4k/mp_battery_terrain4k_game/glaciermp/levels/mp_battery/mp_battery/decals.TerrainDecals`
(the RES leaf embeds a second full asset path).

- Slots used: **12, 13, 14, 18, 19 — exactly the textured base layers** (the
  tungsten observation again), plus **slot 65535 on 2 records** — a sentinel a
  slot-indexed consumer will crash or mis-bucket on. New gotcha; tungsten had no
  such records.
- Groups mix libraries heavily: `seu_` (southern europe) + `naf_` (north africa)
  + `cas_` (central asia roadlines) in one map; one group pairs `cas_roadlines`
  colour with a `seu_roadlines_01_op` mask. Group by whole texture set.
- Top groups: seu_sidewalktile_01 x76, seu_dirtmask (op-only) x55,
  naf_pavementsquaretiles_02 x54, seu_concretepatchspline x39,
  naf_roadvariationmask (op-only) x34, cas_roadlines x28.
- Coverage: x 394..2042, z -548..509 — the old town only; the Rock, the airport
  and the whole sea carry no terrain decal. **Decal Y spans 23.6..99.1 — the
  floor of the decal set sits 0.6 m above the sea level of 22.99**, a tidy
  independent corroboration of A2.

---

## D. Everything else notable

**MEASURED — structure.** 294 LayerData partitions, 113 with zero Objects.
Largest: `_layers_world/generated/ag_aftermathscatter_aftermathentities_fc82f124.ebx`
(**1,952 Objects** — a generated battle-damage scatter layer; the biggest layer
in the level and easy for a placement walk to underestimate), fx_global (294),
lighting_lpv (292), lighting (251). World content: `_layers_world/area_001..010`
subworld dirs (each with own staticmodelgroup.physics 1.7-7.5 MB and
meshvariationdb) plus per-area sub-layers `area_NN_{architecture,decals,
decalsfacade,props,propsfacade,predestruction,roads,vegetation,design}`.
Naming oddities a walker must survive: **`area_07_porps.ebx` (sic)**,
`backdropbuildingsnear.ebx` (0 objects), `_layers_autotests/` and
`_layers_tools/` shipping in retail data.

**MEASURED — ECS.** 54 runtime prefabs: 53 are the empty stub
(`ent=1 arch=1 seg=1 edits=0 comps=[26]`) and **one is populated:
`backdrop_near_ecsprefab` (ent=47 arch=3 seg=6 edits=40 comps=[0,42,50,54,58])**.
Battery joins dumbo/aftermath as a level with a real ECS payload — and it is the
*backdrop* layer that has it. The stub-is-boilerplate law holds.

**MEASURED — gamemode layers.** `_layers_gameplay` carries conquest0, domination,
kingofthehill, rush(+rush0), sabotage + `mp_sabotage0`, **payload**,
**escalation**, **freeroam0**, **keyevents**, squaddeathmatch, teamdeathmatch,
strikepoint (under `flag/`), squadobliteration, customportal, portal_gameplay,
portal_cooked, `dd_modbuildercustom1_volumes_schematic`, plus gating layers
`areaNN_extra` / `areaNN_interiors` / `areaNN_rooftops`, `blockingvolumes`,
`ceiling`. Five modes share one depot byte-for-byte
(`shaderblockdepot_9526102139013923511` = conquest/domination/koth/escalation/
strikepoint) — the tungsten sharing law again.

**MEASURED — lighting/misc.** Enlighten 182.4 MB highend + 118.4 MB lowend
(bigger than tungsten's); `materialgrid_win32.ebx` 15.5 MB. Reflection volumes
exist: `_layers_content/lighting_lrv.ebx` holds `PbrBoxReflectionVolumeEntityData`
+ `PbrDistantReflectionVolumeEntityData`. Prop-light env-decal volumes ship as
`lighting/pfls_*_wedv_battery_ct*.ebx` (per-colour-temperature variants,
ct2500..ct8000b). Per-map FX: `_layers_content/fx_backdrop.ebx` imports the
ambient-warfare set including **`fx_battery_ambwar_multimissile_waterstrike`**
(missiles hitting the sea), chinook rescue, artillery citystrike, building-fire
smoke pillars — a coastal-war vista show around the playable area.

### D1. Backdrop / skyline meshes (open task #36)

**MEASURED** (`probe_battery_backdrop.py`). Battery's skyline is FOUR tiers:

1. **In-level backdrop meshes — the rare part.** `backdrop/buildings/` inside
   the level directory ships 26 building prefabs (`bd_seu_buildingsbattery_01..25`
   + `_44`) and `backdrop/vegetation/` 25 vegetation tiles
   (`bd_seu_vegetationbattery_01..25`) — **51 MeshSets shipped INSIDE the level
   dir**, with a shared material palette (`bd_seu_buildingsbattery_palette`).
   These are the Spanish-coast towns across the bay.
2. **THE PLACEMENT ODDITY: those 50 tiles are placed by a StaticModelGroup in
   the LEVEL ROOT partition `mp_battery.ebx`** (50 members, 1 instance each,
   translation Y 30.8..374.4) — not by any layer or subworld. A placement walk
   that only visits layers/subworlds **misses the entire skyline**.
3. **Billboards.** `_layers_world/backdrop.ebx` (130 Objects) places
   `common/.../backdrop/buildingsbillboard/seu_bd_buildingsbillboard_01..08`.
4. **Near backdrop.** `_layers_world/backdrop_near.ebx` (71 Objects): real
   `oldtownfacade`/`midrise`/roof prefabs with battery-specific colour
   variations (`ovs_battery/ov_seu_oldtownfacade_01_*`), plus the populated ECS
   prefab above. `_layers_world/world.ebx` (251 members / 3,816 instances) is
   the catch-all group: window shutters x939, static doors x511, grilles x416,
   scatter weeds, `seu_cliffhuge_11` x26, `bd_seu_buildingcluster_02` x35 —
   **and the ocean plane** (§A2).

Plus `_layers_content/fx_backdrop.ebx` (the war-vista FX) and the empty
`generated/backdropbuildings_output.ebx` stub.

---

## E. Generalisation — what holds, what battery adds, what it contradicts

| finding | scope | notes |
|---|---|---|
| Page size **4356** for battery; exact decomposition {0, 216,897 = 149,297 + 1 x 67,600}; single 260² BC7 tile, 100.0% modes 4-7 | battery (verification row) | Confirms the brief's derived table and the detect_layout fix. |
| **Paired chunks can carry ZERO colour tiles** (all 4 on battery are pages-only) | at least battery | **Contradicts** an unconditional "paired trailer = 4 child tiles" read. `bf6_splat.gd` must accept k=0 per chunk. |
| **A painted layer CAN bind a real albedo** (L06 fairway grass) | at least battery | **Weakens** MAP-TUNGSTEN.md's "the split is total". Read the depot per layer; never branch on painted/base for texturing. |
| A level can have **NO water entity yet a real sea**: vista mesh `bd_seu_oceanplane_01` at y=22.991, VE OceanComponent shading it | battery (capstone predicted same) | Answers TERRAIN.md §14.11 for battery. "No WaterSurfaceEntityData" != "dry map". |
| Water exe-layout law (0x280 / +0x90 QueryBoxHalfExtent / +0xB0 TileOffset) | every map | Verified against the exe on battery. |
| Crater slot `0xAE16A5C0`, one layer per map, linked family above it (L36 <- L37..41) | every map | Third map confirming. |
| `0xCF3F97E0` integer 0/2/4; `0xCBB9A946` Vec2 (0,0); `0x4C200FE0` small signed float | every map | Verified. |
| Layer table located ONLY by 100% depot-resolve; weak rule fires 68 bytes early | every map | Reproduced exactly (128 vs 196). |
| Empty ECS stub is boilerplate; populated prefabs are readable when they exist | every map | 53 stubs + 1 populated (backdrop_near). |
| Decal slots = textured base-layer indices; **slot 65535 sentinel records exist** | battery adds the sentinel | Guard the decal reader. |
| Terrain dir naming: third pattern `mp_battery_terrain4k` | every map | Find-by-suffix, never build-by-name. |
| Skyline placed by the LEVEL ROOT partition's StaticModelGroup | at least battery | Placement walks must include the root partition, not only layers/subworlds. |
| Colour map = satellite photo incl. ocean; ~1.7% real-albedo ground | battery magnitude, general shape | The strongest per-map argument yet for enabling `colormap_enabled`. |

---

## F. Next actions for the plugin, in priority order

1. **detect_layout verification row** (`addons/highpoly_toggle/bf6_splat.gd`):
   battery must come out page 4356 / tile 67,600, trailer k ∈ {0, 1}, prefix set
   {0, 149,297}. `probe_battery_decomp.py` is the oracle.
2. **Accept k = 0 tiles on paired (and primary) chunks** in `bf6_splat.gd` —
   battery's 4 paired chunks have no colour tiles; slicing four child tiles off
   their tails reads weight pages as BC7. The `_tiles_in` "k=0 is legal" comment
   is right; make sure the paired-tile consumer honours it too.
3. **Turn the colour map on** (`highpoly_mapcontext.gd::colormap_enabled`) —
   on battery ~98% of the ground has no production albedo and the sea's colour
   exists ONLY here. `FIXED_MP_Battery.png` shows what correct output looks like.
4. **Make the placement walk cover the level ROOT partition's StaticModelGroup**
   (`bf6_walk.gd` / `highpoly_gamesource.gd`) — otherwise battery's 50-tile
   skyline (and anything else a map roots there) never renders. Verify: 50
   `bd_seu_*battery_*_mid` instances placed, plus the ocean plane from
   `world.ebx` at scale 499.6.
5. **Log the battery water case explicitly** in
   `highpoly_gamesource.gd::water()`: "no WaterSurfaceEntityData in this level —
   if it is coastal, the sea is a backdrop mesh (see MAP-BATTERY.md A2)" instead
   of a silent null. Never synthesize a plane from the VE ocean component.
6. **Crater slot `0xAE16A5C0`** in `bf6_terrainlayers.gd` (battery L36) — same
   action tungsten already queued; battery is a second test map.
7. **Guard decal slot 65535** in the terrain-decal reader (2 records on battery).
8. **Upstream**: TERRAIN.md §14.11 — battery's answer (vista mesh, y=22.99, the
   `world.ebx` member); `msdb.py` docstring reserved-words correction; note the
   `mp_battery_terrain4k` naming variant wherever terrain-dir discovery is
   documented.
