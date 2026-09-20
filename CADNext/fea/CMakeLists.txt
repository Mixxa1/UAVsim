add_library(cadnext_fea
    src/Material.cpp
    src/TetMesh.cpp
    src/MeshGeneration.cpp
    src/TetElement.cpp
    src/SystemAssembly.cpp
    src/LinearStatic.cpp
    src/Modal.cpp
    src/Harmonic.cpp
    src/ResponseBasis.cpp
    src/RandomVibration.cpp
    src/Shock.cpp
    src/Aeroelasticity.cpp
    src/BirdStrike.cpp
    src/Icing.cpp
    src/PanelFlow.cpp
    src/Thermal.cpp
    src/AirConvection.cpp
    src/ClimaticCycles.cpp
    src/Fire.cpp
    src/Pyrolysis.cpp
    src/Lightning.cpp
    src/Resonance.cpp
    src/Convergence.cpp
    src/StrengthAssessment.cpp
    src/FeaJson.cpp
    src/StructuralPresentation.cpp
    src/StructuralFieldFile.cpp
)

target_include_directories(cadnext_fea PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)

# Structural solver core: no Qt, no Coin3D, no OCCT. Geometry arrives as a tetrahedral mesh,
# so the solver is verified on its own and can be driven headless (CLI, ctest, a Swift
# bridge). Sparse Cholesky comes from Apple Accelerate.
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)

target_link_libraries(cadnext_fea
    PUBLIC
        cadnext_core
    PRIVATE
        ${ACCELERATE_FRAMEWORK}
)

# Job and result files (the contract with the Workbench and the CADNext panel). Built always and
# free of OCCT and Netgen, so a GUI writes jobs and reads results without linking the mesher —
# the study itself runs in the cadnext_structural process.
add_library(cadnext_fea_job
    occt/src/StructuralJob.cpp
)

target_include_directories(cadnext_fea_job
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/occt/include
)

target_link_libraries(cadnext_fea_job
    PUBLIC
        cadnext_em
        cadnext_fea
        cadnext_kernel
)

if(CADNEXT_WITH_OCCT AND CADNEXT_WITH_NETGEN)
    add_subdirectory(occt)
endif()
