# Shared reader packaging

Both engine adapters should consume a matched reader binary and header from one
source revision. The package builder provides an isolated build and an explicit
verification manifest; it does not install into either running editor.

From the product root, with CMake and Visual Studio 2026 installed:

```powershell
& 'C:/Users/mwalt/AppData/Local/Programs/Python/Python312/python.exe' `
  core/tools/build_core_package.py `
  --cmake 'C:/Program Files/CMake/bin/cmake.exe' `
  --out 'C:/PortalSDK_1.4.2.0/out/core-package/<unique-run-id>'
```

The output directory must be new. The builder configures a separate Release x64
build and builds only `bf6_core`, avoiding the default build's research/viewer
targets. It stages an explicit list:

- `bin/bf6_core.dll`
- `lib/bf6_core.lib` (the DLL import library)
- `include/bf6_core.h`
- `reader-manifest.json`

Source and header fingerprints are checked before/after building and again after
staging. A source change rejects the package. Failed outputs remain for diagnosis;
only a package with a completed manifest has passed the builder's checks. The
checks are observational across files, not an atomic snapshot or a replacement
for building a pinned clean source checkout for release.

The builder probes the ABI getter and every declared API symbol in a separate
process. It does not decode game data or certify structure-layout or engine
parity. Packages are marked `development-engine-parity-unvalidated` until those
checks are performed. No live DLL is overwritten and no release is published.

Before staging for an adapter, run `core/tools/check_core_package.py` with
`--package <package-directory> --consumer-header <adapter-header>`. It requires
the exact packaged header and verifies the three payload files against their
manifest hashes. Exit 2 rejects a mismatch or incomplete package. This checks
consistency, not publisher authenticity or engine behavior. The initial clean
package passed against the canonical header and was correctly rejected against
the ABI 5 Unreal header.

## Adoption gates

1. Reconcile the canonical and consumer APIs and structure layouts. As of the
   2026-09-12 inventory, the canonical header declares ABI 4 and Unreal declares
   ABI 5. Copying the canonical package over Unreal is not an upgrade path yet.
2. Rebuild each adapter against the package header. Verify required exports,
   structure sizes/offsets, allocator ownership and buffer lifetimes.
3. Run shared decoding checks and each engine's scene/material regression cases.
   Include distinct map scopes, base/variant pairs, glass, decal receivers and
   cold/warm agreement.
4. Stage an isolated engine installation with the exact binary/header pair.
   Validate clean startup before promoting the package to release packaging.
5. Store the pinned package identity with both adapter builds. Future shared-core
   updates should run both adapters' checks before changing either pin.

The existing `tools/paritylab` framework is the starting point for the rendering
and data comparisons. Engine rendering backends remain separate; a core fix can
be shared, while new rendering capabilities still require adapter implementation.

## Cleanup boundaries

Do not purge files by the word `test` in their names. Unreal currently refers to
`terraindxil_dispatch_test.exe` for a terrain integration path. Promote such a
helper to a product target/name with matching consumers and packaging changes
before removing its old path. Existing build directories can also be inputs to
Godot's native build and parity tools; migrate those references first.

Keep regression source under version control, optional investigations separate,
and generated output under ignored `out/` directories. User maps, session
recovery and unresolved evidence are not generated clutter.
