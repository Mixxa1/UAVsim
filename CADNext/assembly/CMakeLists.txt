add_library(cadnext_assembly
    src/AssemblyMath.cpp
    src/AssemblyModel.cpp
    src/AssemblyJson.cpp
    src/AssemblySerializer.cpp
    src/GeometryReferenceResolver.cpp
    src/AssemblyGraph.cpp
    src/DirectPlacementSolver.cpp
    src/ConstraintSolver.cpp
    src/DOFAnalyzer.cpp
    src/SubassemblyMerge.cpp
    src/AssemblyRecomputeEngine.cpp
)

target_include_directories(cadnext_assembly
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# The assembly core is Qt/Coin3D-free by design (a future Swift bridge
# links it directly). kernel is used for the topology reference types
# only — no OCCT type crosses this boundary.
target_link_libraries(cadnext_assembly
    PUBLIC
        cadnext_core
        cadnext_kernel
)
