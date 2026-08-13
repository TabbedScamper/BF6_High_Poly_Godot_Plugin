# MAP.md — BF6 High-Poly Preview: the Atlas

Read this file FIRST, every session, before touching any code. It is the
navigation document for the whole plugin: what lives where, what the
invariants are, and which shared machinery already exists so it never gets
rebuilt by accident.

**Anchor convention:** anchors are function/const NAMES plus line numbers as
of commit `16fed50`. The name is the durable part (grep it); the line number
is a hint that rots. **Any structural change updates this file (and the
touched `docs/atlas/*.md`) in the same commit.** A MAP that lags the code is
worse than none.

**Deep files:** `docs/atlas/` — `gamesource.md`, `mapcontext.md`, `toggle.md`,
`readers.md`, `infra.md`, `features.md`. Full region maps, cache-key
inventories, format knowledge, redundancy flags. This file is the index;
those are the territory.

**Repo:** `C:\PortalSDK\GodotProject\User_Created\tools\bf6-portal-highpoly-preview`
(`.gdignore`-guarded). **Deployed copy:** `C:\PortalSDK\GodotProject\addons\highpoly_toggle`
— never edited directly; produced by the gated deploy.

Size at `16fed50`: 65 scripts, ~56k lines. The big three: `highpoly_gamesource.gd`
8,883 · `highpoly_mapcontext.gd` 7,544 · `highpoly_toggle.gd` 5,589.

---

## 1. The laws (each of these has already burned us once)

**Process**
- L1. Never force-close the user's editor. No taskkill by image name, ever.
  Deploy only when the user says the editor is closed; otherwise stage to
  `user://highpoly/staged` and let them press "Check for updates"
  (`highpoly_reload.gd:74-131` is the mechanism).
- L2. Never write under `GodotProject/` outside this repo while the editor is
  open — hot-reload of duplicate classes crashes it ("Bad address index").
- L3. Every change goes through the gate (`gate_sandbox.py`) before deploy or
  stage. Verify the DEPLOYED SET, not the single file.
- L4. Research before optimising: search existing measurements, the research
  databank (`PortalSDK\_Research`), and the web first.
- L5. Use real game data, never hardcode. Every visual fact is read from the
  install or a mined table.
- L6. No AI attribution anywhere public (commits, releases, README).
- L7. No em dashes in user-facing strings.
- L8. Releases: tag `vX.Y.Z`, asset `highpoly_toggle.zip` rooted at
  `addons/highpoly_toggle/`, 7-Zip, `plugin.cfg` version == tag. Users run
  NEWER Godot than the 4.6.3 we gate on.

**Performance**
- P1 (RULE 1). Distance culling stays OFF: range slider max ⇒
  `radius = 1e8/1e9`. The bench ASSERTS this (`flightrun _assert_config`).
  Target: steady 60+ fps, everything on except FX.
- P2. STUTTER BEATS AVERAGE. Headline = frames under 60 + 1% low, never the
  mean. Bench twice — all failure is first-encounter warm-up.
- P3. Draw calls are the root cost (~2.6 µs each). The LOD ladder is a
  vertex-MEMORY lever, not a draw-call lever.
- P4. Bench runs poison each other — restart between comparisons.
- P5. The SDK runs a separate render thread (`thread_model=2`): heavy builds
  die silently there; GPU validation stops it.
- P6. Thread policy: `HighpolyVitals.work_tasks(items, cores)` = cores − 2.
  **One read worker at a time** (two ensure_ground workers crashed the build).

**Correctness**
- C1. Cache keying: ANY variable that changes baked output must be in the
  cache dir/suffix or the setting silently no-ops (bitten twice: PROP_LOD,
  VRAM_LOW). Key inventories live in each atlas file.
- C2. Cross-script `const` reads FOLD AT PARSE TIME. Live values need a
  static func (`geom_epoch()`), not a const. Known folds — fix or respect:
  `mapcontext:2310` reads `HighpolyGameSource.PROP_LOD` (keys sidecars!);
  `mapcontext:1069` `TEXTURED_LAYER := HighpolyLib.TEXTURED_LAYER` (a const
  of a const — folds hardest); `toggle:221-224` re-exports `Modes.*`;
  `toggle:2842-2987` `OPEN_STAGES`/`STAGE_WEIGHT`; `tools/perfrun.py:349`
  regex-scrapes `const GEOM_EPOCH` from source text.
