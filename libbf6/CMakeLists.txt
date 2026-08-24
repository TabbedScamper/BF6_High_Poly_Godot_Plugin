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
)

add_library(bf6_core SHARED ${BF6_SOURCES})
target_include_directories(bf6_core PUBLIC include PRIVATE src)
# Only the shared build tags the public functions for DLL export. The static
# library (linked into Unreal) leaves BF6_API empty.
target_compile_definitions(bf6_core PRIVATE BF6_BUILDING_DLL)

# A static form too, so an Unreal module can link it in rather than ship a DLL.
add_library(bf6_core_static STATIC ${BF6_SOURCES})
target_include_directories(bf6_core_static PUBLIC include PRIVATE src)

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
