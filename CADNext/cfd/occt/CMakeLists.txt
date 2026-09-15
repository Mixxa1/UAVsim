# Fluid-domain meshes from exact CAD geometry (Netgen, LGPL-2.1, linked dynamically).
add_library(cadnext_cfd_occt
    src/FlowDomain.cpp
    src/FluidMesher.cpp
)

target_include_directories(cadnext_cfd_occt
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

find_package(Netgen CONFIG REQUIRED)
find_package(OpenCASCADE REQUIRED)

target_compile_definitions(cadnext_cfd_occt PRIVATE OCCGEOMETRY)
target_include_directories(cadnext_cfd_occt PRIVATE ${OpenCASCADE_INCLUDE_DIR} ${NETGEN_INCLUDE_DIRS})

target_link_libraries(cadnext_cfd_occt
    PUBLIC
        cadnext_cfd
        cadnext_kernel
    PRIVATE
        nglib
        ngcore
        TKernel
        TKMath
        TKG3d
        TKBRep
        TKTopAlgo
        TKGeomAlgo
        TKPrim
        TKBO
        TKBool
)
