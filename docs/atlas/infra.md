# Infrastructure layer — 16 files, commit `16fed50`

Actual line counts: autorun 1327, jobs 191, journal 153, log 398, profiler 1054, profile 360, reload 454, updater 478, store 589, vitals 565, diagnose 826, census 834, flightrun 1548, flightpath 112, gamedir 158, lib 982 — 10,029 total.

The two hubs: `highpoly_toggle.gd` (165 refs to these classes) and `highpoly_mapcontext.gd` (57). Most of these files have exactly one caller.

## ★ THE LOGGING CONTRACT (the "how to instrument" reference)

Decision table:

| you want to record | use | lands in |
|---|---|---|
| a fact a user should be able to send you | `HighpolyLog.info/warn/error` | `highpoly-session.log`, panel, saved log; warn/error also Godot Output |
| a fact that must survive an editor kill | `HighpolyProfiler.crumb(stage, detail)` | `breadcrumbs.txt`, flushed per line, worker-safe |
| a per-phase duration with install-read attribution | `BJournal.phase(label, ms, items, note, since)` | `build_journal.txt` |
| a button press / job queued | `BJournal.event("ui"/"job"/"audit", …)` | same |
| a duration summed by name over a recording | `HighpolyProfiler.span(name, ms)` | recording's TIME BY PHASE (main thread only) |
| a per-frame microsecond bucket | `HighpolyProfile.begin/end(name)` | `HighpolyProfile.report()/stats()` |
| "which phase runs now" for the stall detector | `HighpolyVitals.crumb(what)`, `IDLE`-prefixed when done | vitals report + perfrun idle check |
| "still going" inside a long main-thread loop | `HighpolyVitals.tick_long(what, done, total)` | log, flushed |
| a fact an OUTSIDE TOOL must read while the editor still runs | `HighpolyLog.event(ev, d, lvl, cid)` | `highpoly/events.jsonl`, one JSON object per line, flushed per line |
| the current state of everything | `HighpolyLog.write_state(d)` (dock heartbeat assembles it) | `highpoly/state.json`, rewritten whole |
| which RULE a resolver applied | `gs.decide(mesh, state, var, surface, mat, rules)` | `mapcontext/<MAP>/decisions.jsonl` at build end |

**The `.tmp`-under-lock rule** (log.gd:357-370, profiler.gd:196-220): Godot's FileAccess writes through a sibling `.tmp` and renames on close. While the editor runs, `highpoly-session.log` on disk is the LAST cleanly-closed session.

**...and the dodge** (log.gd, `_ev_open`): the `.tmp` dance belongs to WRITE mode. `READ_WRITE` opens the real path in place, so `events.jsonl` is created once in WRITE, closed, then reopened READ_WRITE and appended to with a flush per line. That is the entire reason the event stream is readable from outside a live editor while the session log is not. `tools/test_events.gd` asserts it by reading the file back mid-session, so the property cannot regress quietly. `state.json` deliberately does the opposite: it is written whole through a `.new` and renamed, because a reader must never catch a half-written object. `Log.save()` builds from the in-memory ring, never re-reads the file. `crumbs_begin()` (profiler:192-230) is the only code that salvages a crashed session's `.tmp`. Anything that must survive a hard kill goes through `HighpolyProfiler.crumb()` (flushed every write) or is followed by `HighpolyLog.flush()`.

Three "crumb" mechanisms exist — `HighpolyProfiler.crumb` (file, crash-safe), `HighpolyVitals.crumb` (one static string, stall detector), `BJournal.event` (row table). Same word, unrelated systems.

## highpoly_log.gd (398)
`class_name HighpolyLog`, static. **Hazard: preloaded by 9 files while holding mutable statics** — violates the profile.gd:29-32 rule (live reload leaves two script copies; a preload holder writes the copy nobody reads). API: `hook(cb)` :72 (panel live feed), `debug/info/warn/error` :101-104 (debug dropped unless `highpoly/verbose_log`), `started/finished` :110/:115, `human_ms/human_bytes` :126/:132, `err_code` :140, `flush()` :147, `lines/error_count/warning_count` :193-195, `header()` :238, `save()` :347. Flush policy: batch 20; ≥WARN immediate. Ring `MAX_LINES 800`.
**Bugs found:** :381 the "previous session" guard prefix-matches EVERY session header so the PREVIOUS SESSION block is never appended; :168/:241 hardcode `res://addons/highpoly_toggle` while reload/updater derive it — nested installs silently lose staleness check + version.

