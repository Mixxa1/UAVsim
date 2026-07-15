add_library(cadnext_kernel
    src/Kernel.cpp
    src/KernelFactory.cpp
    src/StubKernel.cpp
    src/OcctKernel.cpp
    src/GeometryEvaluator.cpp
    src/EdgeAnalyzer.cpp
    src/FaceAnalyzer.cpp
    src/VertexAnalyzer.cpp
    src/ExtrudeMesh.cpp
    src/MeshExtractor.cpp
    src/BooleanOps.cpp
    src/ShapeValidation.cpp
)

target_include_directories(cadnext_kernel
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_kernel
    PUBLIC
        cadnext_core
)

if(CADNEXT_WITH_OCCT)
    find_package(OpenCASCADE QUIET)
    if(NOT OpenCASCADE_FOUND)
        message(FATAL_ERROR
            "CADNEXT_WITH_OCCT=ON but Open CASCADE Technology was not found. "
            "Install OCCT (e.g. `brew install opencascade`) or point CMake at "
            "it with -DOpenCASCADE_DIR=<path to OpenCASCADEConfig.cmake>.")
    endif()

    # The OCCT definition is PUBLIC so the viewer/GUI/tests compiled against
    # this kernel agree on which backend exists. The OCCT libraries stay
    # PRIVATE: no OCCT type ever crosses the kernel boundary.
    target_compile_definitions(cadnext_kernel PUBLIC CADNEXT_WITH_OCCT=1)
    target_include_directories(cadnext_kernel PRIVATE ${OpenCASCADE_INCLUDE_DIR})
    target_link_libraries(cadnext_kernel
        PRIVATE
            TKernel
            TKMath
            TKG2d
            TKG3d
            TKGeomBase
            TKBRep
            TKGeomAlgo
            TKTopAlgo
            TKShHealing
            TKPrim
            TKMesh
            TKBO
            TKFillet
    )
endif()
