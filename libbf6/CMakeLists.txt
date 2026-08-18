cmake_minimum_required(VERSION 3.20)
project(libbf6 CXX)

# The engine-neutral Battlefield 6 decode core. No Godot, no Unreal, no engine
# headers here - only the game formats. Bindings link against this.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(bf6_core SHARED
    src/bf6_core.cpp
)
target_include_directories(bf6_core PUBLIC include)

# A static form too, so an Unreal module can link it in rather than ship a DLL.
add_library(bf6_core_static STATIC
    src/bf6_core.cpp
)
target_include_directories(bf6_core_static PUBLIC include)

if (MSVC)
    target_compile_options(bf6_core PRIVATE /W4)
    target_compile_options(bf6_core_static PRIVATE /W4)
endif()
