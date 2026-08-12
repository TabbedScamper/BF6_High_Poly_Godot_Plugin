# Region map — `highpoly_toggle.gd` (actual length 5589 lines; anchors for commit `16fed50`)

The EditorPlugin / UI layer. `_enter_tree` runs L534-L1985 (~1450 lines) and is the file's dominant structural problem.

## Region map

**L1-L230 — Header, preloads, panel member state.** ~25 const preloads of sibling scripts L57-L86 (+ `Modes` L220). `dock` L17, `win` L20, `tools_btn` L21. `FX_JOB` L80, `LIGHTS_JOB` L81 (job-bar lane keys). Services: `previews` L87, `profiler` L88, `mapctx` L90. Map-Context control vars L96-L137. BF6 gate state L154-L163. **THE JOB BAR members: `jobs` L170, `job_row` L171, `job_bar` L178, `job_pct` L179, `job_what` L180.** Read panel (second progress surface): `read_panel/read_title/read_list/read_note/_read_model` L173-L177. `MODE_SDK/LIGHT/GREY/TEX` L221-L224 (**cross-script const reads from `Modes`**).

**L231-L302 — Mode readers + download-gate registry.** `_mode()` L231 (mirrors onto `LibScript.detail`), `_textured()` L237, `_ctx_allowed()` L251, `_mapctx_tex_mode()` L270, `_gate(c, what, back)` L288, `_refresh_gates()` L296 (modulates alpha, never disables — deliberate L273-282).

**L303-L533 — BF6 gate UI + verification + state crumbs.** `_build_bf6_gate()` L305, `_set_game_dir()` L348, `_apply_bf6_gate()` L373, `gate_interactive()` L393 (static iterative), `_locked(c)` L422, `_crumb_state_change()` L460, `_shed_map_context()` L503, `_range_label(v)` L529.

**L534-L735 — `_enter_tree` A.** Global shader params `bf6_ground_col`/`bf6_ground_rect` L565-575. `jobs` adopted/created L610-614. **Job bar built L615-L653**: `job_row` L615, `job_what` L617, `job_bar` L621-627 (ProgressBar, 0..1, draws own "%  1/2" text), `job_pct` L631-642 (child of the bar), `jobs.changed.connect(_refresh_job_bar)` L643. Read panel L670-685. Range slider L693-730 (radius, merge L710, lights clamp 300m L714, FX range L719, PlacedCull L721).

**L736-L852 — Detail Mode + Collision sections.** `mode_btn` L738-754 (from `Modes.ORDER` L743), `ovr_chk` L761, `previews_btn` L780, `col_chk` L790, `iso_chk` L795, `shape_chk` L810, `col_pick` L823, `col_alpha` L837.

