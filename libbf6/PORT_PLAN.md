# libbf6 — porting the decode into a shared core

The Godot plugin's decode is GDScript. This moves it, one module at a time, into
an engine-neutral C++ library (`libbf6`) that both a Godot binding and a future
Unreal binding link against. The research is done; this is translation of
known-correct code, validated by comparing each module's output to the working
plugin.

## Scope for now: Steam only

The Steam executable is plain on disk, so the schema module just reads it. The
EA path (in-memory decrypt of a DRM-wrapped executable) is DEFERRED and revisited
later; the ABI already has a `bf6_was_lifted()` flag reserved for it, which stays
0 until then. Nothing in the core needs the lift to reach a working Steam build.

## Three layers

```
        libbf6 (C++, this dir)          <- reads + decodes the game. No engine.
       /                      \
  Godot binding            Unreal binding
  (GDExtension, thin)      (editor module, thin)
```

The contract is `include/bf6_core.h`. Nothing engine-specific crosses it;
nothing Frostbite-specific leaks past it.

## Module map (GDScript -> core), in dependency order

| # | Core module          | Ported from (GDScript)          | Job |
|---|----------------------|---------------------------------|-----|
| 1 | `oodle`              | `native/src/bf6_oodle.cpp`      | ALREADY C++. Loads the game's oo2core, decompresses. Reuse. |
| 2 | `container` / `cas`  | `bf6_container.gd`, `bf6_cas.gd`| Find install, mount TOC/superbundle, read + decompress a chunk by id. |
| 3 | `source`             | `bf6_source.gd`, `bf6_bundle.gd`| The res/ebx/chunk tables and name -> bytes. |
| 4 | `types`              | `bf6_types.gd` (Steam path only)| Read the plain type schema from the exe. |
| 5 | `ebx`                | `bf6_ebx.gd`                    | Decode an EBX partition to fields. |
| 6 | `meshset`            | `bf6_meshset.gd`                | Geometry: sections, verts, normals, uvs, indices. |
| 7 | `texture`            | `bf6_texture.gd`                | BCn passthrough + header decode. |
| 8 | `material`           | resolution parts of `highpoly_gamesource.gd`, `bf6_atlas.gd` | depot + variation -> concrete texture set. |
| 9 | `walk`               | `bf6_walk.gd`                   | The placement walk -> instances + lights. |
| 10| `terrain`            | `bf6_splat.gd` + terrain parts  | Heightfield, splat, colour map. |

The orchestration in `highpoly_gamesource.gd` (mesh_for, object_rows) becomes the
API entry points, not a module — most of it is caching and engine glue that stays
in the binding.

## The vertical slice — build this FIRST

Prove the whole spine with one asset, no browser, no map loader:

1. `bf6_open()` — modules 1-4: mount and read the schema.
2. `bf6_read_mesh(res_name, 0)` — modules 5-7: one asset's geometry + textures.
3. A tiny Godot binding turns that into an `ArrayMesh` and drops it in a scene.

When one BF6 mesh appears in Godot *through the C core*, every hard seam is
proven: mount, Oodle, schema, the ABI, the coordinate handoff. Only then is the
full port worth committing to — and the same slice re-bound in Unreal is the
Unreal proof-of-concept.

## Validation — never "looks right", always byte-equal

Each ported module is checked against the GDScript reference: dump the module's
output for a fixed asset from both, compare. Meshes compare by vertex/index hash,
textures by block hash, the walk by the placement fingerprint the plugin already
computes. A module isn't done until it matches.

## Already done

- `oodle` (module 1) — exists in C++, reused.
- Modules 2 (container: cas, dbobject, caslocator, toc, bundle, source) and 6
  (meshset geometry), byte-validated against the plugin.