- C3. Packed arrays are VALUES: `acc[0].append_array(v)` appends to a
  temporary. Pull the local out, write it back.
- C4. Mutable statics must be reached via `class_name`, never a preload
  (`highpoly_profile.gd:29-32` states the rule; a live reload leaves two
  script copies and the preload holder writes the one nobody reads).
  **Currently violated by `HighpolyLog` (9 preloads) and `HighpolyJournal`
  (all 5 callers preload it).**
- C5. `PackedScene .res` is NOT byte-stable — never a correctness oracle. The
  walk's oracle is the placements fingerprint (SHA-256 over mesh path + 12
  transform floats per row, `bf6_walk.gd:933`).
- C6. UV law (dfanz0r + census over 11,875 meshes): UV0 fitting 0..1 IS the
  unwrap — never redirect it (flat red/black impostors). A real second
  unwrap (declB TC4 on its own stream) exists on 0.60% of sections, all
  doors/panels. `bf6_meshset.gd:331-371`.
- C7. Never transform-write a scaled object; move by delta.
- C8. Instrument the SINK: decide which log line reports a counter before
  adding it. The decal projector is the model — stats dict in the module,
  reporting in the caller (`mapcontext:6944-7027`).
- C9. The cache staleness ladder: "the fix did not work" is usually a stale
  cache from before the fix. Layers: geom cache epoch (`_g8` dirs), baked
  sidecars (`.baked5*`), material cache, editor-held state.
- C10. Source concurrency (`bf6_source.gd:452-591`, each with a crash log):
  never grow a live Dictionary another thread iterates; a swap "in one
  assignment" is not atomic; build privately, publish on the main thread,
  guard with `_pub_mx`. Hot scans use the `snap_*()` accessors, never the
  live members.
- C11. Godot FileAccess writes through a sibling `.tmp` and renames on close:
  while the editor runs, the on-disk session log is the PREVIOUS session.
  Crash-surviving facts go through `HighpolyProfiler.crumb()` (flushed) or
  are followed by `Log.flush()`.

---

## 2. Shared machinery — USE THESE, NEVER RECREATE

| Need | Use | Never |
|---|---|---|
| Progress in the dock | `_lane(label)` (toggle:2816) → hand the Callable down | a local ProgressBar / inline lane lambda |
| Progress in a module | take a `progress: Callable(done,total)` param (model: `previews.build_all`) | touching UI, print, a file |
| The bar itself | `jobs.set_activity/clear_activity` (highpoly_jobs.gd) — ALWAYS pass your own label | `clear_activity("")` (clears everyone) |
| User-visible fact | `HighpolyLog.info/warn/error` | `print()` |
| Crash-surviving trail | `HighpolyProfiler.crumb(stage, detail)` | Log alone |
| Build audit/phase row | `BJournal.event` / `BJournal.phase` | ad-hoc tables |
| Phase timing in a recording | `HighpolyProfiler.span(name, ms)` | hand-rolled tick deltas |
| Per-frame µs buckets | `HighpolyProfile.begin/end(name)` | — |
| Stall-detector context | `HighpolyVitals.crumb(what)` (+`IDLE` prefix when done) | — |
| Long-loop "still going" | `HighpolyVitals.tick_long(what, done, total)` | — |
| Worker count | `HighpolyVitals.work_tasks(items)` | hardcoded thread counts |
| Benching | flight harness (`BF6_PERFRUN` + tools/perfrun.py) | eyeballing fps |
| Texture from the install | `gs._texture_for(guid, is_normal, cap)` | a second loader |
| Depot access | `gs._depot_for(scope)` | walking `_depot_bundles` |
| Prop geometry | `gs.mesh_for(group_key, lod)` | parsing MeshSets directly |
| Materials | `gs.material_for` / `gs._material_any` | building StandardMaterial3D ad hoc |
| GLB at runtime | `HighpolyStore.load_external_glb` | GLTFDocument inline |
| One Light3D | `HighpolyLighting.make_light(L)` | per-site construction |
| mkdir | `HighpolyStore.ensure_dir` | raw DirAccess |
| Overlay membership test | `HighpolyLib.in_overlay(node)` + `HP_NODE`/`COL_NODE`/`NODE` consts | a fifth spelling of the skip set |
| Ray vs AABB | `HighpolyLib._ray_aabb` | another slab test |
| Orphan-proof layer clear | the name-`contains` sweep, canonical in `HighpolyFx.clear` (fx:104) | `get_node_or_null` (misses orphaned twins) |
| Epoch reads | `HighpolyGameSource.geom_epoch()` | the const (folds) |
| Machine-readable event | `HighpolyLog.event(ev, d, lvl, cid)` → events.jsonl | a second log file |
| "Where am I" snapshot | `HighpolyLog.write_state(d)` from the dock heartbeat | polling from outside |
| Which rule fired | `gs.decide(mesh, state, var, surface, mat, rules)` | leaving it implicit |

