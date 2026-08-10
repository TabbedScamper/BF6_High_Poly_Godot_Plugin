# MP_FireStorm, end to end

One map read from the shipped data, applying the laws established in
`MAP-TUNGSTEN.md` and recording where MP_FireStorm confirms, refines, or
contradicts them. **Every claim is tagged MEASURED or HYPOTHESIS**; a MEASURED
claim names the resource/offset/value and the probe that reproduces it.

Probes: the tungsten probes are level-parametric and were run as
`probe_tung_*.py mp_firestorm`; four firestorm-specific probes were added
where the tungsten tooling was insufficient:

```
tools/probe_firestorm_decomp.py       chunk decomposition table + BC7 tile verdicts
tools/probe_firestorm_colorrender.py  BC7 260^2 tile assembly -> FIXED_MP_FireStorm.png
tools/probe_firestorm_decals.py       decal parser (tungsten's parses 0 of 505 here)
tools/probe_firestorm_cloudshadow.py  task #54 — cloud-shadow params by name (ve_dump)
tools/probe_firestorm_casing.py       level-name casing census across all partitions
```

All read the extracted 2026-08-01 pull through
`BF6_Frostbite_Research/impl/pipeline/bf6_paths.py`, read-only.

---

## 0. The map in one paragraph

**MEASURED.** MP_FireStorm is an **8,192 x 8,192 m** world (block 0 root AABB
`x,z ∈ [-4096, 4096]` — 4x the area of Tungsten), ground from **y = 100.533 to
y = 509.867**, `WorldSizeY = 1024.0`, 265 samples per heightfield node, **245
streaming nodes** (5 Packed, 240 External). Terrain palette **34 layers**
(L29–L33 all link to crater layer L28). It carries **505 terrain-decal records**
in 28 texture groups, **zero water entities of any kind**, 33 ShaderBlockDepots,
211 `LayerData` partitions (93 with zero Objects), 30 `EcsRuntimePrefabAsset`
partitions (29 empty stubs, **one populated**: `area_05_roads`, ent=3), and
**~490 authored FX placements** across four FX layers — the burning-oil-fields
FX are this map's identity. 516 partitions total under
`game/glaciermp/levels/mp_firestorm`. (`probe_tung_terrain/structure/ecs.py
mp_firestorm`)

---

## A. Water

**MEASURED — there is NO water entity anywhere in the level.**
`probe_tung_types.py mp_firestorm --find "water|ocean|river"` over all 516
partitions: **0 matches**. Specifically:

- `_layers_content/water.ebx` (418 B) is a `LayerData` with `Objects = []` —
  the water layer exists and is empty.
- `_layers_content/water_shared_schematic.ebx` holds only schematic plumbing
  (`SchematicChannelEntityData`, `MathOpEntityData`, …), no surface.
- No `WaterSurfaceEntityData`, `WaterEntityData`, `WaterAsset`, or
  `OceanComponentData` exists in any firestorm partition, including
  `mp_firestorm.ebx` and `lighting/ve_mp_firestorm_base.ebx`.

**This breaks the assumption in `highpoly_gamesource.gd::_water_partition()`**
("the entity is always somewhere; only its partition varies" —
MAP-TUNGSTEN.md G6). Tungsten proved the entity can be buried; FireStorm proves
it can be **absent**. The water y-vs-floor diagnostic (Tungsten A3) has nothing
to diagnose here; a consumer must tolerate zero water partitions. The desert
map simply has no water, which the terrain confirms: no river layer analogue,
no channel-shaped ground layer (§B).

---

## B. Terrain and ground layers

### B1. Streaming tree

**MEASURED** (`probe_tung_terrain.py mp_firestorm`, all walks byte-exact,
slack 0):

```
container: UnblurredSamplesPerNodeSidePot 256, NodeCount 245, PersistentNodeCount 240
block 0  heights    15,222 B  xs=265, WorldSizeY=1024.0, 245 nodes (5 Packed, 240 External)
block 1  splat     636,402 B  LayerSlotCount=6, 213 nodes, 19,225 records
block 4  mask        1,037 B
block 7  material 3,129,686 B dim=256, header nodeCount=317, walk visits 238, levelMax=6, 12 pairs
block 8  mask      398,069 B  dim=265, 81 nodes, levelMax=5, maskUnknown0=4
```

