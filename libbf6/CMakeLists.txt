cmake_minimum_required(VERSION 3.20)
project(libbf6 CXX)

# The engine-neutral Battlefield 6 decode core. No Godot, no Unreal, no engine
# headers here - only the game formats. Bindings link against this.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BF6_SOURCES
    src/bf6_core.cpp
    src/oodle.cpp
    src/cas.cpp
    src/dbobject.cpp
    src/caslocator.cpp
    src/toc.cpp
    src/bundle.cpp
    src/source.cpp
    src/armory.cpp
    src/meshset.cpp
    src/placeables.cpp
    src/types.cpp
    src/ebx.cpp
    src/walk.cpp
    src/terrain.cpp
    src/texture.cpp
    src/depot.cpp
    src/destruction.cpp
    src/decals.cpp
    src/splat.cpp
    src/terrainlayers.cpp
    src/terrainstatic.cpp
    src/terrainjoin.cpp
    src/terrainshader.cpp
    src/terrainmask.cpp
    src/terraintextures.cpp
    src/terrainpage.cpp
    src/terraincomposite.cpp
    src/groundsplat.cpp
    src/velighting.cpp
    src/levellights.cpp
    src/lightingzones.cpp
    src/fx.cpp
    src/expression_graph.cpp
    src/expression_registry.cpp
    src/expression_vm.cpp
)

add_library(bf6_core SHARED ${BF6_SOURCES})
target_include_directories(bf6_core PUBLIC include PRIVATE src)
# Only the shared build tags the public functions for DLL export. The static
# library (linked into Unreal) leaves BF6_API empty.
target_compile_definitions(bf6_core PRIVATE BF6_BUILDING_DLL)

# A static form too, for native tools that prefer one executable. Engine
# bindings currently consume the shared C ABI so both Godot and Unreal can
# verify bf6_abi_version() before touching any struct-bearing export.
add_library(bf6_core_static STATIC ${BF6_SOURCES})
target_include_directories(bf6_core_static PUBLIC include PRIVATE src)

# One canonical package layout for every binding. This prevents a copied DLL
# and copied header from drifting independently inside an engine plugin.
install(TARGETS bf6_core
    RUNTIME DESTINATION bin
    LIBRARY DESTINATION bin
    ARCHIVE DESTINATION lib)
install(TARGETS bf6_core_static ARCHIVE DESTINATION lib)
install(FILES include/bf6_core.h DESTINATION include)

if (MSVC)
    target_compile_options(bf6_core PRIVATE /W4)
    target_compile_options(bf6_core_static PRIVATE /W4)
endif()

# Validation harness: reads one CAS reference so its output can be byte-compared
# to the working Godot plugin. Not shipped.
add_executable(cas_test test/cas_test.cpp)
target_link_libraries(cas_test PRIVATE bf6_core_static)
target_include_directories(cas_test PRIVATE src include)

# Validates cas_path resolution against the plugin.
add_executable(loc_test test/loc_test.cpp)
target_link_libraries(loc_test PRIVATE bf6_core_static)
target_include_directories(loc_test PRIVATE src include)

# Module 4: dumps type layouts so they can be compared to typesdk.py, the
# Python reference the GDScript reader was itself ported from.
add_executable(types_test test/types_test.cpp)
target_link_libraries(types_test PRIVATE bf6_core_static)
target_include_directories(types_test PRIVATE src include)

# The whole material chain end to end: section -> state key -> bundle -> depot
# -> slots -> guids -> asset names -> pixels. Reports the survival rate at every
# link, because a break anywhere gives an untextured prop and no error.
add_executable(material_test test/material_test.cpp)
target_link_libraries(material_test PRIVATE bf6_core_static)

add_executable(vista_test test/vista_test.cpp)
target_link_libraries(vista_test PRIVATE bf6_core_static)

add_executable(water_test test/water_test.cpp)
target_link_libraries(water_test PRIVATE bf6_core_static)

add_executable(watercomposite_test test/watercomposite_test.cpp)
target_include_directories(watercomposite_test PRIVATE src include)
target_link_libraries(watercomposite_test PRIVATE bf6_core_static)

add_executable(watermask_runtime_test test/watermask_runtime_test.cpp)
target_include_directories(watermask_runtime_test PRIVATE src include)
target_link_libraries(watermask_runtime_test PRIVATE bf6_core_static)

add_executable(whitecards_test test/whitecards_test.cpp)
target_include_directories(whitecards_test PRIVATE src include)

add_executable(splat_test test/splat_test.cpp)
target_include_directories(splat_test PRIVATE src include)
target_link_libraries(splat_test PRIVATE bf6_core_static)

add_executable(watermask_probe probes/watermask_probe.cpp)
target_include_directories(watermask_probe PRIVATE src include)
target_link_libraries(watermask_probe PRIVATE bf6_core_static)

add_executable(utilityraster_probe probes/utilityraster_probe.cpp)
target_include_directories(utilityraster_probe PRIVATE src include)
target_link_libraries(utilityraster_probe PRIVATE bf6_core_static)

