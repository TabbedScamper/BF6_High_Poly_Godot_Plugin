# Region map — `highpoly_gamesource.gd` (8,883 lines; anchors for commit `16fed50`)

> Note: the file is **8,883 lines**, not 8,371. Every line was read by the surveyor.

---

## REGION MAP

**L1-L56 — Header contract + injected logger.** States why this file exists (replace the 6.6 GB redistributed `mapcontext` download with a read of the player's own BF6 install) and establishes that logging is *injected*, never imported, so the reader is testable outside the editor.
- `class_name HighpolyGameSource` (L3) — the greppable global type.
- `var log_fn := Callable()` (L34) — the injected sink; empty = `print`.
- `var _exe_used` (L40), `var _exe_others` (L41) — which `bf6.exe` supplied type layouts.
- `func _say(s)` (L44) — the file's own logging primitive; defers to main thread via `log_fn.call_deferred` when off-thread (L52-55).

**L58-L238 — Reader state and every in-memory cache declaration.** Owns the handles to the reader stack (`BF6Source`/`BF6Types`/`BF6Walk`), the mount policy (level-only now, catalogue later), and declares the whole cache surface that `release_caches` later has to clear.
- `const BJournal = preload("highpoly_journal.gd")` (L61) — the only `preload` in the file.
- `const MESH_SUFFIX := "_mesh"` (L62), `const SHADERSTATE := "_win32_shaderstate/"` (L64).
- `var src` (L66), `var types` (L67), `var walk` (L68), `var level` (L69), `var error` (L70).
- `var catalogue_mount` (L103), `var catalogue_ready` (L108), `var placements_ready` (L112), `var surface_cache` (L116).
- `var _res_for` (L119), `var _ms := BF6MeshSet.new()` (L120), `var _tex := BF6Texture.new()` (L121).
- `var _depot_bundles` (L125), `var _depot_cache` (L126).
- `var _tex_cache` (L136), `var _mat_cache` (L137), `var _mat_by_look` (L138).
- `var _keys_for` (L158), `var _mesh_by_sig` (L159), `var n_mesh_shared` (L160), `var _group_meta` (L161).
- `var build_materials` (L168), `const TEX_DIM_SETTING` (L193), `var texture_max_dim := 512` (L194).
- `var timings` (L203), `const FROM_INSTALL/FROM_CACHE/FROM_MEMORY/FROM_MIXED` (L226-229), `var phases` (L231), `var _phase_order` (L232), `var read_was_cold` (L237).

**L240-L602 — Instrumentation: phase table, install fingerprint, reports.** Owns this file's *own* measurement model — per-phase wall/items/provenance, the "your install vs a known-good one" fingerprint, and the per-mesh cost table. All of it renders to strings via `_say`.
- `func note_phase` (L243), `func add_phase` (L255), `func _ph_forward` (L283) — forwards to `BJournal.phase` from any thread, to `HighpolyProfile.add` only from the main thread.
- `var _catalog_names` (L314), `const REF_EBX/REF_RES/REF_NAMES/REF_SCOPES` (L316-319).
- `func install_report` (L321), `func phase_report` (L393), `func print_phases` (L423) — also prints `BF6Cas.io_report()` (L441).
- `func build_report` (L455) — the per-mesh table plus the "surfaces that drew white" and "textures decoded" blocks.
- `static func _grouped_i` (L583); `var _hm_paint_us` (L595), `var _hm_texels` (L596), `var _hm_grid` (L597); `func print_build_report` (L600).

**L605-L770 — Lazy top-ups after the map is on screen.** Owns the three pieces of work deliberately moved *off* the open path: the placement walk, the ground composite, and the whole-catalogue mount. Each is blocking and meant for a worker.
- `func ensure_placements(progress)` (L614) — re-runs `walk.run_cached`, then `drop_map_data()`.
- `func ensure_ground(cache_dir, progress)` (L646).
- `var catalogue_upgrading` (L708) — documented as *not a lock* and read by nobody.
- `func upgrade_catalogue(progress)` (L711) — rebuilds `_depot_bundles` privately and publishes on the main thread (L736-763), clearing `_obj_cache` and `_sib_scopes` in the same swap.

**L773-L878 — Texture stats, availability probe, stage vocabulary, geometry epoch.** Owns the public stage list and weights the UI's bar draws from, and the geometry-version number.
- `var tex_dims` (L773), `var tex_stats` (L774) — the shared stats dictionary.
- `static func available(game_dir)` (L781).
- `const ST_MOUNT…ST_LAYERS` (L791-800), `const OPEN_STAGES` (L802), `const STAGE_WEIGHT` (L818).
- `static var n_blend_slot` (L864), `static var n_blend_named` (L865) — read by `highpoly_mapcontext.gd:5613`.
- `const GEOM_EPOCH := 11` (L869), `static func geom_epoch()` (L877) — the call exists precisely so live reload is not fooled by constant folding.
- `const C_WRAP_TEXCOORD := 0x4F5F0664`, `func _wrap_channel_fix(secs, scope, var_hash)` (near `_alpha_gate`) — post-parse carpaint UV override: resolves each carpaint section's depot record (variation-derived key first, like `material_for`) and swaps `sec.uvs` to the texcoord the flag names (1 ⇒ TC1, 0/absent ⇒ TC3). Called from `_mesh_for_body` right after `read_lod`. See readers.md bf6_meshset for the measurement.

**L880-L1224 — `open_map` / `open_async`: the cold read.** Owns mount → type database → partition index → depot scope index → placement walk → geometry cache open → optional ground. Everything downstream depends on the state this leaves behind.
- `static func _fail(stage, why)` (L904) — names the failing stage and reports free RAM.
- `func open_map(map, game_dir, progress, want)` (L912) — ~246 lines; includes the "already open, nothing missing" early return (L928-935) and the `want.placements` gate (L1091).
- `var _open_result` (L1171), `var _open_done` (L1172), `var _prog_stage/_prog_done/_prog_total` (L1189-1191).
- `func open_async(host, map, game_dir, want, progress)` (L1194) — worker task + main-thread frame pump that re-emits progress at most once a frame.

**L1227-L1430 — `map_data` cache and the lazy optional sections.** Owns the once-per-map derived summary and the rules for when it must be recomputed.
- `var _map_data` (L1249), `var _map_data_key := "￿"` (L1250), `var _md_built` (L1254).
- `func drop_map_data()` (L1274), `func refresh_water()` (L1291), `func map_data_ready(cache_dir)` (L1309), `func map_data_would_build(cache_dir, want)` (L1321).
- `const MD_OPTIONAL := ["lights","fx","water","edv"]` (L1358), `func map_data(cache_dir, want)` (L1360), `func _md_need(want)` (L1377), `func _md_fill(cache_dir, need, out)` (L1388).

**L1432-L1691 — Layer classification and `_build_map_data`.** Owns the grouping of walk rows into `(mesh, scope, variation)` prop/backdrop groups, the transpose convention, and the assembly of the whole `map_data` dictionary.
- `func layer_of_scope(scope)` (L1456) — subworld leaf → switchable layer name; the gamemode-token list is at L1485-1488.
- `func _build_map_data(cache_dir, need)` (L1497) — ~194 lines; calls `terrain`, `terrain_surface`, `roads`, `_md_fill`, and releases `_hm["data"]` at L1674-1679.

**L1694-L1857 — The heightfield: `terrain()`.** Owns compositing the streaming-tree height block into `height_game.r16` + `height_game.json`, and reading it back.
- `static func _terrain_key(res)` (L1715) — the cache fingerprint.
- `func terrain(cache_dir)` (L1725) — includes the read-back path (L1752-1777), the `holes_game.png` removal (L1818), and `_build_tile_steps()` (L1766, L1842).

**L1860-L2473 — `terrain_surface()`: the ground's appearance.** Owns colour map, layer palette, splat composite, base/street field, per-layer slice PNGs, the LUT remap, and `layers.json`. The single largest function in the file.
- `const SURFACE_RES_MIN/MAX/M_PER_TEXEL` (L1901-1903), `static func _surface_res_for` (L1905).
- `const COLOR_RES_MIN/MAX` (L1916-1917), `static func _color_res_for` (L1919).
- `const CMAP_VERSION := 2` (L1929), `const SPLAT_VERSION := 10` (L1967), `const LAYER_TEX_DIM := 1024` (L1973).
- `var _surface_cached` (L1980), `var _surface_tried` (L1996), `var _surface_failed` (L1997).
- `func _palette_rows(pal)` (L2004), `func terrain_surface(cache_dir, force, progress)` (L2017) — ~456 lines mixing I/O, image compositing, PNG encoding, thread-pool fan-out and JSON writing.

**L2476-L2634 — The near-field detail window.** Owns a 0.5 m/texel recomposite around the camera, seeded from the far raster.
- `static func _linked_of(pal)` (L2478), `const NEAR_RES := 2048` (L2502), `const NEAR_SPAN := 1024.0` (L2503).
- `var _win_state` (L2505), `func _window_state(cache_dir)` (L2508) — rebuilds the bake's LUT from `layers.json`.
- `func terrain_window(cache_dir, cx, cz)` (L2585).

**L2637-L2736 — Layer texture decode and the slope fallback pair.** Owns squaring every slice to `LAYER_TEX_DIM` and picking the ground/cliff fallback by material class.
- `func _layer_image(res_name, _is_normal)` (L2644).
- `const FB_NATURAL` (L2687), `const FB_HARD` (L2689), `const FB_EXCLUDE` (L2690).
- `func _fb_pick(pal, by_area, words, not_this)` (L2694), `func _write_fallback_layers(pal, by_area, out_dir)` (L2716).

**L2739-L3187 — Roads: shaders, tuning constants, and `roads()`.** Owns reading `TerrainDecals`, grouping by `(cv, op)` or terrain-layer slot, subdividing, draping on `_hm`, and emitting one surface per group.
- `const DECAL_SUBDIV_MAX := 3` (L2779), `const DECAL_SUBDIV_MAX_TRIS := 60000` (L2781), `const ROAD_Y_BIAS := 0.01` (L2783).
- `const ROAD_DECAL_SHADER` (L2800), `const ROADS_PROJECTED := false` (L2895), `const PROJECT_DOWN := 6.0` (L2900), `const PROJECT_UP := 1.5` (L2902), `const ELEVATED_OVER := 2.0` (L2905), `const ROAD_SHADER` (L2907).
- `var _road_shader` (L2947), `var _hm` (L2948), `var road_stats` (L2949).
- `func roads() -> Mesh` (L2957) — ~230 lines; draw-order priorities at L2998-3016.

**L3190-L3468 — Road geometry helpers and road materials.**
- `func _emit_prism(...)` (L3196), `func _custom_slice(custom, ch)` (L3262) — both reachable only when `ROADS_PROJECTED` is true.
- `var _road_subdiv_tris` (L3278), `func _decal_subdiv(vs)` (L3287), `func _subdivide_tris(vs, level)` (L3321), `func _prop_guid(props, slot)` (L3362).
- `var _road_pal` (L3370), `var _road_pal_tried` (L3371), `func _road_layer_albedo(layer)` (L3374), `func _road_material(key, priority)` (L3398) — names materials `bf6_road_fill` (L3453) / `bf6_road_mark` (L3467).

**L3471-L3604 — The drape lattice, colour-map handoff, and `_height_at`.** Owns the one adaptive step table both the terrain mesh build and the road drape read.
- `var drape_step := 2` (L3475) — written by `highpoly_mapcontext.gd:1918`.
- `const TILE_CHUNKS := 16` (L3483), `var _tsteps` (L3484), `var _tcpx` (L3485).
- `var _cmap_mem` (L3489), `var _cmap_mem_level` (L3490), `func colormap_image(map)` (L3493).
- `func tile_steps()` (L3497), `func _build_tile_steps()` (L3501), `func _height_at(x, z)` (L3566).

**L3607-L3930 — Water: partition discovery and the block-2 river surface.** Owns finding which partition declares the `WaterSurfaceEntityData`, and decoding terrain block 2 into an actual water mesh clipped against the ground.
- `const WATER_TYPE` (L3627), `var _water_part := "￿"` (L3646), `func _water_partition()` (L3648), `func _counts_water(name)` (L3678).
- `const WATER_GRID := 1024` (L3710), `func terrain_water(cache_dir)` (L3713) — ~217 lines; the tail-offset candidate list is at L3775.

**L3933-L4189 — `water()` and the water look from the depot.** Owns marrying the block-2 shape to the entity's material record and its ocean-sim inputs.
- `func water(cache_dir) -> Array` (L3933).
- `const WATER_STATE_KEY := 0x2E15621F` (L4066), `const WSLOT_FOAM_RGB/WATER_A/WATER_B/FOAM_NSH/DETAIL_NSH/NOISE/PERLIN/OCEAN_COLOR` (L4068-4075), `const WSLOT_ROLE` (L4077).
- `var _water_look_cache` (L4082), `func _water_look(state_key)` (L4094), `func _water_params(dep, d, key)` (L4118), `func water_texture(file_guid, is_normal)` (L4188).

**L4192-L4391 — The ocean simulation inputs.** Owns reading `WaterOceanSimulationEntityData` out of the level's `*_schematic` partitions.
- `const SIM_TYPE` (L4227), `const SIM_ENABLE…SIM_WAVE_THICKNESS` (L4228-4239), `const SIM_CURVE_TYPE/X/Y` (L4268-4270), `const SIM_VEC4` (L4271).
- `var _water_sim_done` (L4273), `var _water_sim` (L4274), `func water_sim()` (L4282), `func _sim_in(name)` (L4324), `func _sim_row(d, part, idx)` (L4346), `func _sim_curve(v)` (L4365), `func _sim_flat(c, members)` (L4385).

**L4394-L4586 — Lights: type/field tables and record extraction.** Owns the light schema written to `lights.json`, shared with the placed-object walker.
- `const LIGHT_TYPES` (L4413), `const F_COLOR…F_VISIBLE` (L4430-4437), `const F_ENABLED` (L4441), `const LIGHT_FIELDS` (L4444).
- `func _light_record(ent)` (L4501) — the -forward spot convention at L4549; `func _light_records(ents)` (L4555); `func lights(cache_dir) -> int` (L4566).

**L4449-L4487 (interleaved) / L4588-L4731 — Environment decal volumes.** Owns the volume→template→depot-state-key→sheet chain and the records the map context turns into `Decal` nodes.
- `const EDV_TYPES` (L4470), `const EDV_TEMPLATE_TYPES` (L4476), `const F_EDV_TEMPLATE/ENABLE/ALPHA/CULL` (L4480-4483), `const F_EDVT_KEY` (L4484), `const EDV_FIELDS` (L4486).
- `var _edv_tpl_cache` (L4597), `func _edv_template(ptr)` (L4600), `func _edv_records()` (L4633), `func decal_sheet(file_guid)` (L4728).

**L4734-L4861 — FX spawn points.** Owns filtering event-triggered effects out of the walk rows and joining each to its emitter graph.
- `const FX_TRIGGERED` (L4748), `const FX_CLASSES` (L4754), `static func _fx_class(n)` (L4763).
- `func fx(cache_dir, keep_triggered) -> int` (L4771), `func _fx_graph(path)` (L4840).

**L4864-L5070 — The sky panorama.** Owns finding the level's `ve_*` preset, pulling the panorama out of its imports, and remapping 4:1 → 2:1 equirect.
- `const F_PANORAMIC_TEXTURE` (L4884), `const F_LUMINANCE_SCALE` (L4885), `const F_SKY_TYPE` (L4886), `const F_PANORAMIC_ROTATION` (L4887).
- `func sky()` (L4891), `func _sky_from(ve)` (L4911), `func _panorama_import(e)` (L4960), `func _texture_for_asset(asset)` (L4983), `var _sky_cache` (L5002), `func _ve_candidates()` (L5008), `static func _ref_guid(v)` (L5041), `static func _to_equirect(src_img)` (L5055).

**L5073-L5414 — Scatter catalogue, Portal objects, and scope resolution.** Owns the clutter list from `MeshScatteringDatabase`, the assembly of `pf_portal_*` prefabs into `Node3D`s, and the two rules for finding a depot scope.
- `func scatter_entries()` (L5092), `var _scatter_cache` (L5136).
- `const PORTAL_PREFIX := "pf_portal_"` (L5154), `var _obj_walk` (L5156), `var _obj_cache` (L5157), `var _obj_lights` (L5158).
- `func object_node(portal_name)` (L5167), `func _object_node_body(portal_name)` (L5179), `const NAME_PREFIXES` (L5211), `func _resolve_object(key)` (L5223), `func _resolve_prefixed(key)` (L5233), `func object_rows(portal_name)` (L5244), `func object_lights(portal_name)` (L5344).
- `func _scope_of(res_name)` (L5365), `func _scope_by_path(res_name)` (L5382), `func has_object(portal_name)` (L5397), `func _level_dir()` (L5408).

**L5417-L5626 — Mesh name resolution, per-mesh counters, variation liveness, destruction.** Owns `blueprint → res name`, the whole per-mesh timing/counter block, the variation hash and its liveness test, and the hidden-parts table.
- `func resolve_mesh(mesh_path)` (L5418).
- `var t_res` (L5452), `t_parse` (L5453), `t_mat` (L5454), `n_meshes` (L5455), `n_sections` (L5457), `n_surfaces` (L5458), `n_uv2_surfaces` (L5470), `n_pal_split` (L5474), `n_pal_rebuilt` (L5475), `t_tex` (L5484), `t_depot` (L5485), `n_depot_parsed` (L5486), `n_mat_built` (L5487), `n_mat_cached` (L5488), `n_geom_hit` (L5492), `n_geom_miss` (L5493).
- `static func _var_hash(ov)` (L5501) — djb2-lower; `var _var_live` (L5530), `var _sec_keys` (L5531), `func _variation_live(scope, vh, res_name)` (L5534).
- `const F_PHYSICS_PART_INFOS` (L5574), `F_HEALTH_STATE` (L5575), `F_PART_COMPONENT` (L5576), `MESHTYPE_SKINNED` (L5577), `var _hidden_cache` (L5579), `func _hidden_parts(res_name, info)` (L5582).

**L5629-L6002 — Cache accounting and the Diagnose chain.** Owns freeing memory (scene-aware compaction and full release), attributing what the caches hold, and explaining one mesh's resolution chain step by step.
- `func compact_caches(root)` (L5672), `func release_caches()` (L5740) — clears 24 dictionaries/arrays; `func cache_stats()` (L5808).
- `func describe(am)` (L5884), `func describe_state(state_key, scope, var_hash, index, pal)` (L5904), `func _section_keys(res_name)` (L5990).

**L6005-L6461 — `mesh_for`: geometry for one group key.** Owns the memory share test, the disk-cache hit path, the MeshSet parse, the palette-selector split, the one-surface-per-material merge, and naming surfaces after their merge keys.
- `static var _mesh_trace` (L6014), `func mesh_for(group_key, lod)` (L6026) — the paired ENTER/leave trace wrapper.
- `const PROP_LOD := 0` (L6057) — **read cross-script** by `highpoly_mapcontext.gd:2310`.
- `func _mesh_for_body(group_key, lod)` (L6060) — ~400 lines mixing cache lookup, resource I/O, palette analysis, index merging and surface naming.

**L6464-L6567 — The on-disk geometry cache.** Owns the versioned cache directory and the load/save of merged, material-free `ArrayMesh` resources.
- `var geom_cache := true` (L6476), `var _geom_dir` (L6477), `n_geom_loaded` (L6478), `n_geom_saved` (L6479), `t_geom_load` (L6480), `t_geom_save` (L6481).
- `func _geom_open()` (L6484), `func _geom_path(kc)` (L6526), `func _geom_load(kc)` (L6530), `func _geom_save(kc, keys, am)` (L6549), `func _keys_of(am)` (L6563).

**L6570-L6822 — Dressing, re-dressing, and scope fallback.** Owns putting materials onto built surfaces, the live-reload invalidation, the sibling-scope rescue, and the mesh-share signature.
- `var _dressed` (L6588) — documented as the largest strong holder; `var _dress_name` (L6591), `var _dress_uv2` (L6598).
- `func _dress(am, keys, scope, var_hash)` (L6601), `func invalidate_materials(only)` (L6643) — clears 14 caches and 5 held shaders.
- `var _sib_scopes` (L6727), `func _siblings_of(scope)` (L6729), `func _material_any(state_key, scope, alt, var_hash, pal)` (L6747), `func _dress_only(...)` (L6783), `func _sig_for(kc, keys, scope, var_hash)` (L6809).

**L6824-L7257 — `material_for`: the material decision tree.** Owns the ordered dispatch — glass → carpaint → tilepaint → look-key share → smoke → decal → mask/foliage → tint-mask → smoothness → plain `StandardMaterial3D` — plus the variation-derived key rule. The masked branch is gated by `_alpha_gate(consts)` (const `C_ALPHA_TEST 0x77d10576`, beside `_vec2_const`): a record can bind a REAL varying mask as foreign slot filler with the switch OFF (truckpickup offroad wheel carried the van wheel's `_a`) - the switch is checked before the content test; absent = old behaviour. `describe_state` reports the switch too.
- `func material_for(state_key, scope, var_hash, pal)` (L6831) — ~426 lines; cache key at L6840-6849; the `M_TerrainBlend` naming at L7199-7206 and the named-empty exit at L7242.

**L7260-L7458 — Glass, and the prop-tint constants.** Owns the glass fingerprint/tint and the whole linear-tint chain (paint → per-family tint → colour table) plus the sRGB encode rule.
- `const C_GLASS_PALETTE` (L7271), `const C_GLASS_ARCH` (L7272), `func _glass_tint(slots, consts)` (L7275), `func _glass_material(slots, tint)` (L7313).
- `const C_ALBEDO_TINT` (L7366), `C_PAINT_MUL` (L7367), `C_ARCH_LAYER` (L7368), `C_COLOR_TABLE` (L7369), `C_CARPAINT_BODY` (L7370), `C_CARPAINT_SMOOTH` (L7371), `C_TILEPAINT_A` (L7372), `C_TILEPAINT_B` (L7373), `const TINT_EPS := 0.004` (L7378).
- `func _c3(raw, o)` (L7381), `static func _near(c, v)` (L7390), `func _albedo_tint(consts, pal)` (L7401), `static func _srgb_of(c)` (L7456).

**L7461-L7672 — Colour-table canonicalisation and merge-key encoding.** Owns deciding whether a surface must be cut by palette entry, and the `"<key>@<entries>"` surface-name codec that carries that fact through the geometry cache.
- `func _table_canon(raw)` (L7476), `func _pair_canon(raw_a, raw_b)` (L7510), `var _pal_canon_cache` (L7548), `func _pal_canon(state_key, scope, var_hash)` (L7551), `func _needs_split(keys, scope, var_hash)` (L7587).
- `static func _mkey(v)` (L7616), `func _surface_name(bid, key_sel, key_canon)` (L7630), `static func _bits(mask)` (L7654), `static func _mpal(v)` (L7664).

**L7675-L7814 — Carpaint, wrap liveries, and the look key.** Owns the body-vs-member rule, the wrap sheet's dominant-colour probe, and the string that lets two scopes share one material.
- `func _is_body_member()` (L7693), `func _carpaint_of(slots, consts)` (L7704), `var _wrap_paint_cache` (L7731), `func _wrap_paint_of(file_guid)` (L7734).
- `func _look_key(slots, tint)` (L7781) — the 9-part key at L7808-7814.

**L7817-L8143 — Opacity masks, foliage materials, and the paint mask.** Owns the content tests that decide whether an alpha slot is a real cutout, and the two shader materials built from them.
- `var _mask_cache` (L7829), `var _mask_cut` (L7830), `var _foliage_shader` (L7831), `var _prop_tint_shader` (L7832), `func _mask_for(file_guid)` (L7835).
- `const CUTOUT_MIN_CLEAR := 0.02` (L7948), `const CUTOUT_MAX_CLEAR := 0.98` (L7949), `const CUTOUT_SAMPLES := 128` (L7950), `const MASK_MAX_DIM := -1` (L7964), `static func mask_shape(img)` (L7967).
- `func _cut_for(file_guid)` (L8009), `func _foliage_material(slots, mask, cut, tint)` (L8021) — loads `foliage_wind.gdshader` (L8024).
- `var _tint_mask_cache` (L8078), `func _tint_mask_for(file_guid)` (L8081), `const TINT_MASK_MIN_RANGE := 0.02` (L8141), `const TINT_MASK_PROBE_DIM := 128` (L8142).

**L8145-L8346 — Decal-sheet probes, prop emission, smoothness probe, lit sheets.**
- `var _decal_tex_cache` (L8157), `func _decal_sheet(file_guid, is_normal)` (L8160).
- `static var prop_emission := 1.0` (L8218), `var _emissive_mats` (L8232), `func set_prop_emission(v)` (L8237).
- `var _smooth_cache` (L8251), `func _smooth_varies(file_guid)` (L8259), `func _lit_sheet(slots)` (L8299), `func _decal_sheet_varies(file_guid)` (L8310).

**L8349-L8730 — Smoke, decal, tint-masked, smoothness and tile-paint materials.**
- `var _smoke_shader` (L8349), `const C_SMOKE_TINT` (L8355), `C_SMOKE_SCROLL_A/B` (L8356-8357), `C_SMOKE_DISTORT` (L8361), `C_SMOKE_GAIN` (L8364), `func _vec2_const(consts, hash_id, fallback)` (L8367), `var _litpack_cache` (L8377), `func _is_lighting_packed(tex)` (L8379), `func _smoke_of(slots, consts)` (L8411).
- `var _decal_shader` (L8485), `const C_DECAL_GLOSS` (L8504), `func _decal_gloss(consts)` (L8507), `func _decal_of(slots, consts)` (L8515).
- `func _tint_masked_material(slots, tint)` (L8569), `func _smooth_material(slots, tint)` (L8612), `const C_TILE_UV` (L8673), `func _tilepaint_of(slots, consts, pal)` (L8676).

**L8733-L8883 — The texture loader and the depot loader.** The two lowest-level shared primitives: everything above that wants pixels or a `ShaderBlockDepot` goes through exactly these.
- `func _texture_for(file_guid, is_normal, cap)` (L8743) — cache key at L8749-8756, cap accounting at L8815-8820, byte accounting via `HighpolyBcTex.img_bytes` (L8827), S3TC compress (L8830) and mipmap generation (L8852).
- `func _depot_for(scope)` (L8860) — one parse per scope, returns `[BF6Depot, raw bytes]`.

---

## 1. Contract

This file is the **read side of the plugin**: given a map name and the player's own Battlefield 6 install, it produces (a) a `map_data` dictionary shaped exactly like the retired `placements.json`, (b) per-group `ArrayMesh`es with materials attached, and (c) a set of derived files under a per-map cache directory (heightfield, splat/colour bake, `lights.json`, `fx.json`). It must **never** touch the scene tree, create `Node`s or `Texture`s off the main thread, redistribute EA assets, or invent a second build path for game-sourced maps — `map_data()` returns the shape `_load_data` already understands, on purpose.

**In:** a map name, an optional game directory, a `want` dictionary of optional sections, a cache directory, an injected `log_fn`, a `progress` Callable, and two externally-written knobs (`drape_step`, `texture_max_dim` via `ProjectSettings`). **Out:** `map_data()` dictionaries, `Mesh`/`Material`/`Texture2D` objects, `Node3D` prefab assemblies, on-disk cache files, and report strings (`install_report`, `phase_report`, `build_report`) plus stats dictionaries (`phases`, `timings`, `tex_stats`, `tex_dims`, `road_stats`).

---

## 2. Key constants and toggles

### Cross-script const reads — **parse-time folding hazards**

| Line | Name | Value | Gates | Hazard |
|---|---|---|---|---|
| L869 | `GEOM_EPOCH` | `11` | Geometry cache directory suffix `_g11`; bump orphans every cached mesh | **Read as a literal by `tools/perfrun.py:349`** (regex `const GEOM_EPOCH`). `highpoly_toggle.gd:2506/2508` and `tools/test_reloadimpact.gd:52` correctly go through `geom_epoch()` (L877). The whole comment at L871-878 exists because a folded const read would report a stale epoch after live reload. |
| L6057 | `PROP_LOD` | `0` | LOD rung for props; also the `_l%d` geometry cache suffix | **`highpoly_mapcontext.gd:2310` reads `HighpolyGameSource.PROP_LOD` directly — this folds at parse time.** Same class of bug `geom_epoch()` was invented to avoid; there is no `prop_lod()` accessor. |
| L802 | `OPEN_STAGES` | 10 stage strings | UI's stage list | Read by `highpoly_toggle.gd:2842, 2855, 2857, 2876, 2940, 2976` — an array const, folded into the dock at parse time. |
| L818 | `STAGE_WEIGHT` | dict, mount 16.0 … splat 135.0 | Bar travel per stage | Read by `highpoly_toggle.gd:2987`. Same folding hazard. |
| L864-865 | `n_blend_slot`, `n_blend_named` | `0` | Terrain-blend naming diagnostics | `static var`, **not** const — read by `highpoly_mapcontext.gd:5613`; safe, but statics never reset per build. |
| L8218 | `prop_emission` | `1.0` | Emission multiplier on every emissive material | `static var`; set via `set_prop_emission` (L8237). |

### Cache/version epochs

- **L1929 `CMAP_VERSION := 2`** — colour-map decode version; written into `layers.json` as `cmap_v` but **never gated on read** (only `splat_v` is checked, L2055/L2517).
- **L1967 `SPLAT_VERSION := 10`** — gates the whole surface cache (L2055) *and* the near-field window (L2517).
- **L1722 `"+h3"` suffix** inside `_terrain_key` — the heightfield's own epoch, spelled as a string literal rather than a named const.

### Resolution / memory knobs

- **L193-194 `TEX_DIM_SETTING := "highpoly/texture_max_dim"`, `texture_max_dim := 512`** — the single biggest VRAM lever; read at every `open_map` (L917-920), accepts `0` or `64..8192`.
- **L1901-1903 `SURFACE_RES_MIN 2048` / `SURFACE_RES_MAX 4096` / `SURFACE_M_PER_TEXEL 2.0`** — splat raster density.
- **L1916-1917 `COLOR_RES_MIN 4096` / `COLOR_RES_MAX 8192`** — colour-map density.
- **L1973 `LAYER_TEX_DIM := 1024`** — every slice must match or `Texture2DArray` rejects the set.
- **L2502-2503 `NEAR_RES 2048` / `NEAR_SPAN 1024.0`** — near-field window, 0.5 m/texel.
- **L3710 `WATER_GRID := 1024`**, **L3483 `TILE_CHUNKS := 16`**, **L7950 `CUTOUT_SAMPLES := 128`**, **L7964 `MASK_MAX_DIM := -1`** (masks use `texture_max_dim`), **L8142 `TINT_MASK_PROBE_DIM := 128`**.

### Behaviour switches

- **L168 `build_materials := true`** — off skips material resolution entirely.
- **L103 `catalogue_mount := false`** — passed to `src.mount` (L963). **Never written by any caller in `addons/`** — effectively a dead toggle.
- **L6476 `geom_cache := true`** — disables the on-disk geometry cache.
- **L2895 `ROADS_PROJECTED := false`** — switches the road path between the projector and the drape; currently false, which makes `ROAD_DECAL_SHADER` (L2800), `_emit_prism` (L3196), `_custom_slice` (L3262), `PROJECT_DOWN` (L2900), `PROJECT_UP` (L2902) unreachable.
- **L3475 `drape_step := 2`** — written externally by `highpoly_mapcontext.gd:1918`.
- **L6014 `_mesh_trace`** — `BF6_MESH_TRACE=1` environment switch.

### Thresholds

- **L7378 `TINT_EPS := 0.004`**, **L7948-7949 `CUTOUT_MIN_CLEAR 0.02` / `CUTOUT_MAX_CLEAR 0.98`**, **L8141 `TINT_MASK_MIN_RANGE := 0.02`**, **L2783 `ROAD_Y_BIAS := 0.01`**, **L2779/2781 `DECAL_SUBDIV_MAX 3` / `DECAL_SUBDIV_MAX_TRIS 60000`**, **L2905 `ELEVATED_OVER := 2.0`**.
- **L316-319 `REF_EBX 450884` / `REF_RES 260328` / `REF_NAMES 818517` / `REF_SCOPES 16936`** — the known-good install reference figures; `< 90%` prints `<-- LOW`.

---

## 3. Cache keying

**Geometry cache directory — L6516**
```gdscript
var d := "user://bf6_geom/%s_%s_g%d%s%s" % [level, sig, GEOM_EPOCH, lodsfx, vsfx]
```
IN the key: `level`, `src.signature()` (TOC signature), `GEOM_EPOCH` (L869), `lodsfx` = `"" if PROP_LOD <= 0 else "_l%d" % PROP_LOD` (L6502), `vsfx` = `""` / `"_vlow"` / `"_vfull"` from `HighpolyMapContext.vram_mode` (L6511-6515).
NOT in the key: `texture_max_dim`, `build_materials`, `SPLAT_VERSION`.

**Geometry cache file — L6527**
```gdscript
return "%s/%s.res" % [_geom_dir, kc.md5_text()]
```
where `kc` is composed at L6085: `"%s#%d" % [res_name, lod]`. IN: res name + LOD rung, md5'd because res names contain slashes.

**Heightfield — L1749-1750, L1819, L1829; fingerprint L1722**
```gdscript
var r16_path := "%s/height_game.r16" % cache_dir
var meta_path := "%s/height_game.json" % cache_dir
return "%d:%d:%d+h3" % [n, hash(head), hash(tail)]      # _terrain_key
```
IN the fingerprint: streaming-tree res size, hash of its first 64 KB, hash of its last 64 KB, plus the literal `+h3` epoch. Stored as `{"key": …, "res": …, "world_min": …, "world_max": …, "scale": …}`; a length check (L1761) guards partial writes. Re-read verbatim by `terrain_water` at L3827-3831.

**Ground surface bake — L2038-2041, L2091-2092, L2334-2336, L2414-2415, L2429, L2733/2736**
```gdscript
var dir_splat := "%s/splat" % cache_dir
var meta_path := "%s/layers.json" % dir_splat
FileAccess.file_exists("%s/colormap.png" % cache_dir)
"%s/terrain_layers" % cache_dir
"%s/l%02d_alb.png" % [dir_splat, s]   /   "%s/l%02d_nrm.png" % [dir_splat, s]
PackedStringArray(["%s/idx.png" % dir_splat, "%s/w.png" % dir_splat, "%s/idx_raw.png" % dir_splat])
"%s/%s_alb.png" % [out_dir, tag]      # tag = "ground" | "cliff"
```
IN the validity test: the cache directory path itself (the map is implicit in it) **plus** `layers.json`'s `splat_v == SPLAT_VERSION` (L2055) and the mere existence of `colormap.png`. Content of the install is **not** fingerprinted here — unlike the heightfield, a game patch does not invalidate the splat bake. Stale `l*.png` are deleted first (L2099-2103) and `holes_game.png` is unconditionally removed (L1818).

**Near-field window — L2512, L2566-2568**
```gdscript
var meta_path := "%s/splat/layers.json" % cache_dir
Image.load_from_file(ProjectSettings.globalize_path("%s/splat/idx_raw.png" % cache_dir))
Image.load_from_file(ProjectSettings.globalize_path("%s/splat/w.png" % cache_dir))
```
Gated on the same `splat_v == SPLAT_VERSION`.

**Light and FX files — L4577, L4826**: `"%s/lights.json" % cache_dir`, `"%s/fx.json" % cache_dir`. Keyed on the cache directory alone.

**Material cache `_mat_cache` — L6840-6849**
```gdscript
var ck := "%s|%s|%d|%s" % [scope, BF6Depot.key_hex(state_key), var_hash,
    "" if pal.is_empty() else ",".join(Array(pal).map(func(x): return str(x)))]
if _dress_uv2: ck += "|uv2"
```
IN: scope, hex state key, variation hash, the selected colour-table entries, and (conditionally) whether the surface carries a real UV2.

**Look-share cache `_mat_by_look` — L7808-7814**
```gdscript
return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [basecolor_veg|basecolor, normal|normal_vt,
    emissive, alpha, tint, decal_ca, decal_nrm, smoke_ca, emissive_lit]
```
Plus two derived variants: decal `"%s|g%.4f" % [look, _decal_gloss(consts)]` (L7115), and tile paint `"tp|%.4f,%.4f,%.4f|%.4f,%.4f,%.4f|%s|%s|%s"` over clean colour, aged colour, tilebreaker, `normal_vt`, basecolor (L8726-8730).

**Group key (the string map_data hands out) — L1536 and L5329**
```gdscript
var gkey := "%s|%s|%d" % [res_name, scope, vh]
```
IN: resolved res name, depot scope, live variation hash. `_group_meta[gkey] = [res_name, scope, src, vh]` (L1543/L5332). Decomposed again in `_mesh_for_body` L6071-6076.
**Inconsistency:** `scatter_entries` builds a **two-part** key `"%s|%s" % [res_name, scope]` (L5121) with `_group_meta[gkey] = [res_name, scope, ""]` (L5123) — no variation field, so `m.size() > 3` at L6069 is false and the array is one element shorter than every other producer's.

**Mesh share signature `_mesh_by_sig` — L6809-6821**: `"#".join([kc, var_hash, then per surface: the surface name and the resolved Material's get_instance_id()])`. IN: mesh+LOD, variation, the surface layout, and material identity.

**Other keyed caches:** `_keys_for[kc]` (L6085); `_var_live` `"%s|%s|%d" % [res_name, scope, vh]` (L5537); `_pal_canon_cache` `"%s|%s|%d" % [scope, key_hex, var_hash]` (L7552); `_sib_scopes[dir]` (L6740); `_depot_cache[scope]` (L8863); `_depot_bundles[n.substr(0, at)]` where `at = n.find(SHADERSTATE)` (L1074, L742); `_hidden_cache[res_name]` (L5584); `_edv_tpl_cache[path-lower-minus-.ebx]` (L4612).

**Texture cache `_tex_cache` — L8749-8756**
```gdscript
var an := str(asset).to_lower()          # asset name, ".ebx" trimmed
if cap >= 0: an = "%s@%d" % [an, cap]
```
IN: the asset name and, when overridden, the resolution cap. Probe copies are explicitly `erase`d after answering at L7745, L8110, L8182, L8271, L8322. `_texture_for_asset` (L4983-4999) keys the **same dictionary** with a bare `an` and no cap suffix.

**Texture shape histogram `tex_dims` — L8806**: `"%dx%d f%d %s%s" % [w, h, format, chunk, " mip"]`.

**Surface name (the geometry cache's material index) — L7649**: `"%d@%s" % [key, ",".join(entries)]`, decoded by `_mkey` (L7616) and `_mpal` (L7664).

---

## 4. Dependencies

**Preloads (1):** `highpoly_journal.gd` as `BJournal` (L61). Used at L289 (`BJournal.phase`), L933 and L950 (`BJournal.event`).

**Global classes it calls (never preloaded — resolved by `class_name`):**
`BF6Source` (L66, 700, 732, 782, 954), `BF6Types` (L67, 982-1023), `BF6Walk` (L68, 1008, 5150, 5279, 5299), `BF6MeshSet` (L120, 6158), `BF6Texture` (L121), `BF6Cas` (L435, 441), `BF6Terrain` (L1778-1779, 2073, 2532, 3729-3754), `BF6Splat` (L2078, 2243, 2536, 2589, 2614), `BF6TerrainLayers` (L2145, 3377), `BF6MaterialTree` (L1815, 2195), `BF6Decals` (L2964-3052, 3366), `BF6Ebx` (L3682, 3958, 4328, 4618-4621, 4847, 4915, 4960, 5017, 5600), `BF6Depot` (L4108-4175, 4624-4661, 5544, 5906-5917, 6840-6860, 7552-7558, 8879), `BF6Scatter` (L5097, 5103).

**Plugin-side globals it reaches into:** `HighpolyProfile.add` (L293), `HighpolyLog.human_bytes` (L557) and `HighpolyLog.info/flush` (L5169-5175, L6029-6034), `HighpolyVitals.crumb`/`tick_long` (L2034-2035) and `HighpolyVitals.work_tasks` (L2354, L2419), `HighpolyBcTex.img_bytes` (L8827), **`HighpolyMapContext.vram_mode` / `VRAM_LOW` / `VRAM_FULL` (L6512-6514)** — a reverse dependency from the reader into the UI/context layer, inside the cache-key composition.

**Shaders loaded at runtime by path** (relative to this script's directory): `foliage_wind.gdshader` (L8024), `smoke.gdshader` (L8421), `decal.gdshader` (L8550), `prop_tint.gdshader` (L8583, L8618, L8695). Two more are inline string constants: `ROAD_DECAL_SHADER` (L2800), `ROAD_SHADER` (L2907).

**Scripts that call INTO it** (`addons/highpoly_toggle/`): `highpoly_toggle.gd` (constructs it at L4599, `available()` L4574, `geom_epoch()` L2506/2508, `OPEN_STAGES` L2842-2976, `STAGE_WEIGHT` L2987), `highpoly_mapcontext.gd` (holds `game_source`, reads `PROP_LOD` L2310, `n_blend_slot`/`n_blend_named` L5613, `n_sections`/`n_surfaces`/`n_uv2_surfaces` L5011-5021, writes `drape_step` L1918), `highpoly_lib.gd` (L58 holds the open source), `highpoly_lighting.gd` (L958), `highpoly_water.gd` (L54), `highpoly_previews.gd` (L33), `highpoly_reload.gd` (L370), `highpoly_diagnose.gd`, `highpoly_scatter.gd`, `highpoly_fx.gd`, `highpoly_vehicle.gd`, `highpoly_weapon.gd`, `highpoly_soldier.gd`, `highpoly_flightrun.gd`, `highpoly_bctex.gd` (comment only, L151).

**Tools/tests:** `tools/bench_cold.gd:82`, `tools/probe_bare.gd:16`, `tools/probe_billboard.gd:22`, `tools/probe_decalmats.gd:22`, `tools/test_reloadimpact.gd:52-53`. **`tools/perfrun.py:338-349` regex-scrapes the source text for `const GEOM_EPOCH`** — a textual coupling that breaks if the const is renamed or moved.

---

## 5. Shared machinery it defines

- **`tex_stats` (L774)** — the plugin's texture/material stats dictionary. ~30 keys accumulated across the file (`decoded`, `reused`, `failed`, `no_depot`, `no_key`, `materials`, `var_key`, `var_fallback`, `scope_shipping`, `scope_sibling`, `glass`, `carpaint*`, `tilepaint*`, `smoke`, `decals`, `masked`, `tint_masked`, `smooth`, `bytes`, `over_cap`, `at_cap`, `dest_props`, …). Zeroed in place at L6691-6692 (deliberately not reassigned — it is an inferred typed Dictionary).
- **`tex_dims` (L773)** — shape histogram; **`phases` / `_phase_order` / `timings` (L203, L231-232)** — the phase table the dock forwards into `HighpolyProfile`; **`road_stats` (L2949)**.
- **`_texture_for(file_guid, is_normal, cap)` (L8743)** — the one texture loader anything should use: cache, S3TC compression with the normal-map variant, mipmap generation, cap accounting, byte accounting. `water_texture` (L4188) and `decal_sheet` (L4728) are the public wrappers.
- **`_depot_for(scope)` (L8860)** — the one `ShaderBlockDepot` accessor.
- **`material_for(state_key, scope, var_hash, pal)` (L6831)** and **`_material_any(...)` (L6747)** — the material builders; `_dress` (L6601) / `_dress_only` (L6783) apply them.
- **`mesh_for(group_key, lod)` (L6026)** — the one entry point for prop geometry, taking the `"<res>|<scope>|<vh>"` group key `map_data` hands out.
- **`geom_epoch()` (L877)** — the fold-proof epoch accessor other scripts must use.
- **`_light_record(ent)` / `_light_records(ents)` (L4501/L4555)** — the shared light schema, used by both `lights()` and the placed-object walker so the two cannot drift.
- **`mask_shape(img)` (L7967)**, **`_srgb_of(c)` (L7456)**, **`_var_hash(ov)` (L5501)**, **`_mkey`/`_mpal`/`_bits` (L7616/L7664/L7654)** — static helpers usable without an instance.
- **`describe(am)` / `describe_state(...)` (L5884/L5904)** — the Diagnose Selection contract.
- **`compact_caches(root)` (L5672)**, **`release_caches()` (L5740)**, **`cache_stats()` (L5808)**, **`set_prop_emission(v)` (L8237)** — the memory/teardown contract.
- **`tile_steps()` (L3497)** and **`colormap_image(map)` (L3493)** — cross-layer handoffs so the terrain mesh build and the drape read one table.

---

## 6. Redundancy flags

### Progress reporting reimplemented locally
This file carries its **own complete progress model**, parallel to the UI's single job bar:
- `OPEN_STAGES` (L802) + `STAGE_WEIGHT` (L818) — a stage list and a weight table the reader owns, that `highpoly_toggle.gd:2842-2987` folds in as constants.
- `_prog_stage` / `_prog_done` / `_prog_total` (L1189-1191) plus the frame-pump re-emitter in `open_async` (L1210-1222) — a second dedupe/throttle layer.
- `terrain_surface` wraps the caller's `progress` in its own closure that also fires `HighpolyVitals.crumb` and `HighpolyVitals.tick_long` (L2032-2037) — a *third* progress sink.
- Raw `progress.call(...)` sites scattered across `ensure_placements` (L621-623), `ensure_ground` (L654), `open_map` (L959-1139), `terrain_surface` (L2107-2349).
If there is meant to be exactly one job/progress owner in the UI layer, this file currently owns a competing one end to end.

### Ad-hoc logging instead of one Log/Journal
Five channels, chosen ad hoc per call site: `_say` (L44, ~60 sites), `BJournal.event`/`BJournal.phase` (L289, 933, 950), `HighpolyLog.info`+`flush` (L5169-5175, L6029-6034), `HighpolyProfile.add` (L293), `HighpolyVitals.crumb`/`tick_long` (L2034-2035). `print_phases` (L423) and `print_build_report` (L600) also format multi-page tables as strings inside the reader rather than handing structured rows to a reporter.

### Repeated texture-loading / content-probe snippets
Four near-identical "does this sheet vary" probes, all doing `_texture_for(guid, …, TINT_MASK_PROBE_DIM)` → `_tex_cache.erase("%s@%d")` → `duplicate()` → `decompress()` → stride-sample → compare against `TINT_MASK_MIN_RANGE`:
- `_tint_mask_for` (L8081-8136), stride `/48`, alpha only.
- `_decal_sheet` (L8160-8212), stride `/48`, all four channels.
- `_smooth_varies` (L8259-8290), stride `/32`, alpha only.
- `_decal_sheet_varies` (L8310-8346), stride `/40`, all four channels — **this is `_decal_sheet` minus the texture return**, sharing the same `_decal_tex_cache`, differing only in sample stride (40 vs 48). Two functions can disagree about the same cached verdict.
`_wrap_paint_of` (L7734-7774) is a fifth copy of the probe-then-erase idiom.

### Repeated path/name composition
- **Streaming-tree pick loop, four copies:** L1731-1735 (`terrain`), L2062-2066 (`terrain_surface`), L2522-2526 (`_window_state`), L3719-3723 (`terrain_water`). Identical `snap_res()` scan for `"streamingtree"` + level.
- **Asset-name normalisation (`to_lower`, trim `.ebx`), ~15 copies:** L4612, L4691, L4744, L4842-4843, L4966-4968, L4984-4986, L5012-5013, L5420-5421, L7842-7843, L8015-8017, L8087-8089, L8166-8168, L8265-8267, L8316-8318, L8749-8751.
- **Depot scope index build, two copies:** `open_map` L1069-1076 and `upgrade_catalogue` L738-743 — identical `find(SHADERSTATE)` + `find("shaderblockdepot")` logic.
- **Two texture loaders:** `_texture_for` (L8743) vs `_texture_for_asset` (L4983) — the latter shares `_tex_cache` but skips compression, mipmaps, cap accounting and every `tex_stats` counter.
- **Two depot walks:** `_water_look` (L4094-4115) iterates `_depot_bundles` itself instead of going through `_depot_for`/`material_for`.
- **Two palette loads:** `terrain_surface` L2143-2148 and `_road_layer_albedo` L3377-3382 both construct `BF6TerrainLayers` and call `pal.load(src, level, pidx)`.
- **Two lattice samplers:** `_height_at` (L3566, triangle-exact, tile-adaptive) and the inline `ground_at` lambda in `terrain_water` (L3845-3859, plain bilinear on the same `height_game.r16`).

### Duplicated top-up logic
`ensure_placements` (L614-637) reproduces the walk block inside `open_map` (L1091-1109) including its `note_phase` call; `ensure_ground` (L646-664) reproduces `open_map` L1136-1151. `_dress` (L6601) and `_dress_only` (L6783) duplicate the `alt = _scope_of(...)` computation and the per-surface `_material_any` loop.

### Functions over ~150 lines mixing concerns
- `terrain_surface` **L2017-2473 (~456)** — cache gate, CAS I/O, BC7 decode, palette load, splat composite, base-field rasterise, PNG encoding via two thread-pool group tasks, LUT remap, JSON write, five `note_phase` calls.
- `material_for` **L6831-7257 (~426)** — cache keying, variation key derivation, and nine material families dispatched inline.
- `_mesh_for_body` **L6060-6461 (~400)** — share test, disk cache, CAS read, MeshSet parse, palette-selector analysis, index merging, surface naming, cache save, dressing.
- `open_map` **L912-1158 (~246)**, `roads` **L2957-3187 (~230)**, `terrain_water` **L3713-3930 (~217)**, `_build_map_data` **L1497-1691 (~194)**, `terrain` **L1725-1857 (~132)**, `cache_stats` **L5808-5881**, `release_caches` **L5740-5794** (a hand-maintained list of 24 caches, whose own comment records that seven were missed once already).

### Dead / unreachable / never-read
- `const ROADS_PROJECTED := false` (L2895) makes `ROAD_DECAL_SHADER` (L2800), `_emit_prism` (L3196), `_custom_slice` (L3262), `PROJECT_DOWN` (L2900), `PROJECT_UP` (L2902) unreachable in shipped configuration.
- `var catalogue_mount := false` (L103) — never written by any caller; the `true` branch of L963/L977 is unreachable.
- `static func _ref_guid(v)` (L5041) — defined, called nowhere.
- `const F_SKY_TYPE` (L4886) and `const F_PANORAMIC_TEXTURE` (L4884) — declared, never read (the panorama is found through imports instead, L4924).
- `var n_pal_split` (L5474) — incremented at L6435, read nowhere in `addons/`.
- `mips = 0` (L5834) in `cache_stats` — assigned and never used; the variable is declared at L5810.
- `var t = _albedo_tint({C_SMOKE_TINT: …})` (L8469-8470) in `_smoke_of` — computed and discarded; the raw bytes are re-decoded two lines later (L8471-8476).
- `const CMAP_VERSION` (L1929) is written into `layers.json` but never checked on read — only `splat_v` gates the cache.
- `var catalogue_upgrading` (L708) — the comment itself states it is written in two places in `highpoly_toggle.gd` and read in none.

### Correctness smells worth a second look
- **L5121-5123** (`scatter_entries`): builds a 2-part group key and a 3-element `_group_meta` row where every other producer builds 3-part / 4-element. `_mesh_for_body` L6069 silently falls back to `var_hash = 0`.
- **L3378** (`_road_layer_albedo`) and **L5620** (`_hidden_parts`): both lines contain what look like collapsed line continuations, i.e. a backslash-continuation flattened into tabs. They parse, but they are the only two lines in the file written that way.
- **L1069 / L2061 / L2521 / L3660 / L3718 / L4298**: every hot scan takes `snap_res()`/`snap_ebx()` snapshots against the catalogue republish — but **L3655** (`src.ebx.has(cand)` in `_water_partition`) reads the live dictionary directly, which is precisely the pattern the L674-708 comment says takes the process down.
