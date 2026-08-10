# RESEARCH-LEVELROOT — what the level root and `_layers_world` actually place, fleet-wide

Date: 2026-08-10. READ-ONLY study of the 2026-08-01 extracted dump
(`bf6_paths.BUNDLES`); no plugin code touched.

The original premise ("the walk never enters the level root") was already
refuted before this study — the walk measurably captures Battery's ocean
plane, Eastwood's bd_wuu clusters, Contaminated's mountainfort set. This doc
answers the three questions that REMAINED:

1. does a statically readable transform list exist for Dumbo's generated
   skyline? — **YES** (§2);
2. per-map, what does a root-entering walk have to contain? — census table
   (§3);
3. who places FireStorm's giant FX-card meshes, with what transforms? — §4.

Probes (all in `tools/`, all read-only):

| probe | what it measures |
|---|---|
| `probe_lvlroot_survey.py` | fleet-wide census of `mp_<level>.ebx` + `_layers_world/*.ebx`: every SMG (members/placed/transform rows/categories/y-range), every `*ReferenceObjectData` carrier, subworld refs + AutoLoad. `--json` dumps the raw numbers. |
| `probe_lvlroot_shape.py` | raw record-shape diff of root/world SMGs vs the walk-proven subworld ones |
| `probe_lvlroot_dumbo_cityblocks.py` | the Dumbo generated-skyline chain end to end (root SMG members, one generated blueprint + mesh, the 963 `TerrainFillDecalData`, the MVDB record shape, the ECS spline prefab) |
| `probe_lvlroot_firestorm_cards.py` | FireStorm root SMG full transform list + the FX-card carriers in `_layers_content/fx_*.ebx` |

## 1. MEASURED — root/world SMGs are byte-shape-identical to the ones the walk already parses

`probe_lvlroot_shape.py`, 7 samples (roots of battery/tungsten/eastwood,
world.ebx of battery/contaminated, battery `area_001` = walk-proven class,
battery `conquest_subworld`): **one distinct (top-hash-set, member-hash-set)
signature across all seven**. Same type guid
`2e5723ed-effe-ff86-2c68-26573e1011a6`, same member hashes (MemberType
`0xB608BEEE` and MeshAsset `0x1B4A547C` both populated, per-member), same
LinearTransform member hashes, and the same flat-bools hazard everywhere
(`InstanceEnabled` empty, `0x8F8D9F78` packed ints like `0x01010101`). The
walk's SMG parser needs **zero** changes to read root/world partitions.

Fleet-wide corollary (survey, 27 roots): **every root-SMG member carries
explicit `InstanceTransforms` — `xf_rows == placed` and
`members_without_xf == 0` on every map.** No implicit/identity placement
exists at the root.

## 2. THE DUMBO GENERATED SKYLINE — verdict: static transforms EXIST

**MEASURED** (`probe_lvlroot_dumbo_cityblocks.py`):

* `mp_dumbo.ebx` root SMG (@30) has **157 members / 185 placed**: **155
  members are the `ag_motivebackdropsoutputs_generated_blueprints_*`
  partitions, one placed instance each, each with a full LinearTransform**
  (y 35.2..263.3; e.g. `3688b839` at (767.0, 84.5, −2226.5), `55e28f84` at
  (−2473.1, 169.4, −881.9)). The other 2 members are
  `euu_commercial_modern_building_03_b` ×28 and
  `euu_commercial_manhattan_building_03` ×2.
* There are **155 generated-blueprint partitions** in
  `mp_dumbo/generated/` (not 1 as MAP-DUMBO.md §D assumed), each =
  `ObjectBlueprint → StaticModelEntityData → RigidMeshAsset` with its own
  `_mesh.ebx` + `.MeshSet` (shipped beside it) + physics. The mesh's
  LodGroup import resolves to `common/artsetup/lodgroups/backdrop_nolods.ebx`
  (single-LOD backdrop); the `Mesh` import resolves to the partition's own
  `_mesh.ebx`. **The skyline is baked, per city block, into these 155
  shipped meshes** — the walk places them like any other SMG member.

So the "generator" question dissolves: **the generator's OUTPUT ships and is
placed statically; nothing needs reimplementing.** Renderability depends only
on the plugin's normal MeshSet/geometry pipeline accepting these generated
`_mesh.ebx` partitions (they are ordinary `RigidMeshAsset`s with 5
`MeshMaterial`s each, empty `SurfaceShaderName` — materials resolve through
the MVDB like everything else).

