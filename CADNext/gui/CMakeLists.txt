# The gui library is only added to the build when CADNEXT_WITH_QT=ON
# (see the top-level CMakeLists.txt); it requires Qt6 plus the Coin3D viewer.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)

set(CMAKE_AUTOMOC ON)

# Headers are listed so AUTOMOC picks up Q_OBJECT classes living under
# include/ (AUTOMOC only auto-discovers headers next to their sources).
add_library(cadnext_gui
    include/cadnext/gui/CutExtrudeDialog.hpp
    include/cadnext/gui/EdgeOperationDialog.hpp
    include/cadnext/gui/ExtrudeDialog.hpp
    include/cadnext/gui/MainWindow.hpp
    include/cadnext/gui/ProjectTree.hpp
    include/cadnext/gui/PropertyPanel.hpp
    include/cadnext/gui/SketchToolBar.hpp
    include/cadnext/gui/ToolBar.hpp
    src/CutExtrudeDialog.cpp
    src/EdgeOperationDialog.cpp
    src/ExtrudeDialog.cpp
    src/MainWindow.cpp
    src/ProjectTree.cpp
    src/PropertyPanel.cpp
    src/SketchToolBar.cpp
    src/ToolBar.cpp
    src/WorkbenchHost.cpp
)

target_include_directories(cadnext_gui
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_gui
    PUBLIC
        cadnext_core
        cadnext_viewer
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
)