- `placeables` — the SDK's own catalogue JSON, per-level filtered.
- **`types` (module 4), 2026-08-22.** `src/types.{h,cpp}`: PE parse, the
  `typeinfo` section, guid search with a whole-file fallback, `layout`,
  `layout_full` (superclass fold, dedup by nameHash) and `resolve`. Carries the
  GDScript reader's two corrections over the older Python reference: the
  `0xFFFF` "no serialized slot" sentinel is dropped rather than read as an
  offset, and inherited fields dedup by nameHash rather than by offset.
  VALIDATED against `typesdk.py` over 8,609 real type guids
  (`BF6_Frostbite_Research/data/ebx_type_identities.tsv`), on BOTH executables,
  with the harness applying those same two fixes to the Python side so the
  comparison is like for like:
    - SP build: 8,011 identical, 598 absent from both, 0 different.
    - MP build: 8,308 identical, 301 absent from both, 0 different.
      (The counts differing IS the SP/MP schema split, as documented.)
  Speed, same 8,011 types: C++ 2.27 s INCLUDING reading the 176 MB executable,
  Python 21.1 s for the lookups alone. Both use a native substring search, so
  that 9.3x is per-lookup overhead, not the search.
  NOT ported yet, deliberately: the EA App DRM lift and the generated type
  database it feeds. Detection IS ported (entropy: 3.38 bits / 64.8% zero on a
  plain build, against ~8.0 for ciphertext), so an EA install can be told
  plainly instead of silently opening every map empty.
- Build path: MSVC + CMake -> `bf6_core.dll` (Godot) and `bf6_core_static.lib`
  (Unreal), both compiling from the stub.

- **`ebx` (module 5), 2026-08-22.** `src/ebx.{h,cpp}`: the RIFF container, the
  EFIX fixup tables, and the value deserializer driven by module 4. Carries the
  GDScript reader's corrections over ebx.py/ebx_deser.py: PointerRef is a SIGNED
  32-bit offset in an 8-byte slot (885 of 886 refs recovered), array element
  stride follows the element TYPE rather than always u32 (5,762 instances were
  being judged invisible from a bool array read four times past its end), and a
  field landing outside the file nulls THAT FIELD rather than losing the whole
  instance (395 placements).
  VALIDATED line for line against the Python reference on 458 real partitions
  pulled out of the install: globals 218, and 60 each from vehicles, weapons,
  characters and ui. All 458 identical, including one of 137,993 values. The
  harness (`scratchpad/typeport/compare_ebx.py`) applies the same corrections to
  the Python side, and `--raw` reports where the UNPATCHED reference differs, so
  the corrections are visibly doing work rather than being asserted.
  THE VALIDATION FOUND A REAL BUG: decode() and scalar() have DIFFERENT defaults
  in the reference and the difference is load-bearing. An unhandled type enum is
  reported as unknown, but an unhandled ARRAY ELEMENT falls back to a u32.
  Collapsing the two turned real values into null on six of the first 218
  partitions.
  Largest sampled partition (553 KB, 54 instances, 101,924 nested fields, 36,069
  array elements): 113 ms here for parse, decode AND printing 137,993 lines,
  against 390 ms for the Python decode alone.

- **level mounting, 2026-08-22.** `Source::find_tocs` / `mount_level` /
  `available_levels`, ported from bf6_source.gd. The mount is FIRST WINS, so the
  order is the correctness: shared archives first (so a level cannot displace a
  global it depends on), then the level being read, then every other level when
  all_levels is asked for. Among levels the rule reads backwards from how it
  sounds - the level being read must come FIRST, or every other level outranks
  it for any name they share, and levels share names freely.
  Verified on the real install: 30 levels found; mp_dumbo's two tocs lead the 60
  level tocs under all_levels; mounting mp_dumbo alone gives 228,818 ebx /
  165,693 res with 1,950 partitions belonging to the level itself, including its
  own root asset. Cost: find 8 ms, mount 6.7 s (the mount reads segment 0 of
  every bundle, which is the documented price and what the plugin caches).

