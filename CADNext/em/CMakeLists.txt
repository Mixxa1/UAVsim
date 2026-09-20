# Electromagnetics: an FDTD written here rather than taken from a library, because the open FDTD
# codes are GPL and this project may only use LGPL/MPL. No Qt, no OCCT — geometry arrives as a
# voxel mask, so the solver is verified on its own and driven headless.
add_library(cadnext_em
    src/Fdtd.cpp
    src/Shielding.cpp
)

target_include_directories(cadnext_em PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

target_link_libraries(cadnext_em
    PUBLIC
        cadnext_core
)
