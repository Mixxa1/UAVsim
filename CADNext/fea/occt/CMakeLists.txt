add_library(cadnext_fea_occt
    src/ModalStudy.cpp
    src/SolidMesher.cpp
    src/StructuralStudy.cpp
)

target_include_directories(cadnext_fea_occt
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# Netgen comes from CADNext/tools/build_netgen.sh; point Netgen_DIR at its CMake folder
# (third_party/netgen/install/Contents/Resources/CMake). Linked as a shared library (LGPL).
find_package(Netgen CONFIG REQUIRED)
find_package(OpenCASCADE REQUIRED)

target_compile_definitions(cadnext_fea_occt PRIVATE OCCGEOMETRY)
target_include_directories(cadnext_fea_occt PRIVATE ${OpenCASCADE_INCLUDE_DIR} ${NETGEN_INCLUDE_DIRS})

target_link_libraries(cadnext_fea_occt
    PUBLIC
        cadnext_fea
        cadnext_fea_job
        cadnext_kernel
    PRIVATE
        nglib
        ngcore
        TKernel
        TKMath
        TKG3d
        TKBRep
        TKTopAlgo
)

# One job file in, result and field files out. See cli/main.cpp and fea/schema/.
add_executable(cadnext_structural
    cli/main.cpp
)

target_link_libraries(cadnext_structural
    PRIVATE
        cadnext_fea_occt
        cadnext_bridge
)
