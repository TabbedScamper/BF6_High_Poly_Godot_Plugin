# Feature modules — 27 files, commit `16fed50`

Real line counts (brief was stale): markers 417, fx 877, lighting 1390, bctex 498, decalproject 641, collision 249, gamemode 495, gmmine 513, hlod 617, placedcull 324, previews 602, rsprops 216, scatter 808, water 306, and the rest as labeled below.

**Two load styles:** most declare `class_name`. Four deliberately do NOT (collision, decalproject, rsprops, variants) — the staged lane re-enables the plugin without a filesystem rescan, so a freshly registered global class may not resolve; those are preloaded / `load(PATH).new()`ed.

## highpoly_bctex.gd (498)
`class_name HighpolyBcTex`, static. The `.bctex` sidecar format + process-wide two-tier texture pool + material binding. `release_images` :110 (CPU pool only), `release_all` :116, `img_bytes` :131 (exact BC bytes), `pool_stats` :159, `path_for/exists` :201/:205, `decode(path, compress)` :219 (worker-safe), `bind` :356 / `bind_meshes` :382. `MAGIC 0x58544342`, `EXT ".bctex"`, `SLOT_MAP` :41.

## highpoly_collision.gd (249)
No class_name; preloaded (toggle:65). Red overlay approximating collision (proxy meshes re-drawn under `_COLLISION_VIS`, world scale uniform-to-X). `red_material/set_color` :43/:52, `ensure_one/remove_one` :96/:120, `apply(root,on)` :130, `refresh_transforms` :157 (heartbeat), `reisolate/release_isolation` :211/:235. `EPS 1.002`. `_proxy_meshes` :67 duplicates placedcull `_collect_proxy` :301.

## highpoly_decalproject.gd (641) — the road-decal projector
No class_name; `load(...).new()` at mapcontext:6927. Re-projects road decal vertices from the terrain drape onto receiver prop surfaces (XZ grid + barycentric containment). `run(tree, roads_mi, props_root)` :146 (preserves original drape in `hp_drape_mesh` meta :158); `progress_fn` :114 (`(phase, done, total)`); `stats` :110.
Constants: `CELL 2.0`, `COARSE 16.0`, `WINDOW 2.5` (rooftop guard), `BAND_MARGIN 0.6`, `PROP_Y_BIAS 0.004`, `MIN_NORMAL_Y 0.5`, `PREFILTER_NORMAL_Y 0.3`, `MAX_CELLS_PER_TRI 4096`, `MS_PER_FRAME 12`, `MAX_INDEX_MS 60000`.
**`_is_receiver(mat) -> String` :471-488, three shapes** (returns the reason): "named M_TerrainBlend" :474; ShaderMaterial whose code contains `bf6_ground_col` :476; BaseMaterial3D with `albedo_texture == null` :482. Missing any one silently drops receivers depending on build stage.
**Stats keys:** lifted :253, vertices :270, tris :580, instances :389, skipped_instances :374/:387, skipped_groups :345, surfaces :275, ms, no_band :206, straddling :259, index_truncated :323, surfaces_seen :503, receiver_surfaces :508, mesh_tris_kept :535, receiver_meshes :546 ({name: [tris, why]}), r_no_cell :600, r_not_inside :636, r_band :638, r_window :640. Consumed exclusively by mapcontext `_reproject_roads` 6895-7027 (audit + six Log lines).

## highpoly_doors.gd (107)
No preload-blocker; preloaded (toggle:66; variants:20 reuses `_ray_hits_local_aabb` :27). Double-click door proxies to swing (`interactabledoorcontrol` angle). `click` :52, `toggle` :77. `click` is the same 25-line loop as variants `click` :109 — **strongest merge pair**.