- **`walk` (module 9), 2026-08-22. FIRST PASS, 99.96% against the plugin.**
  `src/walk.{h,cpp}` + `Source::partition_index`. The traversal, the transform
  composition, the StaticModelGroup emit with per-instance variation and the
  packed-bool unpack, the destruction-branch stop, the subworld bridge and the
  leaf fallback.
  ORACLE: the shipping Godot plugin's OWN cached walk,
  `%APPDATA%/Godot/app_userdata/.../bf6_walk_mp_dumbo_v4_<sig>.idx`, read with
  `scratchpad/typeport/gdvar.py`. Two caches from different game builds were
  compared to each other first and are byte-identical, so the oracle is stable
  and a difference cannot be blamed on a patch.
  RESULT on mp_dumbo: 48,127 rows against the plugin's 48,126, of which 48,107
  are identical including every transform float. What remains:
    - 14 rows differ ONLY in which name the partition index resolved for the
      variation. Same mesh, same transform, same placement: a duplicate asset
      shipped under two paths shares one partition guid, and "first name wins"
      is decided by iteration order. Ours is now tie-broken by name so it is at
      least stable run to run; the plugin has no tie-break, so the two can
      legitimately disagree about what to call the same partition.
    - 1 sandbags row whose translation differs by about 0.12.
    - 5 latereflections sound-prefab leaf rows against the plugin's 4, from the
      same source partition, with different transforms. NOT EXPLAINED YET.
  TWO FLOAT LAWS, both found by the comparison and both worth 100+ rows:
  GDScript has one float type and it is a DOUBLE, so a Vector3 component widens
  on read and the whole multiply-add runs in double before being stored back as
  float32 (175 rows differed in the sixth significant digit until this matched).
  And the basis rows must not add a "+ 0.0" translation term, because adding a
  positive zero turns a NEGATIVE zero positive (52 more rows).
  Cost on mp_dumbo: mount 4.4 s, types 0.05 s, partition index 19 s, walk 2.45 s.
  The plugin's own figures for the same map are 16 s mounting, 19 s indexing and
  53 s walking, so the traversal itself is roughly 20x.

- **`velighting`, 2026-08-24.** `src/velighting.{h,cpp}`, exposed as
  `bf6_level_lighting` / `bf6_level_lighting_imports`. The level's active
  VisualEnvironment: sun, sky and atmosphere, two cloud layers, cloud shadows,
  fog, exposure and bloom, colour grading, white balance, ambient occlusion,
  global illumination, the shadow cascade distance, and the nine texture
  references the preset binds. 89 named fields per map plus the whole import
  list. Mounts and loads the schema on demand, so it does not need the walk.
  WHICH PRESET: the level ROOT imports the outdoor one. Filter the imports to
  partitions under a `levels/` directory (this drops the four shared
  `common/lighting/` presets every root also imports), drop `thermal`, then -
  where more than one survives, which is every Granite level - keep only
  candidates that actually carry an OutdoorLight component and take the one
  with the highest VE-entity `Visibility`. mp_granite's `nolut` preset has 2
  components, no sun and Visibility 0.15 against the real one's 25 and 1.0.
  Do NOT restrict to the level's OWN directory: every Portal variant is lit by
  its base level's preset, from another level's folder entirely.
  WHICH FIELD: every constant is keyed by (component type_guid, nameHash),
  because the hash-to-name lookup is many-to-one. Two distinct hashes on the
  sun component are both named `SunRotationX` (one is the authored 124.8, the
  other 0.0) and `SunScale` exists on two components at 1.5 and 300000.
  ORACLE: the 22 rows of the Godot plugin's hand-built `TABLE` in
  `addons/highpoly_toggle/highpoly_lighting.gd`, checked in `velight_test`.
  23 levels decode; 21 rows reproduce az, el, lux and SunColor exactly. The two
  that do not are the TABLE's errors, not the decode's, and both are recorded
  in the test:
    - MP_Badlands az 354 and SunColor (1, 0.21, 0) were never derived. The
      mined sidecar carrying that row says so itself ("carried forward as-is"),
      354 appears in none of the four VE presets the level ships, and the
      plugin's own header retracts the claim that this map's sun was
      photo-verified. Its el (10) and lux (45860 against the authored 45860.16)
      DO match, which is what a half-hand-filled row looks like.
    - MP_Plaza SunColor red is authored at 1.06066 and the table carries 1: a
      clamp on the way in. The tint is not normalised in the data.
  Two bugs fell out of it, both fixed here:
    - `Source::partition_index` was built once and never invalidated, so
      mounting a second level left it answering for the first. It only ever
      MISSES, which read as "this level imports no lighting preset" for a
      preset that is plainly imported.
    - the asset-reference fields on a VE (`PanoramicTexture`,
      `SkyGradientTexture`, `HdrColorGradingLut`, ...) are declared with a NULL
      type, so `read_instance` reports them absent while the payload holds an
      ordinary import pointer. `Ebx::import_ref` reads them by name, the way
      `Ebx::int_pointer` already handles the mirror-image case.
  `vedump_test` is the research tool the constants were read off: it emits
  (component type_guid, hash, value) triples for a join against
  `BF6_Frostbite_Research/data/sdk_field_names.tsv`, and dumps every preset a
  level ships, imported or not.