The 92 `bd_eus_dumbo_{brooklyn,manhattan}_NN_mid` MeshSets have **NO static
transform list anywhere**. Measured absences, one per candidate the task
named:

| candidate | measurement |
|---|---|
| the 155 generated blueprints | **0** `bd_eus_dumbo_*` imports across all 310 generated `.ebx` (blueprints + meshes) |
| the 963 `TerrainFillDecalData` (`..._city_blocks`) | records are **closed-spline ground-fill polygons**: `Points` = Vec3 world-coord outlines (`IsClosed=True`, `SplitToMatchHeightfield=True`, `DrawOrderIndex=100`, `Shader2d/3d=null`); **zero import-reference fields; the partition has 0 imports at all**. No meshes, no per-record transforms — fill outlines only. |
| the 3 "Manual City Blocks" ECS entities | name + partition-guid **stubs** (`{Name, PartitionGuid, null guid}`) — no payload |
| the ECS spline payloads | 83 `LocalTransform` edits = the spline CONTROL POINTS (generator INPUT), not building placements |
| the MeshVariationDatabase (`mp_dumbo/mp_dumbo/meshvariationdb_win32.ebx`) | one `MeshVariationDatabase` record, 5,634 `MeshMaterialVariation`s; entries hold `Mesh` import + `Materials` (`SurfaceShaderId`/`SurfaceShaderGuid`) — **materials only, no transforms**. 184 imports resolve to `bd_eus_dumbo_*`. |

**HYPOTHESIS** (consistent with all of the above): the 92 mid meshes are the
generator's *source library*, consumed at build time; at runtime they exist
only as MVDB material entries. A placement walk has nothing to place them
with, and doesn't need to — the 155 baked city-block meshes ARE the skyline.

**MEASURED — the pattern generalises:** `mp_aftermath.ebx` root SMG (@31)
places **76 members / 76 placed, ALL of them generated blueprints** (its
`generated/` dir has exactly 76), y 56.3..323.2, and carries the same
`lay_backdropbuildingsescsplines` layer-ref. `mp_aftermath_portal` mirrors it
(76/76). No other level has `generated_blueprints` partitions (fleet scan of
every `generated/` dir: Dumbo 155, Aftermath 76, all others 0).

## 3. FLEET CENSUS — what a root-entering walk must contain, per map

**MEASURED** (`probe_lvlroot_survey.py`; regenerate the raw JSON with
`--json`). Only one walk cache existed at study time
(`user://bf6_walk_mp_tungsten_v4_*.idx`); asserting against it: **all 27
Tungsten root-SMG member leaf names are present in the cache — 0 missing.**
For every other map no cache exists, so the table below IS the assertion
target: a correct walk's census must contain at least these root placements.