## highpoly_fx.gd (877)
`class_name HighpolyFx`, static. Live GPU emitters/decals/debris at real FX spawn points from `fx.json`, parameterised by six shipped JSON tables + flipbook atlases from the install. `clear(root)` :104 (**the canonical orphan-proof name-`contains` sweep — cited by 3 other files**), `apply(root, map, on, progress, gs)` :122, `set_range` :867. `NODE "_MAP_FX"`, `MAX_EMITTERS 3000`, `FOLD_EPOCH 2` (in cache filenames — bump on fold/mip change).
Known-unresolved (in comments): half-vs-full extent :796; per-effect sheets are a majority vote per graph :285; `EMITTER_BBOX` deliberately not wired :760; sheet-less non-billboard families not drawn.

## highpoly_gamemode.gd (495)
`class_name HighpolyGamemode`. Rebuilds a gamemode as REAL owned Portal objects (7 scene kinds :48); labels owner=null, gameplay objects owner=root (:12-23). `data_path/modes/usable/pretty` :83-:112, `key_for` :123, `built` :148, `in_gamemode` :165, `clear` :176, `apply(root, map, mode, _unused)` :187. `SCHEMA 2` must match gmmine.

## highpoly_gmmine.gd (513)
`class_name HighpolyGmMine`. Mines `_layers_gameplay/<mode>` subworlds → `gamemode_markers.json`. `roots_of` :124 (main thread, snapshots ebx), `mine` :150 (**builds its OWN BF6Walk :175-181 — mining on the shared walker poured placements into the map from a worker**), `mine_to_disk` :467. `CAPTURE_MAX_AREA 1500.0` heuristic :108.

## highpoly_hlod.gd (617) — OFF
`class_name HighpolyHlod`. Bakes a cell's MultiMeshes into one welded ArrayMesh (vertex colours as albedo). Switches: **`HLOD_CELLS := 0` mapcontext:6749 (master off)**, `HLOD_ON_DEMAND := false` :6767, `hlod_near_m 0.0` :6791. Only exercised by flightrun:723. `bake_cell_native` :87 (BF6Oodle merge), `bake_cell` :193 (weld-while-merge, Vector4i keys), `bake_and_install` :414 (cache `hlod_v2_…` :460), `probe` :562.
**Live bug: `bake_and_install` :494-513 hides every node then immediately re-shows them (:511-513), so `replaced`/`draws_saved` report a change that did not persist.**

## highpoly_lighting.gd (1390) — mini-atlas
`class_name HighpolyLighting` (+ preloaded as LightingScript).
| lines | region |
|---|---|
| 1-118 | header + 23-map fallback TABLE; `NODE "_GAME_LIGHTING"` :48 |
| 119-208 | mined VE cache (`mined()` :152 mtime-keyed; `_col/_col_hdr` :192/:201) |
| 209-299 | sun maths (`sun_dir` :254, `sun_energy` :263); `cast_shadows` :270, `shadow_radius 80.0` :285, `interior_fill 0.22` :295 |
| 300-530 | `apply(root, map, gi, shadows)` — sun/sky/Environment; **SDFGI forced off :483**; SSAO = gi |
| 531-753 | white balance + `_apply_mined` :576 (fog :644, grading :675, WB LUT :713) |
| 754-853 | live sub-toggles (`set_gi` :755, `set_shadows` :788, `clear` :845) |
| 854-952 | exposure zones (`tick_zones` :923, EV log2 :914) |
| 953-1035 | map lights core (`LIGHT_SLICE_MS 120` :978, `lights_range 150.0` :979, **`make_light(L)` :997 — the single Light3D constructor**) |
| 1036-1222 | prop fixtures (`PROP_LIGHT_CAP 8` :1053, `refresh_prop_lights` :1154) |
| 1223-1322 | `set_map_lights` — built off-tree, attached once :1255/:1314 (was 23.4s) |
| 1324-1390 | distance culling (`tick_lights` :1344) |
Dead: `shadow_min_size` :289 never read (real rule uses `HighpolyMapContext.SHADOW_MIN_EXTENT` at :838 — a cross-script read).