## highpoly_journal.gd (153)
`class_name HighpolyJournal` — **class_name never used; all 5 callers preload as BJournal** (same mutable-static hazard as Log). Public statics `res_calls/res_bytes/chunk_calls/chunk_bytes` bumped by bf6_source under `_mx`. API: `clear` :46, `bar_tick` :58 (only toggle:3061), `mark` :67, `phase` :81 (only gamesource:289 + mapcontext:324), `event` :98, `report` :108 (BAR SILENT detection :134-136), `save` :141 (jobs:170 on queue drain; flightrun:1531).

## highpoly_jobs.gd (191)
`class_name HighpolyJobs`, Node, instantiated once by the dock. The ONE progress model: `changed` signal :15, `busy/active_label/ratio` :38/:54/:60, `set_activity` :76, `clear_activity` :86, `acquire` :99 (await, serialized), `report` :143, `release` :149 (saves journal when queue empties), `reset` :177. Only two callers ever acquire (plugin update :3661, previews :5262) — the download queue is nearly vestigial; the activity/bar half is the live feature.

## highpoly_profiler.gd (1054) vs highpoly_profile.gd (360)
Disjoint measurement domains: profiler = session recorder (0.25s sampler, ms spans, scene attribution, CSVs under `user://highpoly/perf-<stamp>*.csv`, always-on crash breadcrumbs); profile = per-frame MICROsecond self-time buckets (`begin/end/add`, `stats()` consumed by flightrun:620). Near-identical names are the hazard.
Profiler API: `event` :92, `crumbs_begin/crumb/crumbs_end/last_session_end` :192/:241/:261/:275, `mark` :298, `span` :305, `lane_open/lane_close` :345/:359 (called only from jobs), `start/stop` :383/:407, `mapctx_transfer` :707; statics `_range_culled` :639 + `_tris` :669 reused by census.
**Dead:** `sync` :76 + `_download_snapshot` :464 + whole DOWNLOADS report + 7 CSV columns (highpoly_sync.gd is deleted by the updater); `state_provider` :77 never assigned; `SHADOW_PASSES := 4` :48 hardcoded (census derives it properly at :454); `OWNERS`/`MAPCTX_PARTS` duplicate census `ROOTS`/`PARTS` with different matching.

## highpoly_vitals.gd (565)
`class_name HighpolyVitals`, static, driven by the dock heartbeat (`sample()` toggle:1810). `free_mb` :95, `pressure()` :110 (TIGHT 2048 / CRITICAL 900 MB), `crumb/crumb_is_idle/crumb_age_ms` :158/:172/:186, **`work_tasks(items, cores)` :219 — THE thread policy: min(items, cores-2)**, `tick_long` :228 (10s threshold then Log.flush), `sample` :253 (stall detector = heartbeat lateness, keeps worst 40), `machine` :363, `report` :392. Budgets :85-89: heap 8192 MB, VRAM 5120 MB.

## highpoly_reload.gd (454) — the staged-deploy law
`class_name HighpolyReload`, static. `STAGED_DIR "user://highpoly/staged"` :90. Rule (:74-89): nothing writes `res://` while the editor is open; deploys stage FLAT `.gd`/`.gdshader` files there.
"Check for updates" sequence (toggle:2623): GitHub check → if `staged_count() > 0` refuse unless `crumb_is_idle()` (:2642) → `apply_staged()` :113 → `pending()` :194 → any .gd moved = `cold_swap()` :306 (disable plugin, 2 frames, CACHE_MODE_REPLACE, re-enable) else `_hot_reload` (reload_code :225 shaders-first toggle-last, `heal_new_members` :415, `impact()` :384 → materials bumps `LibScript.build_epoch`; geometry refuses).
`plugin_dir()` :70 duplicated verbatim in updater :227.

## highpoly_updater.gd (478)
`class_name HighpolyUpdater`, static. `_fetch` :56 (4 attempts, backoff, stall watch `STALL_SECS 45`), `plugin_version` :230, `is_newer_version` :243, `github_latest` :283, `check_plugin_update` :333, `sweep_removed` :371 (`REMOVED_FILES`: highpoly_migrate/sync/jobbars/turbo), `update_plugin` :391 (zip → hash-compare → extract → `cold_swap`). **Dead:** `fetch_to_file` :145 (duplicate of _fetch), `remote_etag` :197.