**L853-L1256 — Map Context section (the panel's bulk).** `mapctx_on` L860, `prop_light_on` L887 (reparented into `_detail_chips` L901), `mapctx_backdrop` L906, `mapctx_water` L923, roads has NO chip (comment L942-959; `mapctx_roads` stays null), `mapctx_grass` L961, `mapctx_objects` L976, `mapctx_variant` L1024-1046, `mapctx_fx` L1062 (`_lane(FX_JOB)` L1078), `mapctx_light` L1083, `mapctx_gi` L1100, `mapctx_shadows` L1109, fill slider L1122-1146, photo slider L1155-1177, `mapctx_maplights` L1184 (`_lane(LIGHTS_JOB)` L1204), `mapctx_optimize` L1216 (**pressed=true, visible=false** — always-on, hidden), gates L1237-1249 (`_gate(mapctx_roads,…)` L1244 is a null no-op), `shader_btn` L1251.

**L1257-L1367 — Storage section.** `storage_lbl` L1268, `files_btn` L1285, `MapContextScript.mesh_cache_enabled = true` L1313 + shader-prefs load L1314-1318, `flight_chk` L1328, `purge_maps/purge_btn` L1350-1358, `reset_btn` L1362.

**L1368-L1617 — Log section: log view, markers, pick mode, perf recorder.** `log_count` L1371, `log_view` L1377, `mark_note` L1394 (Enter-pins-to-selection handler L1408-1442), `mark_add` "Drop marker" L1446-1475, `mark_clear` L1476, `mark_fix` L1502, **`diag_pick` "Pick mode" L1552-1562**, `perf_btn` L1573, `save_log/clear_log` L1598-1616.

**L1618-L1695 — Status line, version, scroller, backdrop, deferred boot.** `lbl` L1624 (2 lines fixed, moved to top L1635), `ver_lbl` L1642, `dock_scroll` L1655, `dock_root` L1671, deferred calls L1683-1694 (`Log.hook(_log_line)` L1686).

**L1696-L1985 — Service adoption, signal wiring, the 0.5s heartbeat.** `_take_service` L1699-1711, **`mapctx.status_label = lbl` L1714** (hands the status label to another module), `build_progress` → `jobs.set_activity` L1715-1725, `stage_progress` → `_lane(label)` L1729, `backdrop_progress` lane L1733-1737, **`build_finished` → `_storage_dirty` TWICE (L1750, L1765)** + the real handler L1766-1783, `decal_progress` lane L1760-1764, heartbeat lambda **L1787-L1935 (~149 lines, 13 unrelated jobs)**: Vitals sample L1810, `_read_refresh` L1818, save-guard L1825, crumb L1827, scene change L1830, lighting guard L1833, `mapctx.tick()` L1838, gamemode heal L1851, `tick_lights` L1873, prop lights L1882, zones L1890, ShapeViz L1894, bar clear L1904, image pool reclaim L1917, collision follow L1931. `HighpolyReload.arm()` L1955, `node_added` L1961, `selection_changed` L1963.

**L1987-L2156 — `_settings_snapshot` + `_exit_tree`.** Snapshot L1994. Teardown L2068: soft reopen L2085-2111 (`_capture_ui` L2087, `_keep_service` ×4 L2088-2091), hard exit L2112-2155.

**L2157-L2317 — Startup, save guard, marker meshes, post-build swap.** `_startup()` L2158 (flightrun check L2169, autorun L2172), `_marked_meshes(root)` L2195 (meshes within `HighpolyMarkers.RADIUS` of a marker), `_apply_changes()` L2264 (the scene-stays-stock guard), `_swap_placed_after_build()` L2307.

**L2319-L2420 — Soft-reopen UI capture/restore.** `_capture_ui()` L2334, `_apply_ui(d)` L2353, `_ui_chips()` L2411.

**L2422-L2711 — Soft reopen, live reload, "Check for updates".** `PLUGIN_NAME` L2452, `_reopen_panel()` L2464, `_keep_service/_take_service` L2475/L2490, `_hot_reload()` L2502 (heal L2530-2536, impact match L2565-2607), `_check_updates_now()` L2623 (staged apply L2640-2665, cold-swap decision L2686-2699).

**L2712-L2823 — Window consts, tips, log sink, SDK hide, `_lane`.** `_log_line` L2751 (thread-hops to main L2762), **`_lane(label) -> Callable` L2816 — THE canonical progress-lane factory.**

**L2825-L3076 — Read model, read panel, job-bar refresh.** Static testable model `read_model_new/stage/title/lines` L2840-2895. `CATALOGUE_BAR` L2906. `_read_begin/_read_stage_set/_read_end/_read_refresh` L2916-3019 (weighted overall position L2974-2996 via `STAGE_WEIGHT` L2987; one-live-key discipline L3013-3017). **`_refresh_job_bar()` L3046 → `_refresh_job_bar_body()` L3053** — the ONLY writer of the bar's controls; `BJournal.bar_tick()` L3061; 1 Hz log line L3068-3072.

**L3078-L3212 — UI helpers, sections, backdrop.** `_chip_row` L3095, `_section` L3113, `_save/_restore_section_state` L3131/L3139, `_build_backdrop()` L3154.

**L3213-L3406 — Floating window + dock tab.** `_build_tool_window()` L3213, `DOCK_SLOT` L3256, `_dock_panel()` L3265, `_float_panel()` L3297, layout persistence L3363-3377, `_maybe_play_splash()` L3386.

**L3407-L3682 — Storage measurement, purge, reset, self-update.** `_storage_dirty()` L3431 (2s debounce), `_refresh_storage()` L3441, `_reset_everything()` L3527, `_do_reset()` L3545, `_do_purge()` L3616, `_check_plugin_update()` L3644, `_do_plugin_update()` L3655 (job token L3661, **never calls jobs.report** — bar sits at 0%).

**L3683-L3843 — Scene-change reset, mapctx apply, lighting subs.** `_check_scene_change()` L3687 (~15 control resets L3701-3728), `_apply_mapctx()` L3762 (asked/returned log pair L3794/L3797), `_lighting_subs_enabled()` L3812, `_wants_map_layers()` L3824.

**L3846-L4192 — Async install readers, flag waiter, lighting handlers, auto perf.** `_ensure_placements_async()` L3848, **`_mapctx_rebuild()` L3916 — DEAD (zero call sites)**, `_apply_with_placements()` L3943 (the single chokepoint), `_await_flag()` L4029 (warns at 8s then 30s×n), `_ensure_mapdata_async()` L4052, `_lighting_changed()` L4108, `_lighting_guard()` L4129, `_auto_perf_settings()` L4150 (mesh LOD 4px L4174, thread_model 2 L4180, shadow atlas 2048 L4183, gated by `_perf_applied2` L4156).

**L4193-L4531 — Configure Shaders dialog, Variant row, per-map state.** `_open_shader_dialog()` L4196, `_variant_row_update()` L4273, `_save_mapctx_state()` L4320 (19 keys, called from 19 sites), `_restore_mapctx_state()` L4366 (~165 lines; MODE_SDK→MODE_LIGHT migration L4514).

**L4532-L4838 — Opening the game source, mining gamemodes, catalogue.** `_adopt_open_source()` L4557, `_ensure_game_source()` L4567 (~156 lines; `gs.log_fn` L4608, OOM retry L4670-4686), `_gamemodes_then_catalogue()` L4725, `_mine_gamemodes_async()` L4747 (`MINE_TIMEOUT_MS` 90000 L132/L4775), `_upgrade_catalogue_async()` L4794 (talks to jobs directly L4822-4827 instead of `_lane`).

**L5065-L5276 — Paced placed-object swap, cull helpers, override, previews.** `SWAP_JOB` L5083, `_apply_scene()` L5092 (lane L5116, budget 400ms→clampi(yield*4,250,2000) L5119/L5145; ALSO writes `lbl` "Swapping placed objects: %d of %d" L5132 — duplicate channel), `_cull_radius()` L5158, `_override_toggled()` L5176, **`prop_light_on`/`previews_btn`/`_said_not_map` DECLARED at L5230-5232, ~4400 lines after first use**, `_build_previews()` L5237 (jobs.acquire/report/release L5262-5265).

**L5278-L5589 — Prop lighting, viewport input, PICK MODE, live handlers.** (line numbers pre-v2; grep the names)
- `_set_prop_lighting()`; `PROP_EMISSION_ON`
- `_forward_3d_gui_input()` → body (doors, then variants)
- **`_pick_input` → `_pick_input_body` — PICK MODE V2 (2026-08-12): InputEventMouseMotion at the top = the hover pass (throttled 90 ms + 6 px via `_hover_last`/`_hover_ms` declared beside `_pick_last` ~L95; skipped while any button held or a pick is confirmed; never consumes the event). Tab/Shift+Tab step the ladder on hover OR confirmed focus. Escape is two-stage: first releases a confirmed pick back to hover (`unconfirm`), second clears. Alt+click steps out, same-spot click (6px) drills. A fresh click = `pick` → `focus_on` → `confirm` (bright red) → `edit_node` → `_report_focus`.**
- Marker paths: the note-box Enter handler prefers a CONFIRMED pick (`focus_point()` + `provenance()` into `hp_note_target`) over the selection; a selected MultiMeshInstance3D anchors to `_nearest_instance_point()` (nearest instance to the camera aim), NEVER the group AABB centre (the old center-of-all-look-alikes bug). "Drop marker" also attaches provenance when a pick focus exists.
- `_report_focus()`, `_nearest_instance_point()` (after it), `_collision_changed()`, `_isolate_toggled()`, `_on_selection_changed()`, `_on_node_added()`, `_collision_deferred/_swap_deferred`

## THE JOB BAR — contract

The ONLY ProgressBar in the addon (grep-verified; the other hits are `highpoly_theme.gd` styling). Built L615-653; only writer `_refresh_job_bar_body` L3053 (`job_row.visible = busy` L3055, `check_btn.visible = not busy` L3056).

**To show progress from anywhere in the dock: `_lane(label)` L2816** → returns `func(done,total)` wrapping `jobs.set_activity/clear_activity`. From modules: take a `Callable` parameter, never touch UI (the model to copy is `highpoly_previews.build_all`).

`highpoly_jobs.gd` API: `set_activity(label,done,total)` :76, `clear_activity(label)` :86 (**always pass your own label** — empty clears everyone's), `acquire/report/release` :99/:143/:149 (serialized jobs), `busy/ratio/active_label` (read side), `changed` signal. `ratio()` returns the LEAST-finished lane, so retire finished stage keys (L3013-3017).

### Duplicate progress surfaces (ranked; the consolidation list)
- **D1 (biggest): the read panel** L670-685 + `_read_refresh` L2949-3019 — a full second progress display beside the bar showing the same weighted number it pushes into the bar at L3017.
- D2/D3: `lbl` written as a live counter (L5132) and handed to mapctx as `status_label` (L1714) — same fractions the bar already shows.
- D4: `storage_lbl` as a spinner (L1271, L3445, L3484, L3626, L3553).
- D5/D6: `previews_btn` (L5248-5267) and `update_btn` (L3647/L3679) captions as progress.
- D8: `job_bar.indeterminate` set false twice (L2946, L3019), never true — vestigial.
- D9/D10: 1 Hz bar log line L3068-3072; `BJournal.bar_tick()` L3061 (intended, separate metric).
- D13: three hand-rolled worker-poll pumps L3893-3899, L4083-4089, L4819-4824.
- D14: four inline lane lambdas re-implementing `_lane` (L1722, L1733, L1760, +catalogue) — only `stage_progress` L1729 uses `_lane`.
- Other files: `mapcontext._report_progress` (4 channels), 4 separate progress signals needing 4 wirings.

## Settings

EditorSettings project metadata: `highpoly/shape_outlines` L816/L3084; `highpoly/open_sections` L3136/L3140; `highpoly/tools_seen` L3357; `highpoly_mapctx/<MAP>` 19-key dict L4320-4353 (dead keys: `maptile`, `optimize`, `_mesh_cache`); `highpoly_mapctx/_shaders` L4206/L1315; `_perf_applied2` L4156.
ProjectSettings (one-shot, L4150): mesh LOD threshold 4.0, thread_model 2, directional shadow 2048.
Editor layout ConfigFile: `HighPoly/win_rect|win_open|docked` L3363-3377.
Env vars: `BF6_MESH_TRACE`, `BF6_PERFRUN` (flightrun), `BF6_AUTORUN`.
Statics mirrored: `LibScript.detail/build_epoch/game_source`, `MapContextScript.mesh_cache_enabled/colormap_*/show_fx_cards`, `LightingScript.lights_range/interior_fill/prop_lighting/game_source`, `GameSourceScript.prop_emission`, `mapctx.want_lights/want_fx/job_queue/status_label`.

## Cross-script const reads (fold hazards)

- `Modes.SDK/LIGHT/GREY/TEX` re-exported as this file's consts L221-224 — **folds twice**.
- `HighpolyGameSource.OPEN_STAGES` L2842-2976 and `STAGE_WEIGHT` L2987 — a stage renamed there silently breaks the read panel AND the bar denominator.
- `HighpolyMapContext.NODE/CACHE/PROPS_CACHE`, `SdkHide.*_SUFFIX`, `HighpolyMarkers.RADIUS` L2230, `HighpolyLib.HP_NODE`/`Tier.*`, `Log.Level.*`.
- Correct pattern noted at L1901-1903: `mapctx.build_job` read as a property, never copied.

## Redundancy highlights

Dead: `_mapctx_rebuild` L3916; `mapctx_roads` (null everywhere); `job_bar.indeterminate`; saved keys `maptile`/`optimize`/`_mesh_cache`; `_ready_names` L187; garbled comment L39-43.
Duplicated: `build_finished`→`_storage_dirty` twice (L1750/L1765); two `_swap_busy` wait idioms (`_await_flag` vs raw while L4057); two number-groupers (`_grouped` L3031 vs `_fmt_n` L3414); panel-reset written twice (+`_shed_map_context` a third); the 12-line chip fast-path/slow-path pattern ×4 (L862, L908, L925, L978); `1.0e9 if >= 3500` sentinel ×4.
Oversized: `_enter_tree` ~1450; heartbeat lambda ~149; `_restore_mapctx_state` ~165; `_ensure_game_source` ~156; `_read_refresh` ~71 (the D1 split candidate).
Suspected corrupted line joins (tab where a `\` was): L1519, L2219, L2230, L2576, L2604, L3076, L3490, L2782; embedded newlines in literals L1769-1770, L3497-3498.
