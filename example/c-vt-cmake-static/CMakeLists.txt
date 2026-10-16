cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake-static LANGUAGES C)

include(FetchContent)
FetchContent_Declare(wasp
    GIT_REPOSITORY https://github.com/wasp-org/wasp.git
    GIT_TAG main
)
set(WASP_ZIG_BUILD_FLAGS "-Dsimd=false" CACHE STRING "" FORCE)
FetchContent_MakeAvailable(wasp)

add_executable(c_vt_cmake_static src/main.c)
target_link_libraries(c_vt_cmake_static PRIVATE wasp-vt-static)