add_executable(tilescan_test test/tilescan_test.cpp)
target_include_directories(tilescan_test PRIVATE src include)
target_link_libraries(tilescan_test PRIVATE bf6_core_static)

add_executable(terrainlayers_test test/terrainlayers_test.cpp)
target_include_directories(terrainlayers_test PRIVATE src include)
target_link_libraries(terrainlayers_test PRIVATE bf6_core_static)

add_executable(groundcov_test test/groundcov_test.cpp)
target_include_directories(groundcov_test PRIVATE src include)
target_link_libraries(groundcov_test PRIVATE bf6_core_static)
add_executable(terrainbounds_live_test test/terrainbounds_live_test.cpp)
target_include_directories(terrainbounds_live_test PRIVATE src include)
target_link_libraries(terrainbounds_live_test PRIVATE bf6_core_static)
add_executable(terrainwindow_test test/terrainwindow_test.cpp)
target_include_directories(terrainwindow_test PRIVATE src include)
target_link_libraries(terrainwindow_test PRIVATE bf6_core_static)
add_executable(terrainmask_test test/terrainmask_test.cpp)
target_include_directories(terrainmask_test PRIVATE src include)
target_link_libraries(terrainmask_test PRIVATE bf6_core_static)
add_executable(terrainbindless_test test/terrainbindless_test.cpp)
target_include_directories(terrainbindless_test PRIVATE src include)
target_link_libraries(terrainbindless_test PRIVATE bf6_core_static)
add_executable(terrainpage_test test/terrainpage_test.cpp)
target_include_directories(terrainpage_test PRIVATE src include)
target_link_libraries(terrainpage_test PRIVATE bf6_core_static)

add_executable(scatter_test test/scatter_test.cpp)
target_include_directories(scatter_test PRIVATE src include)
target_link_libraries(scatter_test PRIVATE bf6_core_static)

add_executable(waterdepth_test test/waterdepth_test.cpp)
target_include_directories(waterdepth_test PRIVATE src include)
target_link_libraries(waterdepth_test PRIVATE bf6_core_static)

add_executable(waterheightfield_test test/waterheightfield_test.cpp)
target_include_directories(waterheightfield_test PRIVATE src include)
target_link_libraries(waterheightfield_test PRIVATE bf6_core_static)

add_executable(terraincomposite_test test/terraincomposite_test.cpp)
target_include_directories(terraincomposite_test PRIVATE src include)
target_link_libraries(terraincomposite_test PRIVATE bf6_core_static)
add_executable(terrainstatic_test test/terrainstatic_test.cpp)
target_include_directories(terrainstatic_test PRIVATE src include)
target_link_libraries(terrainstatic_test PRIVATE bf6_core_static)

add_executable(terrainstatic_live_test test/terrainstatic_live_test.cpp)
target_include_directories(terrainstatic_live_test PRIVATE src include)
target_link_libraries(terrainstatic_live_test PRIVATE bf6_core_static)

# Research proof: reads the live map-specific terrain ComputeLayer bytecode and
# validates its exact D3D12 binding contract. It never consumes a dumped shader.
if(WIN32)
  # Optional 2026 DirectX Dump Files capability probe.  The Agility SDK is an
  # explicit configure-time input so normal libbf6 builds do not depend on a
  # machine-local preview SDK.
  set(BF6_DXDMP_AGILITY_DIR "" CACHE PATH
      "Extracted Microsoft.Direct3D.D3D12 preview NuGet package")
  if(BF6_DXDMP_AGILITY_DIR)
    set(BF6_DXDMP_NATIVE "${BF6_DXDMP_AGILITY_DIR}/build/native")
    add_executable(dxdmp_probe test/dxdmp_probe.cpp)
    target_include_directories(dxdmp_probe BEFORE PRIVATE
      "${BF6_DXDMP_NATIVE}/include")
    target_link_libraries(dxdmp_probe PRIVATE d3d12 dxgi advapi32)
    add_custom_command(TARGET dxdmp_probe POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E make_directory
              "$<TARGET_FILE_DIR:dxdmp_probe>/D3D12"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              "${BF6_DXDMP_NATIVE}/bin/x64/D3D12Core.dll"
              "$<TARGET_FILE_DIR:dxdmp_probe>/D3D12/D3D12Core.dll"
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              "${BF6_DXDMP_NATIVE}/bin/x64/d3d12SDKLayers.dll"
              "$<TARGET_FILE_DIR:dxdmp_probe>/D3D12/d3d12SDKLayers.dll")
  endif()

  add_executable(terraindxil_test test/terraindxil_test.cpp)
  target_include_directories(terraindxil_test PRIVATE src include)
  target_link_libraries(terraindxil_test PRIVATE bf6_core_static d3d12 dxgi)
  add_executable(terraindxil_dispatch_test test/terraindxil_dispatch_test.cpp)
  target_include_directories(terraindxil_dispatch_test PRIVATE src include)
  target_link_libraries(terraindxil_dispatch_test PRIVATE bf6_core_static d3d12 dxgi)
  add_executable(terrainrows_test test/terrainrows_test.cpp)
  target_include_directories(terrainrows_test PRIVATE src include)
  target_link_libraries(terrainrows_test PRIVATE bf6_core_static)
  # Existing research-hub evidence dumper. Its .dxbc/.json outputs are
  # disassembly evidence only and are never runtime inputs to libbf6.
  add_executable(terrainkernel_dump_test
    ../../../../../BF6_Frostbite_Research/impl/terrain_static_join/tkdump_test.cpp)
  target_include_directories(terrainkernel_dump_test PRIVATE src include)
  target_link_libraries(terrainkernel_dump_test PRIVATE bf6_core_static)
