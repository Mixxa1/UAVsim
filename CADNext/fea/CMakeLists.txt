add_library(cadnext_fea
    src/Material.cpp
    src/TetMesh.cpp
    src/MeshGeneration.cpp
    src/TetElement.cpp
    src/SystemAssembly.cpp
    src/LinearStatic.cpp
    src/Modal.cpp
    src/Resonance.cpp
    src/Convergence.cpp
    src/StrengthAssessment.cpp
    src/FeaJson.cpp
    src/StructuralPresentation.cpp
    src/StructuralReport.cpp
    src/StructuralFieldFile.cpp
)

target_include_directories(cadnext_fea
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
    PRIVATE
        ${CMAKE_CURRENT_BINARY_DIR}/generated
)

# Structural solver core: no Qt, no Coin3D, no OCCT. Geometry arrives as a tetrahedral mesh,
# so the solver is verified on its own and can be driven headless (CLI, ctest, a Swift
# bridge). Sparse Cholesky comes from Apple Accelerate.
find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)

# Report templates stay plain HTML files (editable, openable on their own) and are embedded at
# configure time as bytes — no text escaping, no literal length limits, no UTF-8 split.
function(cadnext_embed_report source header symbol)
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${source})
    file(READ ${source} hex HEX)
    string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," bytes "${hex}")
    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/generated/${header}
        "static const unsigned char ${symbol}Bytes[] = {${bytes}};\n"
        "static const std::string ${symbol}(reinterpret_cast<const char*>(${symbol}Bytes), sizeof(${symbol}Bytes));\n")
endfunction()
cadnext_embed_report(${CMAKE_CURRENT_SOURCE_DIR}/report/structural-report.html StructuralReportTemplate.inc kStructuralReportTemplate)
cadnext_embed_report(${CMAKE_CURRENT_SOURCE_DIR}/report/modal-report.html ModalReportTemplate.inc kModalReportTemplate)

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
        cadnext_fea
        cadnext_kernel
)

if(CADNEXT_WITH_OCCT AND CADNEXT_WITH_NETGEN)
    add_subdirectory(occt)
endif()
