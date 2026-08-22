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

## Build

```
cmake -S libbf6 -B libbf6/build -G "Visual Studio 18 2026" -A x64
cmake --build libbf6/build --config Release
```
