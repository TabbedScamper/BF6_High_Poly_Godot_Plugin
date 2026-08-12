# Region map — `highpoly_mapcontext.gd` (actual length 7544 lines; anchors for commit `16fed50`)

`@tool`, `extends Node`, `class_name HighpolyMapContext` (L1-L3).

## Region map

**L1-L206 — Header, identity constants, layer switches, signals, job labels.** Plugin-wide names (`_MAP_CONTEXT` node L20, `user://mapcontext` L21), every user-facing layer flag, terrain vertex budget, signal surface.
- `BcTex` preload L19; `PROPS_CACHE` L26; `_show_roads` L41 (default true); `want_lights` L48, `want_fx` L49, `want_grass` L53; `radius` L58 (768.0); `hlod_cells` L66; `cell_override` L71 (static)
- `SHADOW_MIN_EXTENT` L94 (30.0 — read cross-script by highpoly_lighting.gd:838); `terrain_step` L101; `TERRAIN_VERTS_PER_SIDE` L112 (2048); `SKIRT_DEPTH` L116; `_step_for()` L121
- `BJournal` preload L126; `ScatterScript` preload L127
- signals: `build_progress` L147, `decal_progress` L152, `backdrop_progress` L153, `stage_progress` L157 (**declared, NEVER emitted** — dock connects it at toggle:1729), `build_finished` L158, `terrain_ready` L169; `job_queue` L170
- `BUILD_FRAME_MS` L197 (500), `BUILD_FRAME_MS_MIN` L200 (16), `YIELD_BUDGET_RATIO` L204 (8.0), `BUILD_REPORT_EVERY` L205 (100)

**L207-L277 — Adaptive per-slice work budget + build-generation state.** `_frame_ms()` L227 (reads HighpolyVitals.pressure()); `_yield_cost_ms(lane)` L263; `_build_gen` L269, `_building` L270, `status_label` L277.

**L279-L612 — Phase accounting and yielded-frame instrumentation.** `_ph_reset()` L314; `_ph()` L323 (forwards to BJournal.phase L324); `_ph_forward()` L348 (HighpolyProfiler.span L351, HighpolyProfile.add L352); yield probe machinery L385-L495; `_ph_report()` L497, `_yield_report()` L538, `_log_build_phases()` L604.

**L613-L709 — Refresh bookkeeping and study/SDK materials.** `_clay_mat()` L663, `_flat_mat()` L672, `terrain_material()` L682, `assets_material()` L686, `SDK_GRID_M` L653 (12.0).

**L711-L790 — Maptile placement table and path constants.** `MAPTILE_DECALS` L718 (24 maps); `TILE_CACHE` L764; `Log` preload L765; `SDK_TILE_DIR` L766; `LEGACY_TILE_DIR` L767; `SDK_BOUNDS` L779; `WATER_COLOR` L789.

**L791-L901 — Map identity, salvage decision, teardown.** `map_of()` L792; `_can_keep_props()` L826; `_clear()` L843 (bumps `_build_gen` L845, BcTex.release_all L858, name-pattern sweep L879-882).

**L902-L1047 — Maptile lookup and SDK decal stand-down.** `sdk_decal()` L940; `_maptile_path()` L955; `_set_sdk_decal_shown()` L1008; `restore_sdk_decals()` L1028.

