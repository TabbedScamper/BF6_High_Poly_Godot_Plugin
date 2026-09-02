# Native validation harnesses

This directory contains 74 small executables. They are proof and diagnostic
harnesses, not runtime data providers. All game-facing harnesses read the
user's current Steam installation when they run.

## Classification

- `sdk/oracle`: `placeables_test`. It checks the Portal SDK catalogue and is
  intentionally isolated from runtime suites.
- `game/smoke`: archive and broad typed-decode checks registered in CTest:
  `level_test`, `water_test`, `terrain_test`, `decals_test`.
- `game/control`: focused claims with fake, shuffled, or cross-level controls,
  registered in CTest: `waterclosure_test`, `waterheightfield_test`,
  `waterdepth_test`, `terrainlayers_test`, `terrainstatic_test`,
  `terrainstatic_live_test`, `terrainbounds_live_test`, `scatter_test`,
  `fxabi_test`, `weapon_fit_test`.
- `game/UI control`: `rime_live_test`. It reads and recursively expands the
  shipped Rime tree, checks the recorded research table only as an oracle, and
  reports fake-root, shuffled-name, point-anchor, schema-gate, reference-depth,
  and duplicate-identity controls.
- `game/diagnostic`: targeted readers and census programs requiring a search,
  GUID, point, TOC, texture, or other explicit argument: `albedo_test`,
  `bindingset_test`, `bundlecount_test`, `cas_test`, `depot_test`, `ebx_test`,
  `ebxls_test`, `findocean_test`, `fx_test`, `kernelcensus_test`,
  `levellights_test`, `loc_test`, `material_test`, `mesh_read_test`,
  `meshset_test`, `oceankernel_test`, `oceanshader_test`, `pipeline_test`,
  `slots_test`, `source_test`, `texture_test`, `tilescan_test`, `toc_test`,
  `types_test`, `variation_test`, `vedump_test`, `velight_test`,
  `vicinity_test`, `vista_test`, `walk_test`, `watershaders_test`,
  `weaponspike_test`, `whitecards_test`.
- `terrain/render diagnostic`: `groundcov_test`, `splat_test`,
  `terrainbindless_test`, `terraincomposite_test`, `terraindxil_dispatch_test`,
  `terraindxil_test`, `terrainfit_test`, `terrainmask_test`, `terrainpage_test`,
  `terrainrows_test`, `terrainsurface_raster_test`, `terrainwindow_test`.
- `water/render diagnostic`: `waterbind_test`, `watercomposite_test`,
  `waterconst_test`, `waterdepthcmp_test`, `waterdraw_test`, `waterdxil_test`,
  `watermask_runtime_test`.
- `decal diagnostic`: `decaltint_test`, `decaltintmul_test`, `decalwhite_test`.
- `destruction/pipeline diagnostic`: `destruction_test`.
- `armory diagnostic`: `armory_test`.

`dxdmp_probe.cpp` is an optional capability probe rather than a normal test;
it is built only when `BF6_DXDMP_AGILITY_DIR` is supplied.

Registered tests use a proven fixture for the subsystem they exercise rather
than assuming one map contains every system: Tsuru (`mp_isolated`) supplies the
four-cascade ocean, water heightfield, full terrain static table, and compiled
terrain decals; `mp_atoll` supplies the FX ABI fixture. `mp_portal_sand` remains
the smallest general archive/terrain smoke map. Absence on that map is not
misreported as a decoder failure.

## Running the registered suites

```powershell
cmake -S libbf6 -B libbf6/build -DBUILD_TESTING=ON
cmake --build libbf6/build --config Release
ctest --test-dir libbf6/build -C Release -N
ctest --test-dir libbf6/build -C Release -L smoke --output-on-failure
ctest --test-dir libbf6/build -C Release -L control --output-on-failure
```

For a Steam library outside the standard location, pass
`-DBF6_TEST_GAME_DIR=<path>`. Harness output goes under the build tree unless
an explicit output path is supplied.
