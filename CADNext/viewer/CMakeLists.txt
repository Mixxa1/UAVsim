# The viewer library is only added to the build when CADNEXT_WITH_COIN3D=ON
# (see the top-level CMakeLists.txt); it requires Coin3D, SoQt and Qt6.
find_package(Coin CONFIG REQUIRED)
find_package(SoQt CONFIG REQUIRED)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets OpenGL)

add_library(cadnext_viewer
    src/CoinViewer.cpp
    src/SceneGraph.cpp
    src/SelectionController.cpp
)

target_include_directories(cadnext_viewer
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_viewer
    PUBLIC
        cadnext_core
        cadnext_kernel
        Coin::Coin
        SoQt::SoQt
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
)