No blocks 2/5 (Tungsten ships both). `LayerSlotCount = 6` — same as Tungsten
(4,356-page map) against 62 on dumbo/aftermath/eastwood (2,592-page maps).
HYPOTHESIS: LayerSlotCount correlates with the page-size class; still not the
layer count. Block 7's node walk ends exactly at the 56-byte footer
(4 + 12x4 + 4), badrows 0 (`probe_tung_basefield.py`).

### B2. Layer table — 34 layers, and the painted/base texture split is NOT absolute here

**MEASURED.** `layergraphslayergraphs` (1,272 B) record table at offset 96 by
the all-keys-resolve rule (34/34 resolve in the 10,984 B depot; 31
content-deduplicated records). `VisualTerrain` (646 B): layerCount 34,
`SurfaceShaderBlockKey 0x43DB1AAE19A710A9`, links L29→L28 … L33→L28 (five
linked layers; Tungsten had four).

Textured layers (`probe_tung_layers.py mp_firestorm`):

| L | side | textures |
|---|---|---|
| **04** | **painted x702** | `t_wum_chap_distance_02_1_{cv,nhs,ao,ssm}` — full set incl. a `_ssm` slot `0x07A9B250` |
| 08 | painted x65 | `t_com_asphaltdetail_02_ncs` (detail only) |
| **10** | BASE x852 | `t_seu_tileconcretebig_01_{cv,nhs,ao}` + `t_ter_defaulttexture_ao` + `t_gen_breakupmask_02_rgba` |
| 11 | painted x79 | `t_com_asphaltdetail_02_ncs` (detail only) |
| 12, 13, 26 | BASE x852 | `t_cas_asphaltedge_01_{cv,nhs,ao,op}` (three depot records, same texture set) |
| 15 | BASE x852 | `t_ter_defaulttexture_ao` only — the Tungsten-L10 analogue |
| 28 | BASE x852 | `hfd_debug` at slot **`0xAE16A5C0`** — crater layer, **verifies the law** |
| 29–33 | BASE x852 | wum gravel / cracked concrete / dryrockygravel / concretedebris sets (L29–L33 link to L28) |

The other 20 layers bind nothing (shader-computed), and L05/L16/L22/L23 print
zero parameters.

**CONTRADICTION of the absolute form of the Tungsten law.** Tungsten: "all
painted layers are textureless; all textured layers are base — absolute."
FireStorm: **L04 is a painted layer (702 weight-page records) binding a full
cv/nhs/ao/ssm texture set**, and painted L08/L11 bind a detail texture. The
"materials live on the base side" rule is a strong tendency (10 of 13
texture-binding layers are base), **not an invariant** — `bf6_materialtree.gd`
must not assume painted ⇒ textureless.