endif()

add_executable(bindingset_test test/bindingset_test.cpp)
target_include_directories(bindingset_test PRIVATE src include)
target_link_libraries(bindingset_test PRIVATE bf6_core_static)

add_executable(terrainsurface_raster_test test/terrainsurface_raster_test.cpp)
target_include_directories(terrainsurface_raster_test PRIVATE src include)
target_link_libraries(terrainsurface_raster_test PRIVATE bf6_core_static)

add_executable(kernelcensus_test test/kernelcensus_test.cpp)
target_include_directories(kernelcensus_test PRIVATE src include)
target_link_libraries(kernelcensus_test PRIVATE bf6_core_static)

add_executable(findocean_test test/findocean_test.cpp)
target_include_directories(findocean_test PRIVATE src include)
target_link_libraries(findocean_test PRIVATE bf6_core_static)

add_executable(oceankernel_test test/oceankernel_test.cpp)
target_include_directories(oceankernel_test PRIVATE src include)
target_link_libraries(oceankernel_test PRIVATE bf6_core_static)

add_executable(watershaders_test test/watershaders_test.cpp)
target_include_directories(watershaders_test PRIVATE src include)
target_link_libraries(watershaders_test PRIVATE bf6_core_static)

add_executable(oceanshader_test test/oceanshader_test.cpp)
target_include_directories(oceanshader_test PRIVATE src include)
target_link_libraries(oceanshader_test PRIVATE bf6_core_static)

add_executable(variation_test test/variation_test.cpp)
target_include_directories(variation_test PRIVATE src include)
target_link_libraries(variation_test PRIVATE bf6_core_static)
target_link_libraries(whitecards_test PRIVATE bf6_core_static)
target_include_directories(material_test PRIVATE src include)

# Research: names the depot's texture slots from the data, by resolving what is
# bound to each and counting the asset-name suffixes.
add_executable(slots_test test/slots_test.cpp)
target_link_libraries(slots_test PRIVATE bf6_core_static)
target_include_directories(slots_test PRIVATE src include)

# Module 8: the depot join. The format is unusually self-checking - records must
# tile the blob area and blobs must be consumed to the byte - so a wrong parse
# cannot pass quietly.
add_executable(depot_test test/depot_test.cpp)
target_link_libraries(depot_test PRIVATE bf6_core_static)
target_include_directories(depot_test PRIVATE src include)

# Module 7: decodes textures and reports the things that go plausibly wrong -
# a transposed non-square image, a chunk read short, an sRGB flag on linear data.
add_executable(texture_test test/texture_test.cpp)
target_link_libraries(texture_test PRIVATE bf6_core_static)
target_include_directories(texture_test PRIVATE src include)

# Module 10 (heights): reads a level's heightfield and reports the tree it came
# from, so a wrong stride shows up as a bad shape rather than as bad pixels.
add_executable(terrain_test test/terrain_test.cpp)
add_executable(terrainfit_test test/terrainfit_test.cpp)
target_link_libraries(terrainfit_test PRIVATE bf6_core_static)
target_include_directories(terrainfit_test PRIVATE src include)
target_link_libraries(terrain_test PRIVATE bf6_core_static)
target_include_directories(terrain_test PRIVATE src include)

# Module 9: the placement walk, dumped so it can be compared row for row with
# the shipping Godot plugin's own cached walk of the same map.
add_executable(walk_test test/walk_test.cpp)
target_link_libraries(walk_test PRIVATE bf6_core_static)
target_include_directories(walk_test PRIVATE src include)

# Level mounting: the order is the correctness, so it is printed and checked.
add_executable(level_test test/level_test.cpp)
target_link_libraries(level_test PRIVATE bf6_core_static)
target_include_directories(level_test PRIVATE src include)

# Module 5: pulls a real partition out of the install and flattens the decode,
# to be compared line for line with the Python reference.
add_executable(ebx_test test/ebx_test.cpp)
target_link_libraries(ebx_test PRIVATE bf6_core_static)
target_include_directories(ebx_test PRIVATE src include)

# Validates the SuperBundle TOC parse against the plugin.
add_executable(toc_test test/toc_test.cpp)
target_link_libraries(toc_test PRIVATE bf6_core_static)
target_include_directories(toc_test PRIVATE src include)

# Validates the full mount: name -> decompressed bytes.
add_executable(source_test test/source_test.cpp)
target_link_libraries(source_test PRIVATE bf6_core_static)
target_include_directories(source_test PRIVATE src include)

add_executable(meshset_test test/meshset_test.cpp)
target_link_libraries(meshset_test PRIVATE bf6_core_static)
target_include_directories(meshset_test PRIVATE src include)