- **`levellights`, 2026-08-25.** `src/levellights.{h,cpp}`, exposed as
  `bf6_level_lights`. Every lamp, spotlight, ceiling fixture and emissive panel
  a level places, with its world transform, type, colour, intensity AND ITS
  UNIT, falloff, cone, emitter shape, shadow flags and IES profile. `velighting`
  is the sun and the sky; this is the other half, and without it a map is lit at
  midday whatever its preset says. mp_dumbo 7,878 / aftermath 3,874 / isolated
  3,695 / subsurface 5,330 / tungsten 1,514 / capstone 553.
  Mounts and loads the schema on demand, like `velighting`, and does its own
  light-only traversal rather than riding the placement walk. It never decodes a
  `StaticModelGroup` - the walk emits a group's members and returns without
  descending, so for lights a group is a dead end and skipping it is an
  equivalence, not a heuristic. 40 s cold for mp_dumbo, everything included.
  WHERE THE PLACEMENT IS: not on the light. A `*LightEntityData` has no
  `BlueprintTransform` and its own `Transform` is identity on 86.9% of a map's
  lights; the placement sits on a separate component (`dcac04fc-...`) in the
  owning object's `Components` array. Read the component's `Transform` and join
  it to its light through the component's `Light` field.
  WHICH FIELD IS THE POINTER, and this one is why the MP executable matters:
  `Light` is `0xE4B6881A`, declared `Class(LocalLightEntityData)`, a plain
  PointerRef. The GDScript reader and the research write-up both follow
  `0x11F57ECA` instead, calling it "an int field that holds a pointer". It is a
  genuine four-byte `Enum(PBRAnalyticLightShape)`. It only ever resolved because
  those readers load the SP executable, whose schema puts `Light` at +112 and
  `0x11F57ECA` at +120 - which is where the MP data keeps the pointer. Measured
  here on 17,479 components across six maps: `Light` resolves all of them and
  `0x11F57ECA` resolves none. The counter is in `bf6_light_stats` so it stays a
  measurement.
  A SPOT EMITS ALONG MINUS FORWARD, and the basis rows carry the holder's scale,
  so row 2 needs normalising and an area light's world size is its authored size
  times that scale.
  `Color` and `Intensity` are in `engine_only_field_names.tsv` and NOT in the
  SDK table: a reader consulting the SDK table alone gets a full, plausible,
  correctly-counted set of lights that are all white.
  ORACLE: `light-fixture-glow-is-its-own-slot` records `CeilingLamp_Rect_01`'s
  four emitters by hand - spots at 15,625 lm / 6 m / 150 deg and 31,250 lm /
  15 m / 110 deg, tubes at 1,562.5 lm / 2 m - and the decode reproduces all
  four. `levellights_test <game> <level> [@fixture]` dumps them.

## Build

```
cmake -S libbf6 -B libbf6/build -G "Visual Studio 18 2026" -A x64
cmake --build libbf6/build --config Release
```
