# The viewer library is only added to the build when CADNEXT_WITH_COIN3D=ON
# (see the top-level CMakeLists.txt); it requires Coin3D, SoQt and Qt6.
find_package(Coin CONFIG REQUIRED)
find_package(SoQt CONFIG REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets OpenGL)

add_library(cadnext_viewer
    src/CoinViewer.cpp
    src/SceneGraph.cpp
    src/SelectionController.cpp
    src/ModalFieldScene.cpp
    src/StructuralFieldScene.cpp
    src/OffscreenGL.cpp
)

target_include_directories(cadnext_viewer
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_viewer
    PUBLIC
        cadnext_core
        cadnext_kernel
        cadnext_fea
        Coin::Coin
        SoQt::SoQt
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
        "-framework OpenGL"
)

# Offscreen render of a structural field with the same scene the result window uses.
add_executable(cadnext_structural_snapshot
    tools/structural_snapshot.cpp
)

target_link_libraries(cadnext_structural_snapshot
    PRIVATE
        cadnext_viewer
)

# The offscreen snapshot context is CGL (OffscreenGL.cpp): deprecated on macOS since 10.14 but the
# only path Coin3D renders through; the warnings are known and say nothing new.
set_source_files_properties(src/OffscreenGL.cpp PROPERTIES COMPILE_DEFINITIONS GL_SILENCE_DEPRECATION)
