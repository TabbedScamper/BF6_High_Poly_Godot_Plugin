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
