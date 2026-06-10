add_library(cadnext_bridge
    src/UAVSimBridge.cpp
    src/ExportPackage.cpp
    src/AttachmentExport.cpp
    src/MassPropertiesExport.cpp
)

target_include_directories(cadnext_bridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_bridge
    PUBLIC
        cadnext_core
)