**MEASURED — a layer-graph key is shared across maps.** FireStorm L15's
`ShaderBlockKey = 0x958F2824AC0D7783` is byte-identical to **Tungsten L10's**
(the default-AO-only record; Tungsten's river layer). The key is
content-derived, not level-unique — anything treating it as a per-map ID will
collide across maps.

Unidentified constants, FireStorm's evidence: `0x4C200FE0` here is 0 .. +0.02
only (Tungsten saw negatives); `0xCBB9A946` = (0,0) on all 34 layers (again);
`0xCF3F97E0` values 0/2/4 (again, integer); `0x2F9990B7` 0.1 .. 234.188;
`0xF7652FB3` 1.0 .. 45.0. New this map: `0x07A9B250` is a **texture slot**
(`_ssm` suffix), seen only on L04.

### B3. Block 7 — the material raster

**MEASURED** (`probe_tung_basefield.py mp_firestorm`): pairCount 12 (9 used),
`BackgroundMaterialIndex = 0x00000080` — the value Tungsten's study called the
"no background" sentinel on dumbo/eastwood. Mechanically it also decodes as
list 0 index 0 → L00; which reading is correct is **unknown** (L00 is a
plausible desert base, but the sentinel reading is equally consistent).

Texel share of the resolved base field:

```
L10  48.1%   t_seu_tileconcretebig_01 (+breakupmask)   <- has a real albedo
L03  25.0%   textureless
L09  18.0%   textureless
L02   5.1%   textureless
L00   3.4%   textureless
L11   0.2%   detail ncs only     L07 0.1%, L01 0.0%
```

**48.1% of the base field resolves to a layer with an albedo** — far better
than Tungsten's 20.6% ceiling — and the painted side adds L04's
`chap_distance` texture over 702 node-records via weight pages. FireStorm is a
map where fixing the splat/colour decode pays visibly.

### B4. The decomposition table (detect_layout verification row)

**MEASURED** (`probe_firestorm_decomp.py`; page size 4,356 confirms the
derived table's firestorm row; **zero ambiguous, zero unsolvable** over all
257 chunks):

| kind | depth | height prefix | trailer | count |
|---|---|---|---|---|
| primary | 2–5 | 149,297 | **67,600 = one 260² BC7 tile** | 240 |
| primary | 0–1 | 0 (heights Packed in-tree) | 0 | 5 |
| paired | 2 | 0 | 0 | 12 |

`size = 149297 + N x 4356 + 67600` exactly, N = 0..176.

- **The colour tile is a single 260x260 BC7 tile (256 + 2px apron per edge) at
  the very END of the chunk.** BC7 mode test: all 240 tiles pass at exactly
  **100.0%** modes 4-7 (m6 ≈ 99%); all 17 tile-less chunks fail at ≤ 8.5%.
  There is no second/degenerate tile on this map (mean tile alpha 0.001, so no
  baked AO in alpha either).
- **17,424-byte aliasing trap:** 17,424 = 4 x 4,356, so size arithmetic alone
  "finds" k x 132² tiles in what are really weight pages (and mip-pair 85,024
  = 67,600 + 4 pages). Only the mode test disambiguates. Conversely, the mode
  test alone can NOT catch a wrong tile SIZE here: the last 4,624 bytes of the
  real 67,600-byte tile are themselves valid BC7 colour blocks, so the
  plugin's current `(2592, 4624)` pick decodes plausible colours at the wrong
  scale. **The detect_layout fix needs both: exact decomposition for the page
  size, mode test for the tile position.**
- **CONTRADICTION (scope refinement) of Tungsten C1's paired-chunk law:**
  FireStorm's 12 paired chunks are **pure weight pages** (exact N x 4356, no
  BC7 tile at any offset — windowed mode scan in `probe_firestorm_decomp.py`'s
  development, scratch-verified at every k x 67,600 and k x 17,424 window).
  "Paired chunks carry the four child colour tiles" is a per-map layout, not
  universal. Here every depth-3+ child carries its own tile in its own primary
  chunk.
- Height prefix is always a single 149,297 (no doubled prefixes as on
  Tungsten).

### B5. The colour map, rendered