add_executable(skeleton_test test/skeleton_test.cpp)
target_link_libraries(skeleton_test PRIVATE bf6_core_static)
target_include_directories(skeleton_test PRIVATE src include)

add_executable(psdapply_test test/psdapply_test.cpp)
target_link_libraries(psdapply_test PRIVATE bf6_core_static)
target_include_directories(psdapply_test PRIVATE src include)

add_executable(character_test test/character_test.cpp)
target_link_libraries(character_test PRIVATE bf6_core_static)
target_include_directories(character_test PRIVATE src include)

add_executable(rid_test test/rid_test.cpp)
target_link_libraries(rid_test PRIVATE bf6_core_static)
target_include_directories(rid_test PRIVATE src include)

add_executable(psd_test test/psd_test.cpp)
target_link_libraries(psd_test PRIVATE bf6_core_static)
target_include_directories(psd_test PRIVATE src include)

add_executable(dofset_test test/dofset_test.cpp)
target_link_libraries(dofset_test PRIVATE bf6_core_static)
target_include_directories(dofset_test PRIVATE src include)

add_executable(anim_test test/anim_test.cpp)
target_link_libraries(anim_test PRIVATE bf6_core_static)
target_include_directories(anim_test PRIVATE src include)

add_executable(chardeform_test test/chardeform_test.cpp)
target_link_libraries(chardeform_test PRIVATE bf6_core_static)
target_include_directories(chardeform_test PRIVATE src include)

add_executable(pose_test test/pose_test.cpp)
target_link_libraries(pose_test PRIVATE bf6_core_static)
target_include_directories(pose_test PRIVATE src include)

add_executable(skin_test test/skin_test.cpp)
target_link_libraries(skin_test PRIVATE bf6_core_static)
target_include_directories(skin_test PRIVATE src include)

add_executable(mesh_read_test test/mesh_read_test.cpp)
target_link_libraries(mesh_read_test PRIVATE bf6_core_static)
target_include_directories(mesh_read_test PRIVATE src include)

# Validates the SDK placeable catalogue + per-level filter against the counts we
# computed straight from the JSON (universal 1516; e.g. MP_Dumbo total 3015).
add_executable(placeables_test test/placeables_test.cpp)
target_link_libraries(placeables_test PRIVATE bf6_core_static)
target_include_directories(placeables_test PRIVATE src include)
add_executable(albedo_test test/albedo_test.cpp)
target_link_libraries(albedo_test PRIVATE bf6_core_static)
target_include_directories(albedo_test PRIVATE src include)
add_executable(destruction_test test/destruction_test.cpp)
target_link_libraries(destruction_test PRIVATE bf6_core_static)
target_include_directories(destruction_test PRIVATE src include)
add_executable(pipeline_test test/pipeline_test.cpp)
target_link_libraries(pipeline_test PRIVATE bf6_core_static)
target_include_directories(pipeline_test PRIVATE src include)
add_executable(decals_test test/decals_test.cpp)
target_link_libraries(decals_test PRIVATE bf6_core_static)
target_include_directories(decals_test PRIVATE src include)

add_executable(decaltint_test test/decaltint_test.cpp)
target_link_libraries(decaltint_test PRIVATE bf6_core_static)
target_include_directories(decaltint_test PRIVATE src include)

add_executable(decalwhite_test test/decalwhite_test.cpp)
target_link_libraries(decalwhite_test PRIVATE bf6_core_static)
target_include_directories(decalwhite_test PRIVATE src include)

add_executable(vicinity_test test/vicinity_test.cpp)
target_link_libraries(vicinity_test PRIVATE bf6_core_static)
target_include_directories(vicinity_test PRIVATE src include)

add_executable(decaltintmul_test test/decaltintmul_test.cpp)
target_link_libraries(decaltintmul_test PRIVATE bf6_core_static)
target_include_directories(decaltintmul_test PRIVATE src include)

# The VisualEnvironment decode through the C ABI, checked against the four rows
# of the plugin's hand-built lighting table.
add_executable(velight_test test/velight_test.cpp)
target_link_libraries(velight_test PRIVATE bf6_core_static)
target_include_directories(velight_test PRIVATE src include)

# Research: the raw VisualEnvironment dump the lighting constants were read off.
# Emits (component type_guid, field hash, value) triples for a join against
# data/sdk_field_names.tsv, because the hash is not reversible.
# The local light placements: the count, the placement split (which is where
# the classic bug hides), the distributions and a sample in real units.
add_executable(levellights_test test/levellights_test.cpp)
target_link_libraries(levellights_test PRIVATE bf6_core_static)
target_include_directories(levellights_test PRIVATE src include)

add_executable(reflection_test test/reflection_test.cpp)
target_link_libraries(reflection_test PRIVATE bf6_core_static)
target_include_directories(reflection_test PRIVATE src include)

add_executable(import_backref_test test/import_backref_test.cpp)
target_link_libraries(import_backref_test PRIVATE bf6_core_static)
target_include_directories(import_backref_test PRIVATE src include)

