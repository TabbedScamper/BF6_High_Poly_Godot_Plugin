# Native terrain and water in Godot

The Godot adapter now uses the installed-game C++ reader for selected-level
terrain, ground coverage and materials, water surfaces, water heights, water
masks and authored ocean simulation inputs. No extracted game data is shipped.
The existing Terrain and Water controls select these paths when the matched
native binding is available; the script reader remains the fallback.

## Shared behavior

- `BF6Core.environment(level, product, detail)` returns a versioned in-memory
  metadata header plus owned binary buffers. One native context is shared by
  the adapter's native products and guarded by a mutex. Environment reads mount
  the selected level, with `all_levels=0`.
- Native terrain uses absolute heights with `height_scale / 65536`, independent
  X/Z bounds and no AABB Y bias. Geometry caches use `v8_native` so older meshes
  cannot restore the previous height conversion. Road sampling uses the same
  bounds and adaptive tile steps. Preparation runs on the existing loading
  worker; a repeated main-thread request reuses its prepared metadata.
- Ground colour, normal and roughness functions are translated from the active
  Unreal implementation, including eight coverage slots, layer parameters,
  stochastic detail, grass classification and the far-ground blend. Native
  coverage also feeds scatter and ground-blended props. The default coverage
  resolution is 4096 with 512-pixel material sheets, matching Unreal's defaults.
- `core/include/bf6_ocean_replay.h` contains the portable CPU ocean replay:
  positive unnormalized inverse FFT, current Unreal wave-vector signs, foam
  history and the corrected reciprocal foam gain. Godot scheduling and texture
  upload stay outside this header.
- Water reproduces Unreal's simulation gates, cascade overlap, shore/mask
  attenuation, height lift, detail-normal and foam bindings, broad-pattern
  displacement and provisional interactive-wave bridge. Gerstner crest remains
  zero because the current Unreal call sites pass no Gerstner wave set.
- Terrain depth textures use the same 1024 maximum side as Unreal; water-height
  textures use 2048. Sampling happens in C++ before upload. The full geometry
  field is released after road draping; water retains only the compact grid.
- The water driver has one worker job at a time, reuses texture objects, freezes
  the level per job, rejects stale results, pauses its clock while hidden and
  retries transient frame errors with bounded backoff. Removing its scene waits
  for the owned task and releases its cascade textures.

## Rendering boundaries

This is a port of the current Unreal preview, not a claim of identical rendered
frames or a complete reconstruction of the game's renderer.

Godot does not provide Unreal Single Layer Water. Transmission uses scene-depth
and screen-colour textures; volume scattering is approximated through the lit
material. Refraction distortion, the SLW lighting phase and underwater rendering
are not equivalent. Exposure, scene lighting and tone mapping also affect the
result. Tests currently exercise Forward+ with Vulkan, not Compatibility or a
minimum-spec GPU. Native water uses a subdivided plane, not Unreal's adaptive
camera-dependent water mesh.

The exact terrain-page helper currently supports the Tsuru evaluator layout
(304-byte layer rows). Granite's 284-byte layout is explicitly rejected. The
normal terrain material stays active when an exact page is unavailable. The
helper has a 120-second/output-size budget, drains both pipes on a worker, and
never publishes a truncated page. Exact page base colour remains disabled,
matching Unreal's current validity safeguard; supported pages supply normal and
roughness. The helper reads the user's game at runtime.

Region-banded water colour and river flow still have decoding/rendering gaps
in the current shared/Unreal path. Diagnostics identify unsupported cases.
Absent decoded extinction uses Unreal's labelled hue/brightness preview model.
No 10-second cold-load or whole-map 60-FPS claim is made. A full 16385-square
terrain read plus mounting still took roughly 17 seconds in the isolated test.

## Maintaining the port

`tools/sync_unreal_ground_shader.py --unreal-source <BF6HighPoly.cpp> --check`
detects drift from the source translation. Run without `--check` to regenerate,
then run the parser and GPU checks. The source hash is recorded in the shader.
`tools/generate_environment_fields.py` regenerates field serialization from
the canonical reader header. These are source generators, not game-data exports.

Build `native/CMakeLists.txt` against a matched `BF6_CORE_PACKAGE` containing
the header, import library, DLL and reader manifest. Run
`core/tools/check_core_package.py` first. The locally tested reader is ABI 4
with 206 exports. Do not replace Unreal's ABI 5 reader with this DLL.
The mount-only environment preparation and direct compact height path are
documented with measured comparisons in [COLD-LOADING.md](COLD-LOADING.md).

The optional `bin/bf6_terrain_evaluator.exe` is the existing native
`terraindxil_dispatch_test` target packaged under a product name; it links the
reader statically and communicates through the checked V3 page protocol. Its
upstream source is `core/test/terraindxil_dispatch_test.cpp`.

## Verification

- CTest: vertex attribute regression and independent ocean replay tests pass.
  The ocean reference uses a separate double-precision DFT and perturbation
  controls; real Granite inputs also pass. This is CPU numerical verification.
- `test_native_environment.gd`: real native products, exact compact-height
  sampling against full heights, a transposed-height control, checked water
  descriptor joins, malformed packet and unknown-product controls pass.
- `test_native_environment_integration.gd`: actual installed-source merge
  compiles, rectangular terrain geometry and road heights agree. The deliberate
  square-bound control gives a different height.
- Ground texture-array binding, shader parsing and malformed-page rejection pass.
  A real Tsuru V3 exact page passes; Granite's unsupported layout rejects.
- Water default/sentinel, pool-versus-ocean gate, compact-height, rewind,
  animation, stale-level and cleanup checks are provided separately.
- Actual GPU renders on an RTX 4080 pass for Granite and Tsuru. Ground is checked
  against hidden and magenta controls. Water is checked against hidden, frozen,
  disabled FFT, later-frame and amplified-FFT controls. Tsuru's authored FFT
  effect is small but exceeds repeat-frame noise. The harness uses reduced
  coverage/sheet resolution for smoke checks. Tsuru also passes at the production
  4096 coverage / 512 sheet settings (`--production`). These scenes do not
  establish whole-map performance or identical Unreal lighting.

The installed editor restarted and loaded the verified binding and all three
new global classes. Its existing Scene Library plugin reports a typed-dictionary
assignment error at `scene_library.gd:1443`; older One-Offs DDS assets report
truncated mip chains, and existing scenes have duplicate UIDs. Those files were
not changed here. The full project startup is therefore not error-free, despite
the environment integration and GPU tests passing.

Run the isolated Godot tests with `tools/run_native_environment_test.py`.
It fails on engine errors even if a script exits zero. GPU runs require `--gpu`.
Local logs, screenshots and recovery copies are under
`C:/PortalSDK_1.4.2.0/out/godot-environment-port/` and the verification project's
custom user directory. No public release was made for this change.