---

## 3. File index (one line each; full contracts in docs/atlas/)

### The big three
- **highpoly_gamesource.gd (8,883)** — the READ side: install → map_data + meshes + materials + per-map cache files. Never touches the scene tree. → atlas/gamesource.md
- **highpoly_mapcontext.gd (7,544)** — the BUILD ORCHESTRATOR: `_apply_body` lays terrain → roads → water → skyline → props; owns `user://mapcontext` caches, `_apply_radius` streaming, `tick()`. → atlas/mapcontext.md
- **highpoly_toggle.gd (5,589)** — EditorPlugin: the whole dock UI, THE job bar, settings, update/reload wiring, pick-mode input, heartbeat. → atlas/toggle.md

### Readers (bf6_*, 9,103 lines) → atlas/readers.md
- bf6_source (914) the mount + caches + partition index (concurrency laws live here)
- bf6_walk (1,014) the placement walk (transform/name-hash laws, light join, leaf rule)
- bf6_ebx (539) RIFF-EBX + deserializer (signed PointerRef, flat bool arrays)
- bf6_types (347) type layouts read from the exe (0xFFFF sentinel, SP≠MP DBs)
- bf6_meshset (658) MeshSet → arrays (decl laws, UV law, part indices)
- bf6_texture (395) TextureResource → Image (w@22/h@24, chunk-split capping, fmt fixes)
- bf6_depot (325) ShaderBlockDepot (state-key join, slot hashes)
- bf6_splat (1,285) terrain block 1 (pages/tiles/composite; inlined `_insert`)
- bf6_terrain (614) heightfield (0xFF blocks, reversed paired chunks, pad border)
- bf6_materialtree (434) blocks 7/8 (nibble-RLE, pair entries, hard-ground mask)
- bf6_terrainlayers (375) the layer palette chain (17 slot hashes, level-matched depot)
- bf6_decals (470) TerrainDecals roads (two framings, vertex layout, anchor scan)
- bf6_toc (255) merged TOCs (BE, Huffman names, reversed chunk guids)
- bf6_bundle (208) bundle segments + asset tables
- bf6_cas (258) CAS blocks + Oodle (guard nibble 7, multi-block refs)
- bf6_container (276) DICE header, DbObject, find_game, CasLocator
- bf6_atlas (273) flipbook atlas headers · bf6_scatter (143) scatter DB · bf6_mvdb (320) **dead in addon**

### Infrastructure (10,029 lines) → atlas/infra.md
- highpoly_log (398) session log · highpoly_journal (153) build journal (BJournal)
- highpoly_jobs (191) THE progress model · highpoly_profiler (1,054) session recorder + crash crumbs
- highpoly_profile (360) per-frame µs · highpoly_vitals (565) machine truth, stalls, work_tasks
- highpoly_reload (454) staged deploy / hot reload / cold swap · highpoly_updater (478) GitHub self-update
- highpoly_store (589) GLB loader + thumbs (+dead index) · highpoly_lib (982) overlay apply + shared vocabulary (HP_NODE…)
- highpoly_diagnose (826) pick/inspect engine · highpoly_census (834) scene pricing
- highpoly_flightrun (1,548) THE bench · highpoly_autorun (1,327) legacy bench (~60% duplicate)
- highpoly_flightpath (112) camera recorder · highpoly_gamedir (158) install discovery

### Features → atlas/features.md
- decalproject (641) road-decal projector (receiver shapes + stats contract)
- lighting (1,390) sun/sky/env/zones/fixtures · fx (877) live emitters · water (306)
- markers (417) fault markers (report = the point) · gamemode (495) + gmmine (513)
- scatter (808) ground scatter · bctex (498) texture sidecars + pool
- hlod (617) OFF · rsprops (216) OFF · occluders (128) OFF · placedcull (324) on-hidden
- collision (249) · previews (602) · doors (107) + variants (183) (merge pair)
- soldier (181) / vehicle (202) / weapon (117) (merge trio; soldier carries the un-fixed _dress bug)
- modes (76) · sdkhide (83) · shapeviz (122) · theme (258) + section (204) + tips (145) + splash (124)
- objdebug (~470, added 2026-08-13) — the Object Debug window: isolates the picked prop (hides ctx children, zero-scales the instance), rebuilds it alone with every UV channel (`gs.debug_sections` + meshset `keep_all_uvs`), live knobs per part, exports the changed-knob recipe. No class_name (staged-lane rule); preloaded by toggle.

