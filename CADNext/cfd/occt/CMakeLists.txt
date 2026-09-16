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

file(READ ${CMAKE_CURRENT_SOURCE_DIR}/../report/aerodynamics-report.html report_hex HEX)
string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," report_bytes "${report_hex}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS ${CMAKE_CURRENT_SOURCE_DIR}/../report/aerodynamics-report.html)
file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/generated/AeroReportTemplate.inc
    "static const unsigned char reportBytes[] = {${report_bytes}};\nstatic const std::string kAeroReportTemplate(reinterpret_cast<const char*>(reportBytes), sizeof(reportBytes));\n")
add_executable(cadnext_cfd_cli cli/main.cpp)
set_target_properties(cadnext_cfd_cli PROPERTIES OUTPUT_NAME cadnext_cfd)
target_include_directories(cadnext_cfd_cli PRIVATE ${CMAKE_CURRENT_BINARY_DIR}/generated ${OpenCASCADE_INCLUDE_DIR})
target_link_libraries(cadnext_cfd_cli PRIVATE cadnext_cfd_occt cadnext_construction)