## highpoly_markers.gd (417) — fault markers
`class_name HighpolyMarkers`. **The point is the log section, not the sphere.**
Data flow: dock "Drop marker"/note-Enter → `camera_point(dist=12.0)` :57 (12 m ahead; no depth to snap to — mapctx props carry no collision) → `add(root, note, pos)` :66 → SphereMesh r0.5 unshaded no-depth :29-37, under `_HP_MARKERS` group, **owner = root (saves into the .tscn, deliberate :23-24)**, meta `hp_note` :100; the dock also writes `hp_note_target` (read :143/:332, never written here). `list(root)` :127. `import_from` :161. `report(root, map)` :301: expected via `_expected_live(gs, pt)` :197 (walks gs.walk.rows + variant layer via `layer_of_scope` :216) or `_expected` :224 (placements.json); built via `_live(root, pt)` :251 (**tests MultiMesh instance transforms, not get_aabb() :268-271**, + effective-visibility chain :285); seven-outcome verdict :346-390; nearby table :391-415. `RADIUS 14.0` :26 (read by dock:2230).

## highpoly_modes.gd (76)
`class_name HighpolyModes`. The Detail Mode ladder as four pure functions (testable — the dock can't be constructed outside the editor). `SDK 0, LIGHT 3, GREY 1, TEX 2` — **persisted per map; never renumber**. Cleanest file in the set.

## highpoly_occluders.gd (128) — OFF
`class_name HighpolyOccluders`. Places the 867 authored occluders; only caller autorun:561 gated `cfg["occluders"]` default false. **Measured 1.7x WORSE** (12.1→~22 ms median; Godot rasterises the occlusion buffer on CPU and post-merge there is too little left to cull) :26-38. Bug: `apply` sets the project setting :71 and `clear` never restores it.

## highpoly_placedcull.gd (324) — ON but its control is hidden
`class_name HighpolyPlacedCull`. Distance-culls the USER's placed objects via `visibility_range_*` (serialized! remembers and restores). Control = `mapctx_optimize` toggle:1216 pressed=true visible=false. LOD handover requires Tier.LOW :203. `release` :69, `apply(root, r, on)` :115. `SKIP` :24 deliberately excludes `_HIPOLY_PREVIEW` (culled with its object). Exemption ext > 600 m; bands r / 0.6r / 0.35r at 12 m / 3 m; floor 40.

## highpoly_previews.gd (602)
`class_name HighpolyPreviews`, Node, dock service. Object Library thumbnails rendered in an off-screen SubViewport, cached `user://highpoly/thumbs/<Name>__<mode>.png`. `build_all(progress)` :528 — **the model progress consumer: takes a Callable, owns no UI**. Perf history baked in comments (find_children walk was the plugin's biggest instrumented cost → `_lists_cache` :174).

## highpoly_rsprops.gd (216) — OFF
No class_name; `load()` at mapcontext:6250. Direct RenderingServer instances (measured 16% faster) — **OFF because RS instances are invisible to picking, fault markers, census, profiler and cell merge (:41-46); flag `PROPS_RS := false` mapcontext:6241.** Must stay off until the picker consults `groups()`. Bug: `group()` :183 doc promises `{meshes,...}` but the dict holds `items`; `_free_item` leaves freed RIDs in the group array.

## highpoly_scatter.gd (808)
`class_name HighpolyScatter`; preloaded by mapcontext (`_scatter`). Ground scatter from the game's own `MeshScatteringDatabase` accepted by painted splat coverage. `setup` :126, `tick` :294, `set_range` :285. Budget flow: class gate `_kit_class` :654 (veg/debris; neutral drops entirely :224), per-entry cap `max(64, HARD_TOTAL*share)` :429 (`HARD_TOTAL 90000`), radius from the entry's real distance :270, two early exits :432-449, ring-order cells :474, accept = coverage weight then slope then dice :521-545, `_cov_weight` :665, frame spreading `REGEN_MS_PER_FRAME 2.0` :329 (bounds entries, not frame length). `grass_range := 0.0` off by default :45.
Dead: `_regenerate_now` :394-419 loop is unreachable. Two `print()`s :204/:280.

## highpoly_sdkhide.gd (83)
`class_name HighpolySdkHide`. Hides `MP_<map>_Assets`/`_Terrain` stand-ins; memory-only memory (never set_meta — would serialize). `set_hidden` :51, `restore_all` :73. `_saved` keyed by instance id :28.

## highpoly_section.gd (204) / highpoly_tips.gd (145) / highpoly_splash.gd (124) / highpoly_theme.gd (258)
Panel chrome unit. Section: collapsible dock section, `setup` :55, `set_open` :165, signal `opened_changed`. Tips: adopted tooltips (`adopt` :59, meta `hp_tip` — also written by section:172, an undeclared contract). Splash: boot sequence (dead `Pal` preload :27). Theme: palette from `theme.json`, `chip()` :111, `bar()` :104, `build_ui_theme()` :170.

## highpoly_soldier.gd (162→181) / highpoly_vehicle.gd (202) / highpoly_weapon.gd (117)
The hardware assemblers, called from `highpoly_lib._asset_id` (`soldier://`, `vehicle://`, `weapon://`).
- Soldier: NATO=Alliance faction is a PATCH over a shared body (`PATCH` :22, `WEARER` :28, `SPAWNERS` :37). **Bug: `_dress` :128 splits surface names on "@" and does `int(bits[1])` — the exact bug vehicle/weapon document as fixed via `gs._mkey`/`gs._mpal`. Soldier was never updated.**
- Vehicle: `OVERRIDES` :41 / `UNRESOLVED` :55 (kept proxies with reasons); wheels/turrets need the base-skeleton bind pose (reader doesn't exist yet) :30-36.
- Weapon: M4A1 only; `DISPLAY_OFFSET` identity, honest-provisional.
- `_scopes_for` and `_dress` are byte-equivalent in vehicle:163/:174 and weapon:84/:95 — merge into one `highpoly_hardware.gd` (also fixes soldier).

## highpoly_variants.gd (183)
No class_name; preloaded (toggle:69), dispatched after doors (toggle:5355/5357). `order` :78, `click` :109 (same walk as doors), `cycle` :148 (may return `{"fetch": key}`). `print()` :182 bypasses Log.

## highpoly_water.gd (306)
`class_name HighpolyWater`. Water ShaderMaterial: `KIND_PRESETS` :18, 8-wave field from `WaterOceanSimulationEntityData` (`WAVE_LENGTH_RATIO` powers of 1/φ :110). Ours-vs-theirs ledger :92-95. Unresolved: which foam float3 is shallow :258-264.

## Cross-file observations
1. **Node-group clear reimplemented 8×** — fx `clear` :104 is the canonical orphan-proof name-`contains` sweep; markers/occluders/collision still use the `get_node_or_null` form the comment says is wrong.
2. **"Clear then rebuild" prologue ×6** with three different "no scene" strings.
3. **Progress callbacks: four incompatible shapes** (fx/lighting/previews `(done,total)`; decalproject `(phase,done,total)`; scatter none; hlod returns totals).
4. Per-file logging improvisation; the decal projector is the only feature separating measurement (stats dict) from reporting (caller journals) — **the pattern the rest should copy**.
5. Five private "what colour is this material" implementations (bctex/hlod/scatter/decalproject/fx) — at least three would disagree about the same material.
6. Nine stack-walks with four spellings of "skip our own overlays".
7. Merge pairs: doors+variants; weapon+vehicle(+soldier) → hardware; theme+section+tips+splash = chrome.
8. **The off-switch registry:** `HLOD_CELLS 0` (mapcontext:6749), `HLOD_ON_DEMAND false` (:6767), `PROPS_RS false` (:6241), occluders (autorun cfg, default false), `SUBPIXEL_ON false` (mapcontext:6451), placed-cull always-on-hidden (toggle:1216), `grass_range 0.0` (scatter:45). Every switch carries its measurement in an adjacent comment — preserve that.
