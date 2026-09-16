# Rendering parity between Godot and Unreal

The goal is one interpretation of the installed game, consumed by two engine
renderers. Sharing geometry decoding alone does not satisfy that goal. Godot
still resolves many prop materials and UV choices in GDScript; Unreal consumes
the native material description and adds some classifications of its own.

## Confirmed September 12 regression cases

| Case | Evidence | Status |
| --- | --- | --- |
| Aftermath water absent in Godot | Native water read returns one 10 km surface at 49.70 m with authored `Visible=0`. Godot filtered it; Unreal retains it. | Godot filter removed; Aftermath, Tungsten and invalid-map controls pass. |
| Water toggle rebuilds unnecessarily | The native simulation driver increases child count without adding a surface. | Count surface meshes separately. |
| Godot lighting differs from product source | Installed reader lacked live VisualEnvironment selection and lighting-zone dependencies. | Install the source, lighting, zones and panel changes together. |
| Normal maps differ by shader family | Aftermath sedan binds `0xec35a74c` to its `_nmo` sheet. Other prop/character families bind different full hashes. | Preserve the vehicle slot alongside the newer mappings; do not replace one family with another. |
| Sedan purple/pink lights and green headlights | The installed sedan `_e` sheet contains separate R/G/B regions. The older pipeline records these as light-group masks; both current generic renderers bind RGB directly as emission. | Root cause identified. Actual group activation/color evaluation remains to be carried through the shared material description. |
| Wall/floor graffiti missing in Unreal | Godot's `edv` path reads environment decal volumes. The native public decal API supplies terrain decals, a separate system. | Shared environment-volume decode and both adapter consumers are still required. |
| Godot graffiti appears only close | The consumer fades using each record's authored culling distance. | Preserve the authored value; expose an editor preview distance policy separately rather than changing game data. |
| Vehicle checkerboards | No exact material/component failure has been established for the reported surface. | Capture the source scope, resolved section, bindings and compile status before changing materials. |

Water and Lighting are independent per-map switches. Compare the same enabled
layers before comparing render quality. Cloud imagery in the current paths
comes from the sky panorama; Unreal also supplies atmosphere and height fog.
Deploying the lighting reader does not implement complete atmospheric parity.

## Shared contract to finish

Extend the versioned native output rather than introducing another independent
engine-side material resolver. It must preserve:

- Placement scope, variation, resolved shader-state key and source provenance.
- Texture parameter identity, role, packing, color space and explicit fallback
  reason. An RGB light-group mask must not become an emissive color texture.
- Per-layer UV channel and transform, palette selector and per-vertex lane,
  livery coverage, facade bake/mask composition, roughness and metallic packing.
- Environment decal template, composed world transform, projection convention,
  atlas selection, alpha, sorting, culling and texture/material bindings.
- Water surfaces, simulation and optical parameters, plus the active environment
  preset, panorama, sun, exposure, fog and local lighting zones.

Raw authored flags remain available for diagnosis. Consumers must not invent
runtime meaning from a flag name, as the Aftermath `Visible` regression did.
Engine adapters may translate axes, units and render resources. Interpretation
of shader families and authored channels belongs to the shared decoder.

The old pipeline's emissive pixel-purity heuristic is useful evidence, not a
complete reconstruction of light-group semantics. Do not globally suppress
saturated emissive textures: real colored lights are the negative control.

## Promotion checks

Run `tools/check_godot_deployment.py --installed-addon <project>/addons/highpoly_toggle`
after staging. Missing or differing code fails with exit 1; extra files are
reported and never deleted. This would have caught the stale lighting reader.
It checks file identity, not visual equivalence.

Run `tools/test_native_water_visibility.gd` in a Godot project with the matched
addon and native binding. It exercises the actual shared-reader output and the
Godot consumer, including an invalid map. Lighting controls live in
`tools/test_live_environment.gd` and `tools/test_lighting_zone_shapes.gd`.

Use `tools/paritylab` for paired images and evidence. Add the same map/asset
regressions to both adapters before promoting a shared reader revision. Keep
base/variant and cold/warm cases. A passing decoder test does not prove the
renderer uses its result.

The reader packages still require ABI reconciliation described in
`SHARED-READER-PACKAGING.md`; copying an ABI 4 DLL over an ABI 5 consumer is not
an upgrade. No claim of automatic complete cross-engine parity is made yet.
