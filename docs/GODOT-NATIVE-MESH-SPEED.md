# Godot native mesh decoding

Godot now uses the shared C++ reader for vertex attribute decoding. The same
decoder serves the native mesh reader and the Godot binding, avoiding another
independent format implementation. This acceleration does not require a cache.

`BF6MeshSet._read_attr()` makes one native call per attribute instead of running
a GDScript loop per vertex/component. The binding reads the original byte array
through a const accessor and writes directly into a Godot `PackedFloat32Array`.
Tightly packed float2/float3 attributes also use bulk conversion into Godot's
vector arrays. Other component layouts and double-precision Godot builds retain
the vector conversion loops.

Material selection, UV semantic selection, section membership, part transforms,
palettes and indices retain their existing behavior. The reader creates no game
context for this operation and does not mount additional levels. An older
extension without the new method uses the original GDScript decoder. Set
`use_native_attributes = false` on a reader for a reference comparison; its
`native_attribute_reads` and `script_attribute_reads` counters expose the route.

## Verification on 2026-09-12

Godot 4.6.3 stable Windows x64, Release native binding, installed Steam game:

| Measurement | Script | Native | Ratio |
| --- | ---: | ---: | ---: |
| Full LOD decode, 14 real meshes, 41,564 vertices | 112.122 ms | 31.602 ms | 3.55x |
| Float3 attribute, 200,000 vertices | 47.908 ms | 0.980 ms | 48.89x |
| Half2 attribute, 200,000 vertices | 57.632 ms | 0.888 ms | 64.90x |
| Half4 attribute, 200,000 vertices | 77.522 ms | 1.533 ms | 50.57x |
| Short4N attribute, 200,000 vertices | 126.892 ms | 1.079 ms | 117.60x |
| UByte4N attribute, 200,000 vertices | 154.101 ms | 0.952 ms | 161.87x |

The real corpus mounts only `mp_granite_clubhouse_portal`; it covers SUV/sedan
doors, billboards, curbs and Manzanita vegetation. Full serialized section
outputs match exactly, including all UV metadata. All 1,380 attribute reads use
the native route with zero fallback. Timings alternate execution order, discard
the first pair, and use the upper median of remaining samples. The corpus row
sums the per-mesh upper medians.

The benchmark times decoding already-read resource/chunk bytes. It excludes
disk I/O, decompression, material assembly, scene insertion and rendering. These
numbers are not whole-map cold-start or viewport FPS measurements, and are not
measurements on the minimum-spec PCs.

Additional checks passed:

- 48 format/stride combinations across 24 supported formats, exact float bytes.
- All 65,536 half-float encodings: matching finite values, infinities and signed
  zero. Both paths produce NaN for NaN inputs; 1,022 signaling NaN encodings have
  different payload quiet bits, so those are checked as NaN rather than claimed
  bit-identical.
- Bounds, malformed elements, short buffers and integer overflow rejection.
- C API capacity failures leave output untouched; 80,000 calls from eight
  threads match their reference values.
- New script with the old extension: correct script fallback. Installed new
  DLL pair with the new script: native method runs. Existing BF6Oodle methods
  remain available.

Evidence: `C:/PortalSDK_1.4.2.0/out/godot-native-speed/`, especially
`attribute-direct-array.log`, `mesh-corpus-direct-array.log`,
`installed-pair-smoke.log` and `old-extension-final-fallback.log`.

## Building and deploying

Build and verify a reader package using [shared reader packaging](SHARED-READER-PACKAGING.md).
The new stateless `bf6_decode_vertex_attribute` export is additive; this package
remains ABI 4 and exports 204 declared functions. Existing struct layouts are
unchanged by this change. Unreal's ABI 5 consumer still requires reconciliation;
this DLL must not replace its reader binary.

Configure `native/CMakeLists.txt` with Visual Studio 2026, x64, and
`-DBF6_CORE_PACKAGE=<verified-package-directory>`. Build the `bf6_oodle` and
`vertex_attribute_test` targets in Release, then run CTest with `-C Release`.
The binding build uses the packaged header/import library and copies the
matching reader DLL beside its output. The legacy `native/build.bat` remains a
separate build route; it does not select this package automatically.

Deploy `bf6_oodle.windows.x86_64.dll` and `bf6_core.dll` together into
`addons/highpoly_toggle/bin/`, with the updated `bf6_meshset.gd` in the add-on.
Close Godot before replacing DLLs. The local development install has been
updated; recovery copies and hashes are under
`out/godot-native-speed/deploy-backup/manifest.json`. No release was published.

Godot regression scripts live under `tools/test_native_vertex_*.gd` and
`tools/test_native_mesh_corpus.gd`; `tools/run_native_vertex_test.py` supplies a
headless process timeout and captured log. They use an isolated project with
the mesh reader at `res://bf6_meshset.gd`, the tested extension and DLL pair,
and, for the real corpus, the existing BF6Source dependency scripts. Import the
isolated project once to register its global classes. The existing isolated
projects are under `out/godot-native-speed/harness/` and
`out/godot-native-speed/old-extension-harness/`. Game bytes are read at runtime;
test logs are evidence, not runtime inputs.

## Remaining performance work

Measure complete map opening next, separating game reads/decompression, texture
decoding, material creation and scene insertion. Native mesh decoding removes
one measured bottleneck; it cannot establish a ten-second complete load or a
60 FPS render budget. Material/renderer convergence and the shared ABI migration
remain separate work. Preserve Godot's existing appearance while profiling those
stages before choosing the next native port.