| level | root SMG placed (xf rows) | root cats | root y | what the root places | subworlds (autoload) | `_layers_world` files placing / SMG placed / carrier refs |
|---|---|---|---|---|---|---|
| mp_abbasid | 25 (25) | backdrop | 76.5..86.0 | `bd_naf_buildingsabbasid_NN_mid` skyline ring | 8 (3) | 43 / 43,640 / 1,869 |
| mp_aftermath | 76 (76) | backdrop | 56.3..323.2 | **all 76 generated city-block blueprints** (§2) | 11 (4; incl. `AftermathGauntlet` auto, `Winter_Event`/`Default_Event` off) | 1 / 1 / 0 — `world.ebx` is a router (55 layer-refs + 11 subworld-refs) |
| mp_badlands | 35 (35) | backdrop+veg | −6.9..752.6 | `bd_wum_terrainbadlands_NN_near/far` vista ring | 8 (3) | 19 / 10,459 / 693 |
| mp_battery | 50 (50) | veg+backdrop | 30.8..374.4 | `bd_seu_vegetationbattery/buildingsbattery_NN_mid` | 8 (3) | 55 / 35,710 / 1,323 — incl. `bd_seu_oceanplane_01` (the y 22.99 ocean) |
| mp_capstone | **0** | — | — | root places nothing | 8 (3) | 30 / 13,772 / 869 |
| mp_contaminated | **3,885** (3,885) | other+backdrop+veg | 193.6..521.8 | a whole backdrop FOREST: `bd_tr_com_sprucenorway_01_m_b` ×643, trunk logs ×1200+, raspberry ×400… (38 members) | 8 (3) | 64 / 33,099 / 739 |
| mp_dumbo | 185 (185) | backdrop+other | −134.3..263.3 | **155 generated city blocks** + 30 `euu_commercial_*` (§2) | 8 (3) | 9 / 533 / 874 (incl. `global_debrispiles` 874 refs) |
| mp_eastwood | 67 (67) | backdrop+veg | 78.5..806.6 | `bd_wuu_stormdrain/terraineastwood/…` (the 71-cluster study's entry point) | 9 (4) | 25 / 25,115 / 1,119 |
| mp_firestorm | 16 (16) | (vista terrain)* | 257.6..1452.8 | `bd_cas_terrainfirestorm_01..08_near/far` rings (§4) | 8 (3) | 37 / 26,495 / 3,338 |
| mp_golmudrailway | 5 (5) | other | 696.8..742.6 | 2 rural chimneys ×2 + **`cas_velociraptor_01`** (mountain-top easter egg) | 8 (3) | 22 / 24,314 / 188 |
| mp_granite | 69 (69) | backdrop+veg | −1.9..968.6 | `bd_wuu_terraingranite_NN_near/far` + backdrop veg | 10 (**8**) | **0 — no `_layers_world` dir**; world lives in named subworlds `WORLD`, `CONTENT_NonStreaming`, `ROADS`, `Vista_LG/Med`, `BLOCKOUT`, `GAMEPLAY`, `PATHFINDING` (all auto) |
| mp_isolated | **0** | — | — | root places nothing | 8 (3) | 10 / 7,897 / 328 |
| mp_limestone | 49 (49) | backdrop+veg | 36.1..385.3 | `bd_seu_buildingslimestone_NN_mid` ring | 8 (3) | 21 / 14,560 / 392 — incl. `bd_seu_oceanplane_01` + 2 `com_fountain_water_sphereplane` |
| mp_outskirts | 2 (2) | other | 96.5 | `ind_cablefloor_02/03` | 8 (3) | 24 / 18,162 / 922 |
| mp_plaza | **0** | — | — | root places nothing | 8 (3) | 54 / 42,298 / 1,732 |
| mp_portal_sand | **0** | — | — | root places nothing | **3** (2: Content, GAMEPLAY) | 0 — no `_layers_world` dir |
| mp_propaganda | — | — | — | **NO level-root partition in the dump** — the level dir ships only `prefabs/` + `tweakables/` (7 files). Nothing for a walk to do. | — | — |
| mp_subsurface | **0** | — | — | root places nothing | 8 (3) | 37 / 25,049 / 526 |
| mp_tungsten | 27 (27) | backdrop+veg | 82.9..889.4 | `bd_cas_terraintungsten_NN_near/far` + veg | 9 (4; incl. `GraniteBR` auto) | 33 / 24,762 / 639 |
| mp_aftermath_portal | 76 (76) | backdrop | 56.3..323.2 | same 76 generated blueprints as mp_aftermath | 10 (4) | 1 / 1 / 0 |
| mp_portal_lobby | 0 | — | — | root places nothing (UI + Gameplay subworlds only) | 2 (2) | 0 |
| mp_granite_*_portal (clubhouse, mainstreet, marina, militaryrnd, militarystorage, techcampus) | 55 (55) | backdrop+veg | −1.9..968.6 | granite vista subset (35 bd + 20 veg) | 10 (8) | 0 — granite subworld naming |
| mp_granite_underground_portal | 69 (69) | backdrop+veg | −1.9..968.6 | full granite vista set | 9 (8) | 0 |

\* the survey's keyword classifier tags `*firestorm*` as "fx" ("fire"
substring); the 16 members are vista TERRAIN meshes, not FX.

Cross-cutting **MEASURED** facts the walk can be asserted against:

* Root carriers beyond SMG + subworld/layer refs are **VisualEnvironment
  only** on every map (6-7 `VisualEnvironmentReferenceObjectData`, no
  Object/SpatialPrefab refs at root anywhere).
* Every map's root reaches `_layers_world` through
  `SubWorldReferenceObjectData` `…/_Layers_World/World` with
  **AutoLoad=True** (where the dir exists); `_Layers_Content/Content` and
  `_Layers_Gameplay/Gameplay` are likewise AutoLoad=True fleet-wide.
  `Marketing`, `_Layers_Tools`, `_Layers_Autotests`, `Lighting_*` are
  AutoLoad=False fleet-wide. Special autoloads: Tungsten `GraniteBR`,
  Aftermath(+portal) `AftermathGauntlet`; Aftermath's seasonal
  `Winter_Event`/`Default_Event` are off.
* **Granite-family levels have no `_layers_world` at all** — a walk keyed on
  directory names instead of the root's `SubWorldReferenceObjectData`
  BundleNames would silently lose the entire world on 9 levels
  (mp_granite + 8 portal variants). The BundleName list is the contract.
