cmake_minimum_required(VERSION 3.19)
project(c-vt-cmake LANGUAGES C)

include(FetchContent)
FetchContent_Declare(wasp
    GIT_REPOSITORY https://github.com/wasp-org/wasp.git
    GIT_TAG main
)
FetchContent_MakeAvailable(wasp)

add_executable(c_vt_cmake src/main.c)
target_link_libraries(c_vt_cmake PRIVATE wasp-vt)
