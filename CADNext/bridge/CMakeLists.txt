add_library(cadnext_bridge
    src/UAVSimBridge.cpp
    src/ExportPackage.cpp
    src/AttachmentExport.cpp
    src/MassPropertiesExport.cpp
    src/UAVPartFormat.cpp
    src/UAVPartJson.cpp
    src/UAVPartSections.cpp
    src/UAVPartBinary.cpp
    src/UAVPartWriter.cpp
    src/UAVPartReader.cpp
    src/UAVPartValidator.cpp
)

target_include_directories(cadnext_bridge
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_bridge
    PUBLIC
        cadnext_core
)