**L1049-L1443 — The terrain shader source and its state.** `EXT_TERRAIN_LAYER` L1066 (1<<19); **`TEXTURED_LAYER := HighpolyLib.TEXTURED_LAYER` L1069 — CONST-FOLD HAZARD** (const initialised from another script's const; used L6199, L6303, L6348). `TERRAIN_SHADER` L1070-L1397 — `splat_texel()` L1136 and `splat_texel_n()` L1208 are verbatim duplicates. `NEAR_RECENTER_M` L1425 (256), `NEAR_MIN_INTERVAL_MS` L1426 (3000), `NEAR_FEATHER_M` L1427 (24), `SPLAT_LIFT` L1440.

**L1444-L1714 — Splat set, colour map, layer textures (disk → GPU).** `_splat_set()` L1444 (~126 lines); `colormap_enabled` L1611 (static true); `colormap_strength` L1617 (static 0.75); `_colormap_set()` L1620; `_flat_tex()` L1685; `_layer_tex()` L1696.

**L1715-L1862 — Terrain material assembly + live-material finder.** `_terrain_shader_mat()` L1723; `set_colormap_strength()` L1814; `_live_terrain_mat()` L1841.

**L1864-L1966 — The game source handle and map-data load.** `game_source` L1874; `_load_data()` L1895 (`game_source.map_data` L1908-1911, `terrain_step` L1917, **writes `game_source.drape_step` L1918**, `_cell_size` L1921/L1964).

**L1968-L2204 — Variant layers, FX cards, water visibility.** `_load_prop_layers()` L1979; `set_variant_layers()` L2049; `set_fx_cards_shown()` L2109; `set_water_shown()` L2120; `log_water_state()` L2148 (warns when chip and node disagree L2165).

**L2205-L2409 — Prop mesh entry point, VRAM mode, sidecar suffixes.** `_prop_mesh()` L2223; `mesh_cache_enabled` L2269 (static false; toggle sets true at :1313); `VRAM_FULL/COMPRESSED/LOW` enum L2292; `vram_mode` L2293 (static; set by flightrun:240, read by gamesource:6512); **`_baked_suffix()` L2304 reads `HighpolyGameSource.PROP_LOD` L2310 — the confirmed cross-script const hazard**; `GEOM_SUFFIX` L2319; `bake_geometry_only` L2328 (static false).

**L2410-L2622 — Worker-thread texture compression + VRAM watchdog.** `_compress_textures()` L2470; `VRAM_WARN_MB` L2583 (6144); `vram_check()` L2594.

**L2624-L2888 — GLB parse, material passes, deferred sidecar cache.** `_parse_prop_file()` L2627 (split-part L2653-2678, single sidecar L2680-2694, geom tier L2714, glTF L2728-2758); `_finish_prop()` L2766; `flush_sidecars()` L2845; `_write_sidecar()` L2866.

**L2889-L3169 — Shader preferences + per-material swap passes.** `shader_prefs` L2894 (static, written by toggle:4222-4263); `TBLEND_SHADER` L2956; `_terrainblend_materials()` L2981; `_bind_ground_globals()` L3022 (flat-white warning L3032, `bf6_ground_col`/`bf6_ground_rect` L3035-3045); `white_texture()` L3054; `_wind_swap_materials()` L3062; `apply_shader_prefs()` L3118.

**L3170-L3410 — Parallax facades, surface merging (dead), LOD gen, helpers.** `_merge_equal_surfaces()` L3233 (DEAD); `_with_lods()` L3346.

**L3411-L3820 — Mesh merge pipeline + geometry helpers.** `_merge_meshes_inner()` L3490 (content key L3523, 255-surface split L3579, MikkTSpace L3599-3608); `_bake_mesh()` L3724; `_flipped_mesh()` L3791.

**L3821-L3887 — Backdrop MultiMesh placement.** `_add_multimesh()` L3823; `mark_never_casts()` L3882.

**L3888-L4413 — `apply()`/`_apply_body`: THE BUILD ORCHESTRATOR** (~500 lines). See pipeline below.

**L4414-L4459 — Build-done query + nearest-first queueing.** `is_build_done()` L4418; `_sorted_prop_entries()` L4421.

**L4460-L4735 — `_build_backdrop_async` + hide-while-building.** L4460 (near-duplicate of props loop); `_begin_build_draw()` L4688; `_end_build_draw()` L4697.

**L4736-L5118 — `_build_props_async` + progress reporting.** L4736 (~315 lines); `_report_progress()` L5057 (writes status_label L5080, print() L5084, build_progress.txt L5085-5088, AND emits build_progress).

**L5119-L5318 — Storage: usage, purge, cleanup.** `dir_usage_async()` L5120; `purge_map()` L5186; `purge_everything()` L5237; `cleanup_stale()` L5279.

**L5320-L5419 — Water surfaces.** `_add_water_plane()` L5328 (`Water` group L5341-5345).

**L5420-L5766 — Heightfield terrain mesh.** `TERRAIN_CHUNKS` L5426 (16); `_build_terrain_from_heightmap()` L5434 (cache path L5450: `"%s/terrain_ck%d_s%d_v7.res"`; terrain-blend census log L5612 reads HighpolyGameSource.n_blend_slot/n_blend_named; raw `print()` at L5539 and L5615); `_heightmap_mesh()` L5637; `_skirt_arrays()` L5714.

**L5768-L5956 — External GLB loading + sidecar decode.** `_load_external_glb()` L5862; `_bind_side()` L5874; `_decode_side()` L5899; the prefetch block L5768-5856 is DEAD (~90 lines of comments for a removed pipeline).

**L5958-L6212 — Cell MultiMeshes, `ensure_layer`, `reskin`.** `_add_cell_multimeshes()` L5958 (cell key L5969); `ensure_layer()` L6013 (water L6062-6098, backdrop L6099-6117, objects L6118-6145 — re-implements apply's per-layer launch); `reskin()` L6159.

**L6215-L6377 — Instanced-group builder.** `PROPS_RS` L6241 (false — RS path dead); `_build_mmi()` L6321 (layer choice L6342-6348, size-gated shadow L6369).

**L6379-L6521 — Per-mesh draw distance + objects toggle.** `_set_mmi_lod()` L6402; `SUBPIXEL_ON` L6451 (false); `set_objects_shown()` L6509.

**L6524-L6696 — Environment decal volumes + backdrop toggle.** `EDV_MAX_DECALS` L6540 (2048); `_add_env_decals()` L6590; `set_backdrop_shown()` L6686.

**L6699-L6893 — HLOD cell merging + cache compaction.** `HLOD_CELLS` L6749 (0 — `_bake_hlod` L6800 is a no-op); `HLOD_ON_DEMAND` L6767 (false); `_compact_caches()` L6867.

**L6895-L7028 — `_reproject_roads` + receiver diagnostics.** `_reproject_roads()` L6895 (projected-volume early out L6911-6918, projector load L6927, `pj.run` L6940, journal audit L6947). Diagnostics L6955-L7027:
- L6955 "%d of %d decal vertices now sit on a prop surface"
- L6969 tris/instances/skipped
- **L6977 "%d of %d prop surface(s) are decal receivers … giving %d triangle(s)"**
- **L6988 four-way rejection: r_no_cell, r_not_inside, r_band, r_window + no_band L6995-6999**
- **L7002-L7015 receiver meshes BY NAME (top 10)**
- L7016-7021 straddling; L7022-7027 index_truncated warning

**L7030-L7223 — Layer queries, context toggle, merge distance, radius, grass.** `set_roads_shown()` L7030; `set_context_shown()` L7062; `set_merge_distance()` L7105; `set_radius()` L7184; `set_grass()` L7214.

**L7224-L7353 — `_apply_radius`: distance streaming.** L7224 (only-new fast path L7243, hysteresis L7295, budgeted apply L7314-7329, backdrop AABB cull L7333-7338); `_editor_cam()` L7340.

**L7354-L7545 — `tick()`, SDK-decal watchdog, near-field window.** `tick()` L7354; `_tick_near()` L7424; `_near_apply()` L7487 (`terrain_ready.emit` L7511/L7541 — the true end of the terrain pipeline).

## Build pipeline order (THE load-bearing sequence)

`apply()` L3906 → `_apply_body()` L3915:
1. `_ph_reset()` L3921 → snapshot prev state L3923-3930 → `map_of` guard L3937
2. Skyline salvage L3953-3961; props salvage (`_can_keep_props` L3978) L3977-3985
3. `_clear()` L3987
4. On map switch: `game_source.release_caches()` L4026-4036
5. `_load_data(map)` L4046 (→ map_data; sets terrain_step/drape_step/_cell_size)
6. ctx = `_MAP_CONTEXT` Node3D L4063
7. `_bind_ground_globals(map)` L4079; `_terrain_shader_mat(map)` if textured L4088
8. maptile/SDK-decal L4104-4105
9. TERRAIN: `_build_terrain_from_heightmap` L4170
10. SCATTER: `_scatter.setup` L4197
11. ROADS: live `_data["roads"]` Mesh L4218-4227 else roads.glb L4228-4245; BJournal audit L4267
12. WATER: `_add_water_plane` L4277
13. BACKDROP: salvage L4292-4298 else `_build_backdrop_async` (fire-and-forget) L4322
14. PROPS: salvage L4349-4359 else `_build_props_async` (fire-and-forget) L4386; `_add_env_decals` L4389

`_build_props_async` tail (post-build chain): `_apply_radius` L4939 → `_building=false` L4942 → `_end_build_draw` L4945 → **`await _reproject_roads` L4954 → `await _bake_hlod` L4955 → `_compact_caches` L4956** → `flush_sidecars` L4960 → `_report_progress(true)` L4963 → `_release_texture_images` L4968 → `log_water_state` L4977 → census rows L4991-5043 → `build_finished.emit` L5051.

After the build — `tick()` L7354: `_hlod_pump` L7368 → `_apply_radius(budget)` L7385 → scatter L7390 → `_tick_near` L7391 → `_tick_sdk_decal` L7392; near window ends at `_near_apply` L7487 → `terrain_ready.emit(true)` L7541.

Single-layer path (no teardown): `ensure_layer()` L6013.

## Cross-script const reads (fold hazards)
- **L1069** `const TEXTURED_LAYER := HighpolyLib.TEXTURED_LAYER` — folded into this script's const table at parse time.
- **L2310** `HighpolyGameSource.PROP_LOD` in `_baked_suffix()` — keys every sidecar; stale parse = wrong LOD rung silently.
- L3367 `BcTex.EXT` (dead code); L5247 `HighpolyStore.MODELS_DIR/THUMBS_DIR` (in purge_everything — a mismatch deletes the wrong dir).

## Cache keys
- Per-map dir: `"%s/%s" % [CACHE, map]`; splat `%s/splat`; colormap.png; prop_layers.json; scatter.json
- `_baked_suffix` L2310-2314: `".baked5l%s.res"` / `".baked5f%s.res"` / `".baked5%s.res"` (%s = "" or "lod%d") — IN: vram_mode, PROP_LOD
- `_part_suffix` L2301: `"%s.p%d.res"`
- terrain cache L5450: `"%s/terrain_ck%d_s%d_v7.res"` — IN: map, chunks, step, version
- reader caches L5211-5219: `user://bf6_geom/<lvl>_<sig>/`, `bf6_walk_<level>_v<n>_<sig>.idx`, `bf6_index_…`, `bf6_pidx_…`
- cell key L5969: `"%d,%d"` from world min + cell size

## Redundancy highlights (feeds refactor)
- `_apply_body` ~500 lines; `_build_props_async` ~315; `_build_backdrop_async` ~197 (near-duplicate of props loop); `_build_terrain_from_heightmap` ~195; `_reproject_roads` L6944-7027 is pure reporting.
- `ensure_layer` re-implements apply's launches ×3; four copies of flat/clay material selection.
- Dead: `_purge_terrain_cache` L807, `_maptile_tex` L963, `_merge_equal_surfaces` L3233 + `_concat_surfaces` L3274, `_want_companions` L3362, `_extract_mesh` L3754, `_collect_prop_mmis` L5091, `_free_mmi_list` L5101, `reset_props_verification` L645; consts POLL_SECS/UNPACK_JOB/BUILD_JOB_OF2/SDK_CONFIG/TILE_URL_FALLBACK/RANGED_JOB/ARCHIVE_JOB/MERGE_MIN_SURFACES/READER_CACHE_DIR; ~250 lines of flag-dead HLOD/RS/subpixel code; the prefetch block L5768-5856.
- Progress: `_report_progress` uses FOUR channels (signal, status_label, print, build_progress.txt); `decal_progress` carries two unrelated phases (HLOD L6840 + roads L6939); `stage_progress` never emitted.
- Raw `print()` at L5539, L5615, L5084. Two log front-ends (Log preload + HighpolyLog global).