`probe_firestorm_colorrender.py` decodes all 240 tiles (BC7 via
`bf6_colormap.py`'s DDS/Pillow wrapper) into
`%APPDATA%/Godot/app_userdata/Battlefield™ Portal Project/_cmapprobe/FIXED_MP_FireStorm.png`.

**It reads as a coherent aerial photo**: eroded desert drainage over the whole
square, the town + highway band across the middle, two airstrips, and a huge
BLACK burn scar over the south-east quadrant whose extent coincides with the
oil-field fire FX placements (§D2: firelines at x -218..2040, z 174..1383) —
an internal cross-check, since **no SDK overhead image ships for this map**
(`addons/bf_portal/terrain_decal/textures/` has only Aftermath, Capstone,
Tungsten). Whole-image mean RGB (0.529, 0.516, 0.490), 0.5-centred as the
modulate law expects.

---

## C. Decals and roads — the parser needed two fixes

**MEASURED.** `decals.TerrainDecals` is 9,266,184 B: slotCount 34 (= layer
count), 7 slots with a GUID, recordCount 505. **`probe_tung_decals.py` parses
0 of 505 records on this map.** Two format deviations from TERRAIN.md §10.2
(both fixed in `probe_firestorm_decals.py`, which parses **505/505 with zero
chain breaks**):

1. **Record 0 does not start with `[u32 propSize]`.** Its head is
   `[u64 0xAEF8B6DE64DD8673][u32 0xEEFD3D7A][24 zero bytes]`; read as a
   propSize that is ~1.7 GB and the documented walk aborts instantly. Record 0
   is also degenerate content-wise: `AssetSlot = 0xFFFF` (out of the 34-slot
   table), TriCount 2, a 1 x 1 m AABB at (313, 139, -178).
2. **Records are not 4-byte aligned.** propSize can be odd (record 208:
   0x149), which puts every later tail on an odd byte offset. The tungsten
   anchor scan steps 4 bytes and can never land on it. **Byte-stepped
   scanning finds every anchor** — the 1.0/1.0/u64-0 anchor itself is present
   on all 505 records. This correction belongs in TERRAIN.md §10.2.

Slot usage (chain-validated, `FirstIndex == prev + prevTri*3` holds 505/505):

| slot | recs | tris | world span |
|---|---|---|---|
| 12 | 156 | 42,514 | x ±4090, z -1223..866 — the full-width highway band |
| 13 | 138 | 11,118 | x ±4090, z -501..465 |
| 26 | 124 | 11,316 | town box |
| 15 | 47 | 17,126 | town box |
| 9 | 37 | 1,334 | x ±4090 |
| 10 | 2 | 188 | town |
| 65535 | 1 | 2 | the degenerate record 0 |

28 texture groups; the big ones: `t_cas_roaddirt_02` x108,
`t_cas_erosiongravel_01` x49, `t_cas_asphaltedge_03` x48, prop-less x41,
`t_cas_ridgemudrock_05` x39, `t_cas_roadlines_01` x35, plus an **airbase set**
(`afb_airstrip_*` mults, `t_airstrip_white_solid/dashed`, runway text
`t_fs_0..3_a02`) and mixed-library groups (asia/centralasia + westusmountain +
southerneurope in one map — group by whole texture set, per the Tungsten
warning). Unlike Tungsten, decals span the **full x extent** of the world
(the highway crosses the map); z is bounded to -1223..866.

---

## D. Everything else notable

### D1. Level-name casing (the capital-S question)

**MEASURED** (`probe_firestorm_casing.py`): four casings coexist in the
shipped bytes of the 516 partitions:

```
MP_FireStorm  x433   (level partitions: "Game/GlacierMP/Levels/MP_FireStorm/...")
mp_firestorm  x175   (res/bundle path strings; also the on-disk directory name)
MP_Firestorm  x7     (lighting + common/fx library: "Common/FX/Levels/MP/MP_Firestorm/...")
MP_fIRESTORM  x1     (lighting/pm_mp_firestorm_distanthaze.ebx)
```

Any case-sensitive contains() splits the level into four families. The plugin
is safe today: `highpoly_gamesource.gd:804` lowers the incoming map name once
(`level = map.to_lower()`), and every matcher (`bf6_terrainlayers.gd:100-114`,
`bf6_decals.gd:70-77`, `bf6_scatter.gd:48-55`, `bf6_source.gd:104/145`,
gamesource:1525) lowers the resource-name side before contains(). VERIFIED by
reading each call site; keep that invariant — the data guarantees nothing.

### D2. FX — fire/smoke density and the big distant cards

**MEASURED** (`probe_firestorm_fx.py`; blueprint GUIDs resolved through the
full-dump guid index). Four FX layers, ~490 placements:

- **`fx_oilfields` (80 refs) — the burning oil fields**, all inside the black
  burn scar of the colour map: `pffx_fireline_firestorm_oilfields` **x37**
  (x -218..2040, z 174..1383), `fx_oilfields_smokepillar_firedecal` x10, dark
  fire pillars s/l/huge x~12, blur pillars x6, `pffx_oilfields_pressurefire_5pt`,
  plus 5 crater prefabs.
- **The big distant FX cards are MESHES, not emitters.**
  `ob_fx_bd_vertical_smokeplume_03_firestorm` at (3612, **957**, 890) is an
  `ObjectBlueprint` → `StaticModelEntityData` → Mesh
  (import `00a12f3d-0ce7-b1a5-420f-5a44f1df36c3`), unit-square part bounds
  scaled by the instance transform, all shadow flags off. Its companions:
  `fx_oilfields_firestorm_smokecard_blend` (3957, **1320**, 947),
  `fx_oilfields_firestorm_topblend` (2459, **1669**, 2491),
  `fx_oilfields_smoke_background` (978, 441, 3574),
  `fx_oilfields_smokepillar_background_huge` (3470, 170, -267),
  `fx_oilfields_smoke_distantonly` (1734, 163, 1012). These are the giant
  plume columns visible map-wide; a placement walk that skips FX layers never
  sees them, and they are exactly the kind of win the high-poly preview wants.
- **`fx_global` (306 refs) — ambience**: sanddust/debris x89 + swirly dust,
  dust motes; `fx_mp_firestorm_flies_garbage_01` x42;
  `fx_firestorm_fire_vehicle_m` x22, `fx_firestorm_scatteredsmallflames` x17,
  `fx_firestorm_crater_smolder` x15, `fx_mp_firestorm_area_embers_xxl` x12,
  smokepillars, refinery firepillar, `dwpf_globalwind_mp_firestorm`.
- **`fx_backdrop` (101 refs) — ambient war**: AA launch sites x15, airstrikes
  x24, jet formation runs x11 (y 342..665, out to x -4006), missiles, tracer
  firefights x4 (y up to 689), the huge-silo explosion/smokepillar cluster at
  (-183, -901), backdrop fog `fx_bd_fog_air_firestorm` x12.
- **Placement-walk hazards:** `fx_cap_cloud_spawn_point_cluster_m` (a Capstone
  asset) sits at **y = 500,000** — any bounds/centroid computation that
  ingests FX transforms must clamp or exclude it. `fx_sketch` holds one
  `fx_sorting_temp_bigbbx` (a sorting hack with a huge bbox).
- **Plugin coverage: `fx_effect_sheets.json` knows exactly ONE of these
  (~60 distinct) blueprints** (`fx_firestorm_fire_vehicle_m`). The map's
  visual identity is currently ~0% renderable by the FX system.

### D3. Cloud-shadow mask parameters (task #54)

**MEASURED** (`probe_firestorm_cloudshadow.py`; exe layout via ve_dump, field
hashes re-keyed through the research name tables). They live on the
`OutdoorLightComponentData` (instance 3) of
`lighting/ve_mp_firestorm_base.ebx`:

```
CloudShadowEnable                <in PropertyOverrides names; bool block>
CloudShadowTexture            -> lighting/t_mp_firestorm_terrainshadows_04
CloudShadowSize                  4096.0        CloudShadowCoverage   0.561
CloudShadowExponent              4.0           CloudShadowSpeed      (0.0, 0.0)
CloudShadowIsTopDown             true          CloudShadowAddressingMode 4
CloudShadowHeightFadeEnable      false         CloudShadowStartFade  -1.0
CloudShadowStartHeightFade       0.0           CloudShadowsFadeDistance 0.0
SecondaryCloudShadowTexture   -> lighting/t_mp_firestorm_terrainshadows_second_49
SecondaryCloudShadowSize         8192.0        SecondaryCloudShadowCoverage 0.679
SecondaryCloudShadowExponent     5.443748      SecondaryCloudShadowIsTopDown true
SecondaryCloudShadowAddressingMode 4           SecondaryCloudShadowSpeed (0.0, 0.0)
CloudRadiosityEnable             true          CastTerrainShadowsEnable true
```

**Both speeds are zero and both textures are named `terrainshadows`** —
FireStorm repurposes the cloud-shadow projector as a **static, top-down baked
shadow mask** (the smoke-pall darkening over the burn scar), secondary sized
exactly to the 8,192 m world. Sun on the same component: SunRotationX
302.549988, SunRotationY 35.0 (elevation), SunIntensity 100,000 — matching
`highpoly_lighting.gd`'s "MP_FireStorm" row (az 302.55, el 35.00, lux 100000)
exactly, which validates both readings. Also in `lighting/`: participating
media `pm_mp_firestorm_distanthaze` and
`pm_firestorm_norbs_global_stormy_smoke_01`, and an 8k panoramic sky texture —
the rest of the "burning sky" look.

### D4. Backdrop / skyline

**MEASURED.** `_layers_world/backdrop.ebx` holds 8 objects: 2x
`ObjectReferenceObjectData` → `bd_ind_silooilhuge_01` (the huge industrial oil
silo backdrop mesh, near the fx_backdrop silo-fire cluster) and 6x scaled
`SpatialPrefabReferenceObjectData` → `pf_crater_ap_firestorm` (asset-gym
crater prefab; also placed 5x in fx_oilfields and 4x in fx_global). The
`generated/backdropterrainnear_output.ebx` and `backdropterrainfar_output_*`
layers declare **zero Objects** — there is no backdrop terrain ring mesh; the
skyline is sky texture + distant haze + the smoke-card meshes of §D2.

### D5. Structure oddities

**MEASURED.**

- Terrain dir is `mp_firestorm_terrain` (dumbo-style `<level>_terrain`, not
  Tungsten's `terrain_<level>`); the naming inconsistency law holds. Inside
  it, the decals RES sits under a **mirrored path tree**:
  `mp_firestorm_terrain_game/glaciermp/levels/mp_firestorm/mp_firestorm/decals.TerrainDecals`.
  Anything globbing `<terrain>/*.TerrainDecals` non-recursively finds nothing.
- Subworlds are `area_01..area_08`, with the geometry split as
  `area_0N.ebx` (LayerData, 103–473 objects) + `area_0N_sublvl.ebx` +
  `area_0N_sublvl/staticmodelgroup.physics.PhysicsResource` (1.4–6.0 MB).
  **`area_03/05/07_predestruction.ebx` carry 104/188/53 objects** — a walk
  that ingests both an area and its predestruction twin double-places props.
- Nine gamemode depots are byte-identical
  (`shaderblockdepot_9526102139013923511` under breakthrough / conquest /
  domination / escalation / koth / rush / sqdm / strikepoint / tdm) — same
  dedup phenomenon as Tungsten.
- Biggest files are lighting: `enlighten_mp_firestorm_highend` 110.3 MB,
  lowend 38.9 MB, `materialgrid_win32.ebx` 14.4 MB. Unread by the plugin.
- ECS: 29 empty stubs + **one populated prefab**
  (`area_05_roads_ecsprefab`, ent=3 arch=3 seg=6 edits=2 comps=[0,42,54,58]) —
  confirms populated prefabs are readable and stubs are boilerplate.
- Scatter (open task): the level ships a 10,308 B `MeshScatteringDatabase`,
  but **all 35 `SingleTerrainLayerData` instances declare
  `MeshScatteringTypes = []`** — the Identifier→catalogue join CANNOT be
  validated on this map, and terrain clutter is authored absent (burned
  desert). Note also: 35 layer instances vs `layerCount = 34` in
  VisualTerrain — one spare slot, unexplained.
- Height quantisation: `WorldSizeY 1024.0` over u16 → 1.56 cm/step, Tungsten
  class.

---

## E. Generalisation — what FireStorm confirms and what it breaks

| finding | scope | notes |
|---|---|---|
| Page size **4,356** confirmed by exact decomposition of all 257 chunks, zero residual | verification row | Matches the derived table and `bf6_splat.py`; the plugin's `(2592, 4624)` pick is wrong on this map on both axes. |
| Colour tile = ONE 260² BC7 tile at the chunk END, depth≥2 primaries only; 100.0% modes 4-7 | firestorm (battery/limestone/plaza screened same by bf6_colormap.py) | Tungsten's "colour tile is FIRST of two" is per-map; dumbo's "single tile last" shape recurs here at a bigger size. `color_tiles()` must size the tile per map, then take the mode-passing tile. |
| **Paired chunks carry NO colour tiles** — pure child weight pages | CONTRADICTS Tungsten C1's paired-tile law as a universal | Tile-in-paired is a per-map layout property. |
| **A painted layer CAN bind a full texture set** (L04, 702 painted records, cv/nhs/ao/ssm) | CONTRADICTS the absolute painted⇒textureless reading | Keep base-side handling, but never skip texture resolution for painted layers. |
| Water entity can be **absent entirely** (0 water types in 516 partitions) | extends Tungsten A3 | `water()` needs a "no partition found" path, not just a buried-height diagnostic. |
| `0xAE16A5C0` = crater slot, one layer per map (L28 here), linked layers L29–L33 | verifies | Five links, not four — link count varies. |
| Layer-graph ShaderBlockKey `0x958F2824AC0D7783` identical on firestorm L15 and tungsten L10 | new | Keys are content hashes; never use as per-map identity. |
| Decal records: not 4-byte aligned + a degenerate slot-0xFFFF record 0 with a hash head | new, at least firestorm | TERRAIN.md §10.2's anchor scan must byte-step; expect propSize-less sentinel records. |
| Decal parse rescue: chain invariant + byte-stepped anchor parses 505/505 | tool | `probe_firestorm_decals.py`. |
| `0x00000080` background: "no background sentinel" vs "list0→L00" both fit | open | Firestorm cannot discriminate; needs a map where L00 is visually distinctive. |
| Empty-ECS-stub law + populated-prefab readability | verifies | 29 stubs, 1 populated. |
| LayerSlotCount 6 on both 4,356-page maps studied vs 62 on 2,592-page maps | HYPOTHESIS | Correlates with page-size class; meaning still unknown. |
| Casing: four variants of the level name coexist in the data | every map (assume) | Lowercase both sides of every match, always. |

## F. What this explains about plugin failures on this map

- Ground: `detect_layout` picks page 2,592 → weight pages are decoded with the
  BC4 codec over raw 66² pages AND sliced at wrong offsets; colour comes from
  the last 4,624 bytes of the real tile — valid BC7 at the wrong scale, i.e.
  plausible-but-wrong colours rather than Tungsten's cyan.
- The map's signature look (fires, smoke pillars, plume cards, smoke-pall
  shadow) lives in FX layers, static card meshes, and the cloud-shadow
  projector — all currently outside what the plugin renders; the terrain fix
  alone will still look "peacetime".

---

## G. Next actions, in priority order

1. **`addons/highpoly_toggle/bf6_splat.gd::detect_layout`** — same fix as
   MAP-TUNGSTEN.md G1 (exact decomposition, prefix set, unique winner), plus:
   accept 67,600 as a tile size, and validate the tile by the BC7 mode test at
   the chunk END — on this map the decomposition is unique with zero ambiguity
   (verification row in §B4), and the mode test alone is insufficient (last
   4,624 bytes of a real tile also pass).
2. **`bf6_splat.gd::color_tiles`/`node_pages`** — per-map tile size
   (4,624/17,424/67,600, mips 85,024 per `bf6_colormap.py`), tile at END for
   this map, none in paired chunks, none for depth 0/1. Verification: the
   assembled colour map must match FIXED_MP_FireStorm.png (mean ≈ 0.53/0.52/0.49,
   burn scar in the SE quadrant).
3. **`bf6_materialtree.gd` / `bf6_terrainlayers.gd`** — resolve textures for
   painted layers too (L04), and add slot `0x07A9B250` (`_ssm`) alongside the
   `0xAE16A5C0` crater slot.
4. **`highpoly_gamesource.gd::water()`** — handle "no water partition exists"
   explicitly (log "level ships no water entity — nothing to draw"); FireStorm
   is the existence proof.
5. **FX**: add the oil-field/backdrop blueprints to `fx_effect_sheets.json`
   (only `fx_firestorm_fire_vehicle_m` is known today), and treat the
   `ob_fx_bd_*` / `*_smokecard_*` blueprints as static meshes in the placement
   walk (`highpoly_gamesource.gd` / `bf6_walk.gd`) — they are ordinary
   StaticModelEntityData and are the cheapest huge visual win on this map.
   Clamp/exclude the y=500,000 `fx_cap_cloud_spawn_point_cluster_m` outlier in
   any bounds computation.
6. **Lighting** (`highpoly_lighting.gd` / `highpoly_mapcontext.gd`): implement
   the static cloud-shadow mask — a top-down projected darkening texture,
   parameters in §D3 (primary 4,096 m / coverage 0.561 / exponent 4.0;
   secondary 8,192 m / 0.679 / 5.44; speed zero so it is a one-time bake, and
   the textures ship in `lighting/`). This is the smoke-pall look.
7. **Placement walk**: exclude `*_predestruction` layers when the base area
   layer is walked (§D5), or gate on one of the two.
8. **Upstream to `BF6_Frostbite_Research`**: TERRAIN.md §10.2 byte-stepped
   anchor + sentinel record 0 + odd propSize; §5.2/5.3 "trailer can be one
   260² tile at the end; paired chunks may carry no tiles"; and the
   cross-map-shared ShaderBlockKey observation.
