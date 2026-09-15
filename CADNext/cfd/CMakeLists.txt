# Flow solver integration: meshes and configurations for SU2 (LGPL-2.1, run as a separate process,
# built by tools/build_su2.sh), verification geometries, convergence history. No Qt, no OCCT.
add_library(cadnext_cfd
    src/FlatPlate.cpp
    src/Joukowski.cpp
    src/Su2Case.cpp
    src/Su2Mesh.cpp
)

target_include_directories(cadnext_cfd
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_cfd
    PUBLIC
        cadnext_core
)

# SU2_CFD used by the flow verification tests; empty when SU2 has not been built.
set(CADNEXT_SU2_CFD "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/su2/install/bin/SU2_CFD" CACHE FILEPATH "SU2_CFD executable")

if(CADNEXT_WITH_OCCT AND CADNEXT_WITH_NETGEN)
    add_subdirectory(occt)
endif()