* 5 maps place NOTHING at root (capstone, isolated, plaza, portal_sand,
  subsurface, + portal_lobby): a walk change that only added the root gains
  nothing there — their skylines/seas are in `_layers_world`/subworlds.

## 4. FIRESTORM'S GIANT FX-CARD MESHES

**MEASURED** (`probe_lvlroot_firestorm_cards.py`).

Two separate systems, and the y-values in the task straddle both:

**(a) The root SMG (@26) — 16 vista terrain meshes, ordinary SMG members
with explicit transforms, identity basis.** Near ring
`bd_cas_terrainfirestorm_01..08_near` at (±8186.38, y 257.6..744.1, ±8186.38);
far ring `_01.._08_far` at (±24610.12, y 509.2..1452.8, ±24610.12). The walk
carries these exactly like Tungsten's `bd_cas_terraintungsten` set.

**(b) The oil-field plume cards — placed by
`mp_firestorm/_layers_content/fx_oilfields.ebx`** (layer name
**`fx_oilfields`**, under `_Layers_Content/Content`, AutoLoad=True from the
root). Six placements match the card patterns; they split by carrier type:

| blueprint | carrier @inst | translation | what it is |
|---|---|---|---|
| `ob_fx_bd_vertical_smokeplume_03_firestorm` | **ObjectReferenceObjectData** @6 | (3611.7, **956.8**, 890.3) | **ObjectBlueprint → StaticModelEntityData** (mesh `…smokeplume_03_firestorm_mesh.ebx`). The card's size is in the reference's BASIS: R=(−164.0, −1049.5, 1952.8) \|R\|≈2223 m, U=(194.6, 3553.5, 1926.2) \|U\|≈4047 m, F \|F\|≈1369 m — a ~2.2 × 4.0 km tilted card. **An ordinary static-mesh placement; the walk carries it iff it visits the `fx_oilfields` content layer and applies the scaled basis.** |
| `fx_oilfields_firestorm_smokecard_blend` | EffectReferenceObjectData @79 | (3957.3, **1320.4**, 946.6) | `EffectBlueprint` (1 `EmitterGraphEntityData` + 1 `EffectEntityData`) — **NOT a mesh** |
| `fx_oilfields_firestorm_topblend` | EffectReferenceObjectData @72 | (2458.9, **1668.6**, 2490.6) | EffectBlueprint — NOT a mesh |
| `fx_oilfields_smoke_background` | EffectReferenceObjectData @61 | (978.3, 441.0, 3573.8) | EffectBlueprint — NOT a mesh |
| `fx_oilfields_smoke_distantonly` | EffectReferenceObjectData @80 | (1734.2, 163.3, 1011.7) | EffectBlueprint — NOT a mesh |
| `fx_oilfields_smokepillar_background_huge` | EffectReferenceObjectData @57 | (3469.7, 170.4, −266.6) | EffectBlueprint — NOT a mesh |

All six: `Excluded=False`. The five Effect refs have identity bases — their
visual size lives inside the emitter graphs (FX-sheet territory, see
MAP-FIRESTORM.md §D2), not in any transform a static walk could use.

**Correction to MAP-FIRESTORM.md §D2 while measuring:** only the `ob_fx_bd_*`
plume is a mesh; `smokecard_blend` (y 1320) and `topblend` (y 1669) are
EffectBlueprints. The doc's "treat the `ob_fx_bd_*` / `*_smokecard_*`
blueprints as static meshes" is half-right — the smokecard/topblend/…
family cannot be drawn by the placement walk; they need the FX-sheet path.

## 5. Consequences for the plugin (research only — nothing changed here)

1. **Dumbo/Aftermath skyline:** no generator, no MVDB-transform hunt. Verify
   the walk does not FILTER the 155/76 `ag_motivebackdropsoutputs_*` members
   (their leaf names don't match `bd_*`/prop conventions) and that the
   geometry pipeline accepts their `_mesh.ebx`+`.MeshSet`; materials resolve
   via MVDB as usual (LodGroup `backdrop_nolods`).
2. **Walk asserts:** the §3 table's root numbers (placed counts, y-ranges)
   are cheap per-map census assertions; Tungsten's cache already passes.
3. **Granite family:** follow BundleNames from
   `SubWorldReferenceObjectData`, never the `_layers_world` directory
   convention.
4. **FireStorm:** drawing `ob_fx_bd_vertical_smokeplume_03_firestorm` from
   `fx_oilfields` (scaled-basis card) is the one static-mesh win; the other
   five plumes are emitters, out of walk scope.