# Exact local VisualEnvironment trigger geometry from the installed level.
# Reports the real AreaProximity->shape joins beside a rotated-source control.
add_executable(lightingzones_test test/lightingzones_test.cpp)
target_link_libraries(lightingzones_test PRIVATE bf6_core_static)
target_include_directories(lightingzones_test PRIVATE src include)

add_executable(vedump_test test/vedump_test.cpp)
target_link_libraries(vedump_test PRIVATE bf6_core_static)
target_include_directories(vedump_test PRIVATE src include)

# Research: the authored water constants - the VE ocean component's fields
# beside the water material's depot record, so the pair can be solved together.
add_executable(waterconst_test test/waterconst_test.cpp)
target_link_libraries(waterconst_test PRIVATE bf6_core_static)
target_include_directories(waterconst_test PRIVATE src include)

add_executable(waterclosure_test test/waterclosure_test.cpp)
target_link_libraries(waterclosure_test PRIVATE bf6_core_static)
target_include_directories(waterclosure_test PRIVATE src include)

# Runs the current installed ocean DXIL directly against live H0. Research
# oracle only: no dumped shader or staged spectrum is a runtime input.
add_executable(waterdxil_test test/waterdxil_test.cpp)
target_link_libraries(waterdxil_test PRIVATE bf6_core_static d3d12 dxgi)
target_include_directories(waterdxil_test PRIVATE src include)

# Creates and executes the current installed level's selected water graphics
# PSO against a small offscreen synthetic-neutral scene.  This is the raster
# counterpart to waterdxil_test; it consumes no staged shader or texture dump.
add_executable(waterdraw_test test/waterdraw_test.cpp)
target_link_libraries(waterdraw_test PRIVATE bf6_core_static d3d12 dxgi)
target_include_directories(waterdraw_test PRIVATE src include)

add_executable(waterbind_test test/waterbind_test.cpp)
target_link_libraries(waterbind_test PRIVATE bf6_core_static)
target_include_directories(waterbind_test PRIVATE src include)

add_executable(bundlecount_test test/bundlecount_test.cpp)
target_link_libraries(bundlecount_test PRIVATE bf6_core_static)
target_include_directories(bundlecount_test PRIVATE src include)

add_executable(waterdepthcmp_test test/waterdepthcmp_test.cpp)
target_link_libraries(waterdepthcmp_test PRIVATE bf6_core_static)
target_include_directories(waterdepthcmp_test PRIVATE src include)

# Module FX: every placed emitter LAYER on a level, with its sheet, its grid,
# its lighting model and its merged parameter table. Checked against
# data/fx_level_inventory.tsv, which is its oracle.
add_executable(fx_test test/fx_test.cpp)
target_link_libraries(fx_test PRIVATE bf6_core_static)
target_include_directories(fx_test PRIVATE src include)

# The same decode over the C ABI, called the way a binding calls it.
add_executable(fxabi_test test/fxabi_test.cpp)
target_link_libraries(fxabi_test PRIVATE bf6_core_static)
target_include_directories(fxabi_test PRIVATE src include)

add_executable(weaponspike_test test/weaponspike_test.cpp)
target_link_libraries(weaponspike_test PRIVATE bf6_core_static)
target_include_directories(weaponspike_test PRIVATE src include)

add_executable(weapon_fit_test test/weapon_fit_test.cpp)
target_link_libraries(weapon_fit_test PRIVATE bf6_core_static)
target_include_directories(weapon_fit_test PRIVATE src include)

add_executable(factory_fit_test test/factory_fit_test.cpp)
target_link_libraries(factory_fit_test PRIVATE bf6_core_static)
target_include_directories(factory_fit_test PRIVATE src include)

add_executable(armory_test test/armory_test.cpp)
target_link_libraries(armory_test PRIVATE bf6_core_static)
target_include_directories(armory_test PRIVATE src include)

add_executable(armory_camera_composition_test
  test/armory_camera_composition_test.cpp
  viewer/armory_camera_composition.cpp)
target_link_libraries(armory_camera_composition_test PRIVATE bf6_core_static)
target_include_directories(armory_camera_composition_test PRIVATE src include viewer)

add_executable(armory_camera_math_test
  test/armory_camera_math_test.cpp
  viewer/armory_camera_composition.cpp)
target_link_libraries(armory_camera_math_test PRIVATE bf6_core_static)
target_include_directories(armory_camera_math_test PRIVATE include viewer)

# Supported update-time exporter: reads both the installed game's ModBuilder
# records and the current Portal SDK declarations. It never consumes staged
# armory JSON/TSV data, so a game or SDK update cannot leave a plausible stale
# mapping beside the executable.
add_executable(portal_armory_codegen tools/portal_armory_codegen.cpp)
target_link_libraries(portal_armory_codegen PRIVATE bf6_core_static)
target_include_directories(portal_armory_codegen PRIVATE src include)

# One-mount UI runtime coverage harness.  It composes the current-install Rime
# readers with the renderer's data-flow interpreter, but never consumes a
# generated TSV/JSON as runtime input.  JSON and SVG are outputs for humans and
# CI; they are not inputs to the viewer.
add_executable(ui_runtime_audit tools/ui_runtime_audit.cpp viewer/rime.cpp)
target_link_libraries(ui_runtime_audit PRIVATE bf6_core_static)
target_include_directories(ui_runtime_audit PRIVATE src include viewer)