## highpoly_store.gd (589)
`class_name HighpolyStore`, static. Live: `ctx_scan` :57, `load_ctx_scene` :93, `ensure_dir` :123 (generic helper stranded here; used by profiler+updater), **`load_external_glb` :332 (the runtime GLB→PackedScene workhorse: WebP ext, corrupt-file detect+delete, tangents, S3TC)**, `ensure_scene_tangents` :380 (worker-safe) / `compress_scene_textures` :396 (main-thread), `thumb_path` :203, `prune_keep` :567. Paths: `ROOT user://highpoly`, `MODELS_DIR` (dormant), `THUMBS_DIR` (live), `CTX_PROPS user://mapcontext/_props`, `INDEX_PATH store.json` (dormant).
**Dead:** `remote`/`mesh_remote` :112/:116 never assigned (doors:14 and previews:118 read a permanently empty dict); the whole ingest/index API.

## highpoly_diagnose.gd (~910 after pick v2) — Pick mode's engine
`class_name HighpolyDiagnose`, static. Driven entirely by the dock (see toggle.md pick region).
**Pick mode v2 (2026-08-12, Revit-style two-stage selection):** `_confirmed` static + two overlay materials via `_red(hard)` — light red (hover/Tab preview) and bright red (confirmed). `hover(camera, pos, root)` re-picks on mouse moves at `HOVER_TRI_BUDGET 80000` in `pick`'s hover_mode: candidates whose box CONTAINS the camera are dropped (the terrain/roads/water mega-meshes sort first at t=0 and starved the budget — hover looked dead on map objects while clicks worked), and any mesh over `HOVER_MESH_CAP 40000` tris previews by its box via the fallback instead of being soup-built per move (`_tri_estimate` reads index lengths, no arrays). Hover never replaces a confirmed focus and keeps the Tab ladder when the hit stays on the same node+instance.
**Hide/unhide (2026-08-12):** the dock's "Hide picked" button or H in the viewport hides the highlighted object (the right-click variant existed for one commit and was removed: it collided with freelook) — a node goes `visible = false`, a MultiMesh instance is zero-scaled with its original transform kept; restore data lives in NODE METAS (`hp_pick_hidden`, `hp_pick_hidden_insts`) so a plugin reload cannot strand things hidden. Owned (user) nodes are REFUSED — hiding writes `visible`, which serializes. `hide_focus(root)` / `unhide_all(root)` (meta sweep; returns `{nodes, insts, gated}` where gated names invisible ancestor groups) / `_note_gate`. The dock's Unhide button maps gated group names to layer chips via `_layer_chip_name` — the "is its mode on" check.
**The click confirms the hover (2026-08-12):** a left click with an unconfirmed hover focus CONFIRMS it and never re-picks — hover and click run the pick with different rules (hover_mode), so a fresh full-budget pick on the click could resolve to something BEHIND the highlight. A full pick runs only when no hover focus exists (or a confirmed one is being replaced by clicking elsewhere). `confirm(root)` / `unconfirm(root)` / `is_confirmed()` switch the stage. `provenance(gs)` renders the focused thing's identity as one line (mesh res, scope, variation, surface+state key, instance, world pos) — what a pinned note carries into the saved log.
- `clear()` — restores every tinted node's own `material_overlay`, resets `_confirmed`.
- **`pick(camera, pos, root, tri_budget := TRI_BUDGET)` — two-phase raycast: AABB entry-distance sort, then triangles, stop when a hit beats the next box.** Budgets `TRI_BUDGET 400000`, `BIG_SURFACE 300000` (AABB-only), `SOUP_KEEP 12`.
- `focus_on(hit, root)` — builds the batch/object/surface ladder, ALWAYS unconfirmed (confirming is the click's job).
- `step(delta, root)` — Tab drills in, Shift-Tab out.
- `focus_label(gs)` (PICKED prefix + next-action hint; `_surface_tag` names a part by its bound texture), `run(root, gs, mapctx, note)` — the full resolution-chain report (picked → selected → camera aim).
Duplicates: `_ray_box` ≡ `HighpolyLib._ray_aabb`; `_collect` another walk.

## highpoly_census.gd (834)
`class_name HighpolyCensus`, static; one addon caller (flightrun:625 `take(croot)`). Prices the scene as the GPU charges: surfaces, distinct materials/shaders, casting surfaces × MEASURED cascades (`_directional_cascades` :454), dedup recovery, reconciliation vs the engine draw counter. `report()/lines()` :676/:689 reachable only from tools/. Third scene-walk implementation exists in autorun `_surface_census` :902.

## highpoly_flightrun.gd (1548) — ★ THE bench harness
`class_name HighpolyFlightRun`, static; only preloads Log (deliberate isolation). Entry toggle:2169: `BF6_PERFRUN` env (path to session JSON or bare tag). Inert when unset. Driven externally by `tools/perfrun.py`.
Phases: scan :208 → open :247 → dock_sync :300 → configure :315 → build :356 → assert :485 → settle :535 → flight :597 → census :622 → hlod probe/ab :643/:684.
Asserted rules (:26-38): culling OFF (`NO_CULL_SLIDER 3500`, `mapctx.radius == 1e8` :1111-1126 — failure aborts); headline = `frames_under_60` + 1% low, never the mean (`MS_60/MS_30` absolute :67-68). Refuses headless (:201-206).
Outputs: report `cfg["out"]` default `user://perfrun_<map>_<tag>.json` :163 (**NOT perfrun_history.json — that file lives in the pipeline repo, not here**); heartbeat `.progress` :165; flight path `user://bf6_flightpath_<base_map>.json` :161; journal `<out dir>/build_journal.txt` :1541. Report banked twice: `_bank_report` :1323 (partial, pre-HLOD) then `_finish` :1334.
`_summarise` :832-939: frames_under_60/30, fps_1pct_low, worst_ms(+where), stationary-vs-moving stutter split, draw peaks, full per-frame arrays.

## highpoly_flightpath.gd (112)
`class_name HighpolyFlightPath`, static. Records editor camera at 20 Hz → `user://bf6_flightpath_<map>.json` (basis as 9 floats). `start` :39, `stop` :58, `MAX_SAMPLES` 20*60*10. Two consumers parse it with two different parsers (flightrun:1395, autorun:1246).

## highpoly_gamedir.gd (158)
`class_name HighpolyGameDir`, static. `verify(path)` :81 ({ok, layout, oodle, why}), `autodetect()` :135 (saved → CANDIDATES → Steam registry → all libraryfolders), `_settings()` :44 headless guard (only instance-testing EditorInterface works). `_steam_root` :114 via `reg query`.

## highpoly_lib.gd (982) — the shared-helper file
`class_name HighpolyLib`, static. The addon's namespace: **`HP_NODE "_HIPOLY_PREVIEW"` :19, `TEXTURED_LAYER 1<<18` :31, `COL_NODE "_COLLISION_VIS"` :32, `VARIANT_META` :722.** Mutable statics: `build_epoch` :56, `game_source` :65 (untyped on purpose), `use_legacy`, `detail`.
Catalogue: `rescan_objects/known/_match_key/match_key_public/scene_keys` :106-221. Apply: `restore` :236, `plan` :281, `apply/apply_names` :302/:312, `_asset_id` :339 (`game://`/`soldier://`/`weapon://`/`vehicle://`), `apply_one` :498, `_set_textured` :601 (size-gated shadow), `invisible_material` :664 (alpha-scissor pickable-but-invisible). Variants :735-772 (`declared_variants` :758 is a stub returning []). Geometry/picking: `in_overlay` :774, `_global_aabb` :804, `_ray_aabb` :822, **`proxy_under(camera, pos, root)` :847**, `_merged_aabb` :897, fit :924-982.
Duplication: the "skip our own overlays" predicate inline ×6 while `in_overlay()` exists; 9 stack-walks with the same skeleton; `_ray_aabb` ≡ diagnose `_ray_box`.

## highpoly_autorun.gd (1327)
`class_name HighpolyAutorun`, static; `BF6_AUTORUN` env; **~60% duplicate of flightrun** (17 functions duplicated, 5 verbatim: `_scene_for/_find_scene/_windows/_engine/_say`). Unique value: the layer sweep :610-717 (per-layer off + re-fly + delta, incl. engine-floor rows), foliage screenshot :1163, build-rate sampler `_rate` :736. Neither harness is deprecated in code.

## Cross-file observations
- class_name-vs-preload rule (profile.gd:29-32): mutable statics must be reached via class_name. **Violated by Log (9 preloads) and Journal (5 preloads, class_name unused)** — the highest-value inconsistency in the plumbing, given hot reload is the headline feature.
- Four "how expensive is this scene" walkers: profiler `_attribute` :548, census `take` :142, autorun `_surface_census` :902, diagnose `_aimed` :724.
- Helpers duplicated across files: ray/AABB slab test ×2; plugin_dir ×2 (+2 hardcodes in log.gd); ensure_dir in store (journal calls make_dir_recursive directly); Performance snapshot ×5; find-scene-by-map ×2; dialog dismissal ×2; `_say` ×2.
- Dead subsystems still carried: the download pipeline (profiler.sync, store.remote/index API, updater.fetch_to_file/remote_etag, most of jobs' acquire queue), profiler.state_provider, census.report/lines, lib.declared_variants, log.set_verbose, autorun's FlightPath preload.
