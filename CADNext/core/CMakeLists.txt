add_library(cadnext_core
    src/Document.cpp
    src/DocumentSerializer.cpp
    src/Object.cpp
    src/Sketch.cpp
    src/SketchProfile.cpp
    src/Feature.cpp
    src/Material.cpp
    src/Transform.cpp
    src/AttachmentPoint.cpp
    src/Command.cpp
    src/CommandStack.cpp
)

target_include_directories(cadnext_core
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)