add_executable(ebxls_test test/ebxls_test.cpp)
target_link_libraries(ebxls_test PRIVATE bf6_core_static)
target_include_directories(ebxls_test PRIVATE src include)

add_executable(rime_live_test test/rime_live_test.cpp)
target_link_libraries(rime_live_test PRIVATE bf6_core_static)
target_include_directories(rime_live_test PRIVATE src include)

# Parses the current install's SerializedExpressionNodeGraph resources and
# reports real results beside corruption and wrong-resource controls. This is
# the first layer of the offline DiceExpression runtime; no staged corpus table
# is a runtime input.
add_executable(expression_test test/expression_test.cpp)
target_link_libraries(expression_test PRIVATE bf6_core_static)
target_include_directories(expression_test PRIVATE src include)

add_executable(expression_registry_test test/expression_registry_test.cpp)
target_link_libraries(expression_registry_test PRIVATE bf6_core_static)
target_include_directories(expression_registry_test PRIVATE src include)

add_executable(expression_vm_test test/expression_vm_test.cpp)
target_link_libraries(expression_vm_test PRIVATE bf6_core_static)
target_include_directories(expression_vm_test PRIVATE src include)

add_executable(expression_weapon_runtime_test
  test/expression_weapon_runtime_test.cpp)
target_link_libraries(expression_weapon_runtime_test PRIVATE bf6_core_static)
target_include_directories(expression_weapon_runtime_test PRIVATE src include)

# Direct-install proof for MenuWeapon's expression-authored header actions.
# The test follows localize-call slot producers and reports a fabricated SID
# control, so an adjacent favorites description cannot become a fourth button.
add_executable(armory_header_actions_test
  test/armory_header_actions_test.cpp
  viewer/armory_header_actions.cpp)
target_link_libraries(armory_header_actions_test PRIVATE bf6_core_static)
target_include_directories(armory_header_actions_test PRIVATE src include viewer)

add_executable(expression_attribute_runtime_test
  test/expression_attribute_runtime_test.cpp)
target_link_libraries(expression_attribute_runtime_test PRIVATE bf6_core_static)
target_include_directories(expression_attribute_runtime_test PRIVATE src include)

add_executable(rime_interface_color_test
  test/rime_interface_color_test.cpp)
target_link_libraries(rime_interface_color_test PRIVATE bf6_core_static)
target_include_directories(rime_interface_color_test PRIVATE src include)

add_executable(rime_reference_frame_test
  test/rime_reference_frame_test.cpp viewer/rime.cpp)
target_link_libraries(rime_reference_frame_test PRIVATE bf6_core_static)
target_include_directories(rime_reference_frame_test PRIVATE src include viewer)

# One-mount proof of the complete authored front-end spine: boot, legal,
# universal menu, weapons and attachment editing. It discovers the screens
# from the current install and reports real property wiring beside a shuffled
# producer control; no generated route table is a runtime input.
add_executable(frontend_flow_test test/frontend_flow_test.cpp)
target_link_libraries(frontend_flow_test PRIVATE bf6_core_static)
target_include_directories(frontend_flow_test PRIVATE src include)

add_executable(catalogue_test test/catalogue_test.cpp)
target_link_libraries(catalogue_test PRIVATE bf6_core_static)
target_include_directories(catalogue_test PRIVATE src include)

add_executable(rime_paint_test test/rime_paint_test.cpp viewer/rime.cpp)
target_link_libraries(rime_paint_test PRIVATE bf6_core_static)
target_include_directories(rime_paint_test PRIVATE src include viewer)

# Exact runtime adapter/proof for MenuWeaponScreen's data-bound stack lists.
# It reads the mounted UI graph and DBD field ids; no exported roster or
# hand-authored list is a runtime input.
add_executable(rime_list_provider_test
  test/rime_list_provider_test.cpp viewer/rime_list_provider.cpp viewer/rime.cpp)
target_link_libraries(rime_list_provider_test PRIVATE bf6_core_static)
target_include_directories(rime_list_provider_test PRIVATE src include viewer)

# Explicit, typed stand-in for online account/profile services.  The provider
# validates the mounted DBD and the live graph route before adding a value;
# fake-route and changed-signature controls are part of its executable test.
add_executable(offline_profile_provider_test
  test/offline_profile_provider_test.cpp
  viewer/offline_profile_provider.cpp
  viewer/rime_list_provider.cpp
  viewer/rime.cpp)
target_link_libraries(offline_profile_provider_test PRIVATE bf6_core_static)
target_include_directories(offline_profile_provider_test PRIVATE src include viewer)

# Runtime-only proof for DataLists whose authored ItemTemplate is empty.  The
# test resolves the unique visual cell from the installed DBD partition GUID
# and the candidate cell's EFIX Imports[]; it never consumes the research GUID
# table or a generated mapping.
add_executable(rime_dynamic_list_cell_test
  test/rime_dynamic_list_cell_test.cpp viewer/rime_list_provider.cpp viewer/rime.cpp)