### The off-switch registry (every one has its measurement in an adjacent comment)
| switch | where | value |
|---|---|---|
| HLOD_CELLS | mapcontext:6749 | 0 |
| HLOD_ON_DEMAND | mapcontext:6767 | false |
| PROPS_RS | mapcontext:6241 | false (blocks: picking/markers/census can't see RS instances) |
| SUBPIXEL_ON | mapcontext:6451 | false |
| PROP_LOD | gamesource:6057 | 0 |
| ROADS_PROJECTED | gamesource:2895 | false |
| occluders | autorun cfg | false (measured 1.7× worse) |
| grass_range | scatter:45 | 0.0 |
| mapctx_optimize (placed cull) | toggle:1216 | ON, hidden |

---

## 4. The build pipeline (the sequence everything hangs on)

`toggle` chip/handler → `_apply_with_placements` (toggle:3943, the chokepoint)
→ `mapctx.apply()` (mapcontext:3906) → `_apply_body` (3915):
clear/salvage → `_load_data` (map_data) → `_bind_ground_globals` →
terrain (`_build_terrain_from_heightmap` 5434) → scatter → roads → water →
`_build_backdrop_async` (4460, fire-and-forget) → `_build_props_async` (4736)
+ `_add_env_decals`.

Props tail: `_apply_radius` → `_reproject_roads` (6895) → `_bake_hlod` (no-op)
→ `_compact_caches` → `flush_sidecars` → census rows → `build_finished`.
After that, `tick()` (7354) every 0.5 s: `_apply_radius` budget → scatter →
`_tick_near` (near-field ground window → `terrain_ready`).

Single-layer path with no teardown: `ensure_layer()` (6013).

---

## 5. Redundancy ledger (feeds the strangler refactor, ranked)

1. **`_enter_tree` (toggle, ~1450 lines)** — everything else is downstream of
   splitting it. The 149-line heartbeat lambda alone does 13 jobs.
2. **Progress narration ×4 channels** — bar + read_panel (D1, same weighted
   number rendered twice) + status label + log/journal; four inline lane
   lambdas that re-implement `_lane`; `stage_progress` declared and never
   emitted; `decal_progress` carries two unrelated phases.
3. **`_apply_body` (~500) / `_build_props_async` (~315) / `_build_backdrop_async`
   (~197, near-duplicate loop)** — one parameterised slice-loop removes ~100
   lines; the census printing (4991-5043) doesn't belong in the build.
4. **autorun vs flightrun** — 2,875 lines, 17 duplicated functions, 5 verbatim.
   Port the layer sweep + screenshots into flightrun, retire autorun.
5. **Logging identity hazard** — Log + Journal hold mutable statics but are
   preloaded everywhere (C4). Mechanical fix, high value given hot reload.
6. **gamesource giants** — `terrain_surface` ~456, `material_for` ~426,
   `_mesh_for_body` ~400; five copies of the texture-probe idiom; two texture
   loaders; four streaming-tree pick loops; ~15 asset-name normalisations.
7. **The tree-walk/skip-set zoo** — nine stack walks, four spellings of "skip
   our overlays"; `in_overlay()` exists and isn't called.
8. **doors+variants, weapon+vehicle+soldier** merges (the latter fixes
   soldier's real `_dress` palette bug).
9. **Reader-layer helper dedup** — guid_str ×6 ("MUST agree" by comment),
   BE readers ×3, NUL-scan ×7, FnvFile decode ×2, band-paint ×2.
10. **Dead subsystems** — the download pipeline remnants (profiler.sync +
    DOWNLOADS report, store index/ingest API, updater fetch_to_file), mvdb,
    `_mapctx_rebuild`, the mapcontext prefetch block, ROADS_PROJECTED arm,
    hlod re-show bug (`bake_and_install` 494-513 undoes its own hides).
11. **Real bugs found by the survey, not yet fixed:** log.gd:381 previous-
    session guard never fires; log.gd:168/241 hardcoded plugin path; soldier
    `_dress` :128; hlod re-show; occluders never restore the project setting;
    scatter `_regenerate_now` dead loop; `_water_partition` live-dict read
    (gamesource:3655); scatter_entries 2-part group key (gamesource:5121).

---

## 6. External tooling & data

- Pipeline repo: `User_Created\tools\bf6-highpoly-pipeline` (miners,
  fb_uv2census.py, gate_sandbox.py, deploy tooling, perfrun.py,
  perfrun_history.json lives THERE).
- Python: `C:\PortalSDK\python\python.exe` (not on PATH).
- Research databank: `PortalSDK\_Research` (INDEX.md).
- Session log: `user://highpoly-session.log` — locked `.tmp` while the editor
  runs; flushes on clean exit. Crash trail: `user://highpoly/breadcrumbs.txt`.
- Build journal: `user://highpoly/build_journal.txt`.
- Geometry cache: `user://bf6_geom/<level>_<sig>_g<EPOCH><lod><vram>/`.
- Map caches: `user://mapcontext/<map>/`.

### The machine-readable set (readable WHILE the editor runs)
Added 2026-08-13. The session log is the PREVIOUS session until a clean exit
(law C11), which made every diagnosis a quit-and-paste round trip. These three
are not:
- `user://highpoly/events.jsonl` — one JSON object per line
  `{t,unix,sess,seq,lvl,ev,cid,d}`, flushed per line, opened READ_WRITE so no
  `.tmp` rename is involved. Rolls to `events-prev.jsonl` per session.
  `HighpolyLog.event()`; warns and errors route themselves in.
- `user://highpoly/state.json` — plugin version and staleness, geometry epoch,
  map, build state, cache dirs, counts, last pick, settings probe. Written from
  the dock heartbeat, throttled 2 s (`_write_state_snapshot`, toggle.gd).
- `user://mapcontext/<MAP>/decisions.jsonl` — WHICH RULE FIRED per material
  state (uv primary/wrap, alpha gate) with inputs, output and a plain why.
  `gs.decide()` / `gs.flush_decisions()`; deduped on
  (mesh, state key, variation, surface).
Regression: `tools/test_events.gd` (asserts mid-session readability, the
envelope, sequence monotonicity, warn routing, no temp left behind).
Run it with the scratchpad's `run_test.py`, same sandbox trick as the gate.

### The query side (pipeline repo `tools/`)
- `hp.py` — state / log / watch / decisions / errors / find / where. Read-only.
- `dossier.py` — everything the GAME says about one asset, as one JSON doc.
  Selectors: name, res path, `state:0x...`, or a pick provenance line.
  Carries the KNOWN-FLAG table (wrap texcoord `0x4f5f0664`, alpha test
  `0x77d10576`) with each row's ABSENT default, which must stay in step with
  `highpoly_gamesource._alpha_gate` / `_wrap_channel_fix`.
- `explain.py` — the joint oracle: game truth vs our decision trace, diffed.
- `golden.py` — freeze the decisions for the props that have gone wrong
  before; `check` exits 1 on any change. Snapshots live in this repo under
  `tools/golden/<MAP>.json` and belong in the same commit as the rule change.
- `bf6_mcp.py` — all of the above as MCP tools. Registered in `~/.claude.json`
  as `bf6`. Read-only by design: no deploy verb.
- `sysprobe.py` / `doctor.py` — what the editor process is doing to the
  machine, and which settings and addons are signing up for per-frame work.
- `bootbench.py` — what a REAL editor boot costs: the plugin's event stream +
  process sampling + wall clock in one timeline, A/B on one variable.

### Boot, measured 2026-08-13 (n=5, stable to ~1.5 s)
| mark | figure |
|---|---|
| plugin alive (editor usable) | **8.0 s** |
| settled (all background work stopped) | **37.6 - 39.2 s** |
| the map tab in `open_scenes` | **8 - 9 s** of that, and 1.36 GB |
| Windows Defender exclusion | ~1 s, inside the noise |
| peak CPU | 8 - 9% of 32 cores, so boot is NOT parallel-bound |

**Time to USABLE is not time to quiet.** The editor is up and the plugin is
running at 8 s; the rest is scan, scene restore and GPU upload continuing
underneath. An earlier reading of "30 s before the plugin exists" was an
artifact of the event stream being created lazily on the first thing that
logged; `plugin.ready` is now emitted deliberately.

### THE FRAME RATE, measured 2026-08-13 in the REAL editor
**MEASURE FOCUSED OR DO NOT MEASURE.** An unfocused editor sleeps 100 ms per
frame (`unfocused_low_processor_mode_sleep_usec`) and View > Frame Time reports
that stall as GPU TIME. Same editor, same scene, same overlay:

| | cpu | gpu | fps |
|---|---|---|---|
| unfocused | 25-28 ms | 30-35 ms | 28-32 |
| **focused, flying** | **25-28 ms** | **19 ms** | **51** |
| focused, range 600 m | 13-14 ms | 14 ms | 65-70 |

So the frame is **CPU bound** at No Cull: ~9 ms of draw submission (15,719
draws at 5120x1440) stands between the user and 60 fps. The "GPU climbing 8 ->
30 ms over time" that this session chased for hours was the editor settling
into background idle. Nothing was climbing.

**The bench runs UNATTENDED and therefore UNFOCUSED**, and its window is
1600x900 where the real one is 5120x1440 (it drew 10,391 against 15,719). Both
gaps make every unattended figure describe a state the user never works in.
`session.py` should force focus before flying; not yet done.

Dock changes that came out of it: the range slider is now **10..1000 m
defaulting to 500** with **No Cull as its own button** (it used to be the top
notch of a 0..3500 slider, which is where a drag lands and is the most
expensive setting there is), and a **"Draw when unfocused"** chip sets the
background sleep to 16 ms so the editor stays readable at ~60 fps.

### FOUR THINGS CHANGED THE USER'S SETTINGS AND DID NOT RESTORE THEM
All found in one session; treat any new `set_setting` or slider write as
guilty until it parks and restores:
1. the bench's `low_processor_mode_sleep_usec`
2. the bench's `unfocused_low_processor_mode_sleep_usec`
3. **the bench's RANGE SLIDER** - driven to No Culling, recorded, never put
   back, into a value the dock PERSISTS per map in project metadata. One run
   pinned a user's editor in its slowest configuration for every future
   session; ~130 runs exist on that machine.
4. the new unfocused chip (restored three ways by construction)

### godot-mcp limits, VERIFIED not assumed (2026-08-13)
- `execute_editor_script` is EXPRESSION ONLY: no assignment, and
  `EditorInterface` is not reachable. "Invalid named index 'EditorInterface'".
- `get_editor_camera` returns `{}` - the editor camera cannot be driven from
  MCP, matching the note in `highpoly_autorun._fly` that
  `get_editor_viewport_3d()` hands back a plain SubViewport.
- `get_editor_performance` DOES work and is trustworthy for draw calls,
  object counts and memory. Its fps is only meaningful when the editor is
  focused AND something is changing (the editor redraws on demand).
- Focus can be forced from PowerShell (`WScript.Shell.AppActivate` on the
  editor pid), which is how to make a remote reading meaningful.

### Three boot-time laws, each paid for
- **Settling is not a CPU threshold.** `cpu_pct` is normalised across cores
  and boot is single-threaded: one saturated thread is ~3.1% of 32 cores. Use
  working set going flat (plus quiet disk) as the signal. The CPU rule
  reported "settled" at 5 s when the truth was 38 s.
- **NEVER pass `--benchmark-file` to a run you intend to close.** Godot dumps
  it from `Main::cleanup` and the process then spins at one core forever
  (window gone, ws 980 -> 209 MB, threads 69 -> 14 -> 9, then stuck).
  Measured against plain / `--log-file` / both: only the benchmark flag
  hangs, everything else exits in ~1.2 s. **A normal editor closes cleanly**;
  this was our own harness flag, and it burned a core through several
  measurements before it was found. Opt-in behind `--engine-phases`.
- **Watch the transition, not the end state.** The above took three rounds to
  find because detection waited 120 s after close before sampling, so every
  observation was of a process long past the event. Sampling once a second
  from the moment of close found it in one run.

### Cold is not warm
A throwaway project booted COLD includes a one-time import and cannot be
compared with the real project, which is always WARM. That mistake produced
"the 10,883 class_name scripts cost 27 s" (cold 30.5 s); warm the same
project is 11.7 s, and repeated runs put the remaining differences inside a
~2.5 s noise floor. Below ~3 s, this harness cannot separate anything: an
empty project measured 3.6 s cold and 6.1 s warm, and a trivial-body variant
measured SLOWER than the full-content one.