target_link_libraries(rime_dynamic_list_cell_test PRIVATE bf6_core_static)
target_include_directories(rime_dynamic_list_cell_test PRIVATE src include viewer)

add_executable(asset_owner_test test/asset_owner_test.cpp)
target_link_libraries(asset_owner_test PRIVATE bf6_core_static)
target_include_directories(asset_owner_test PRIVATE src include)

add_executable(asset_instances_test test/asset_instances_test.cpp)
target_link_libraries(asset_instances_test PRIVATE bf6_core_static)
target_include_directories(asset_instances_test PRIVATE src include)

# Resolves a live hardware MeshSet state key through the installed
# ExpressionShaderDatabase to its selected raster bytecode.  The paired fake
# key is a required control; output shaders are research artifacts only.
add_executable(hardware_shader_test test/hardware_shader_test.cpp)
target_link_libraries(hardware_shader_test PRIVATE bf6_core_static)
target_include_directories(hardware_shader_test PRIVATE src include)

# ---- native viewer: Dear ImGui (Win32 + D3D11) over libbf6 -------------------
# The shell is upstream's own example backend, unmodified. Only the BF6 half is
# ours, which is the point: no time spent rewriting a window and a device.
set(IMGUI third_party/imgui)
if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/${IMGUI}/imgui.cpp)
  add_executable(bf6viewer
    viewer/bf6viewer.cpp
    viewer/rime.cpp
    viewer/rime_list_provider.cpp
    viewer/offline_profile_provider.cpp
    viewer/armory_header_actions.cpp
    viewer/armory_ui.cpp
    viewer/armory_camera_composition.cpp
    ${IMGUI}/imgui.cpp ${IMGUI}/imgui_draw.cpp
    ${IMGUI}/imgui_tables.cpp ${IMGUI}/imgui_widgets.cpp
    ${IMGUI}/backends/imgui_impl_win32.cpp
    ${IMGUI}/backends/imgui_impl_dx11.cpp)
  # THE PIPELINE CONSUMES COLOURS AS BGRA, MEASURED, NOT ASSUMED.
  #
  # A probe drawing IM_COL32(255,0,0) - pure red - sampled #0000FF out of the
  # backbuffer. Everything else is stock: the swap chain reports format 28
  # (R8G8B8A8_UNORM), the backend declares COLOR as R8G8B8A8, and the shader
  # passes the colour through untouched. Whatever the cause, the bytes are
  # consumed in the opposite order, and this is the switch ImGui provides for
  # it - it repacks IM_COL32 rather than asking every call site to reverse its
  # arguments. Every UI colour in this viewer was reversed before it: FE-Text
  # #BFCAD1 rendered #D1CABF, Charcoal #22313C rendered #3C3122, which is why
  # the whole screen read brown instead of blue-grey.
  target_compile_definitions(bf6viewer PRIVATE IMGUI_USE_BGRA_PACKED_COLOR)
  # Keep optimized viewer symbols beside release builds.  UI composition is
  # deliberately data-driven and a bad runtime tree can otherwise leave only
  # an opaque executable RVA in Windows Error Reporting.
  if(MSVC)
    target_compile_options(bf6viewer PRIVATE /Zi)
    target_link_options(bf6viewer PRIVATE /DEBUG:FULL /MAP)
  endif()
  target_include_directories(bf6viewer PRIVATE src include ${IMGUI} ${IMGUI}/backends)
  target_link_libraries(bf6viewer PRIVATE bf6_core_static d3d11 dxgi d3dcompiler)
  add_custom_command(TARGET bf6viewer POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_directory
            ${CMAKE_CURRENT_SOURCE_DIR}/viewer/assets
            $<TARGET_FILE_DIR:bf6viewer>/assets)
endif()

# CTest is an inventory and repeatable runner for the proof harnesses. The
# harness executables remain ordinary binaries; tests that need the installed
# game are registered but disabled when the Steam install is not configured.
include(CTest)
if(BUILD_TESTING)
  include(cmake/BF6Tests.cmake)
endif()
add_executable(dofclose_test test/dofclose_test.cpp)
target_link_libraries(dofclose_test PRIVATE bf6_core_static)
target_include_directories(dofclose_test PRIVATE src include)
add_executable(swarm_test test/swarm_test.cpp)
target_link_libraries(swarm_test PRIVATE bf6_core_static)
target_include_directories(swarm_test PRIVATE src include)
add_executable(clipinfo_test test/clipinfo_test.cpp)
target_link_libraries(clipinfo_test PRIVATE bf6_core_static)
target_include_directories(clipinfo_test PRIVATE src include)
add_executable(chanbone_test test/chanbone_test.cpp)
target_link_libraries(chanbone_test PRIVATE bf6_core_static)
target_include_directories(chanbone_test PRIVATE src include)
add_executable(telemetry_test test/telemetry_test.cpp)
target_link_libraries(telemetry_test PRIVATE bf6_core_static)
target_include_directories(telemetry_test PRIVATE src include)

add_executable(spawn_test test/spawn_test.cpp)
target_link_libraries(spawn_test PRIVATE bf6_core_static)
target_include_directories(spawn_test PRIVATE src include)

add_executable(vshape_test test/vshape_test.cpp)
target_link_libraries(vshape_test PRIVATE bf6_core_static)
target_include_directories(vshape_test PRIVATE src include)

add_executable(footprint_test test/footprint_test.cpp)
target_link_libraries(footprint_test PRIVATE bf6_core_static)
target_include_directories(footprint_test PRIVATE src include)

add_executable(autopaint_test test/autopaint_test.cpp)
target_link_libraries(autopaint_test PRIVATE bf6_core_static)
target_include_directories(autopaint_test PRIVATE src include)

add_executable(debris_test test/debris_test.cpp)
target_link_libraries(debris_test PRIVATE bf6_core_static)
target_include_directories(debris_test PRIVATE src include)

add_executable(matrel_raw_test test/matrel_raw_test.cpp)
target_link_libraries(matrel_raw_test PRIVATE bf6_core_static)
target_include_directories(matrel_raw_test PRIVATE src include)

add_executable(wind_test test/wind_test.cpp)
target_link_libraries(wind_test PRIVATE bf6_core_static)
target_include_directories(wind_test PRIVATE src include)

add_executable(weather_test test/weather_test.cpp)
target_link_libraries(weather_test PRIVATE bf6_core_static)
target_include_directories(weather_test PRIVATE src include)

add_executable(wavesel_test test/wavesel_test.cpp)
target_link_libraries(wavesel_test PRIVATE bf6_core_static)
target_include_directories(wavesel_test PRIVATE src include)

add_executable(sps_test test/sps_test.cpp)
target_link_libraries(sps_test PRIVATE bf6_core_static)
target_include_directories(sps_test PRIVATE src include)

add_executable(spsdec_test test/spsdec_test.cpp)
target_link_libraries(spsdec_test PRIVATE bf6_core_static)
target_include_directories(spsdec_test PRIVATE src include)

add_executable(eal3_test test/eal3_test.cpp)
target_link_libraries(eal3_test PRIVATE bf6_core_static)
target_include_directories(eal3_test PRIVATE src include)

add_executable(eal3find_test test/eal3find_test.cpp)
target_link_libraries(eal3find_test PRIVATE bf6_core_static)
target_include_directories(eal3find_test PRIVATE src include)

add_executable(eal3walk_test test/eal3walk_test.cpp)
target_link_libraries(eal3walk_test PRIVATE bf6_core_static)
target_include_directories(eal3walk_test PRIVATE src include)

add_executable(eal3mp3_test test/eal3mp3_test.cpp)
target_link_libraries(eal3mp3_test PRIVATE bf6_core_static)
target_include_directories(eal3mp3_test PRIVATE src include)

add_executable(eal3v2_test test/eal3v2_test.cpp)
target_link_libraries(eal3v2_test PRIVATE bf6_core_static)
target_include_directories(eal3v2_test PRIVATE src include)

add_executable(eal3rebuild_test test/eal3rebuild_test.cpp)
target_link_libraries(eal3rebuild_test PRIVATE bf6_core_static)
target_include_directories(eal3rebuild_test PRIVATE src include)
add_executable(typescan_test test/typescan_test.cpp)
target_link_libraries(typescan_test PRIVATE bf6_core_static)
target_include_directories(typescan_test PRIVATE src include)
add_executable(gpcensus_test test/gpcensus_test.cpp)
target_link_libraries(gpcensus_test PRIVATE bf6_core_static)
target_include_directories(gpcensus_test PRIVATE src include)
add_executable(exedb_test test/exedb_test.cpp)
target_link_libraries(exedb_test PRIVATE bf6_core_static)
target_include_directories(exedb_test PRIVATE src include)
add_executable(gameplay_test test/gameplay_test.cpp)
target_link_libraries(gameplay_test PRIVATE bf6_core_static)
target_include_directories(gameplay_test PRIVATE src include)
add_executable(mbprobe_test test/mbprobe_test.cpp)
target_link_libraries(mbprobe_test PRIVATE bf6_core_static)
target_include_directories(mbprobe_test PRIVATE src include)
add_executable(physics_test test/physics_test.cpp)
target_link_libraries(physics_test PRIVATE bf6_core_static)
target_include_directories(physics_test PRIVATE src include)
add_executable(placereach_test test/placereach_test.cpp)
target_link_libraries(placereach_test PRIVATE bf6_core_static)
target_include_directories(placereach_test PRIVATE src include)
add_executable(occluder_test test/occluder_test.cpp)
target_link_libraries(occluder_test PRIVATE bf6_core_static)
target_include_directories(occluder_test PRIVATE src include)
add_executable(typecensus_test test/typecensus_test.cpp)
target_link_libraries(typecensus_test PRIVATE bf6_core_static)
target_include_directories(typecensus_test PRIVATE src include)
add_executable(thermal_test test/thermal_test.cpp)
target_link_libraries(thermal_test PRIVATE bf6_core_static)
target_include_directories(thermal_test PRIVATE src include)
