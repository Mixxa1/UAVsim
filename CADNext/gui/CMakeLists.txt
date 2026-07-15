# The gui library is only added to the build when CADNEXT_WITH_QT=ON
# (see the top-level CMakeLists.txt); it requires Qt6 plus the Coin3D viewer.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)

set(CMAKE_AUTOMOC ON)

# Headers are listed so AUTOMOC picks up Q_OBJECT classes living under
# include/ (AUTOMOC only auto-discovers headers next to their sources).
add_library(cadnext_gui
    include/cadnext/gui/AssemblyJointDialog.hpp
    include/cadnext/gui/AssemblyPartLoader.hpp
    include/cadnext/gui/AssemblyWindow.hpp
    include/cadnext/gui/AttachmentPointDialog.hpp
    include/cadnext/gui/CADPartLibraryService.hpp
    include/cadnext/gui/FilePreviewAssets.hpp
    include/cadnext/gui/CutExtrudeDialog.hpp
    include/cadnext/gui/EdgeOperationDialog.hpp
    include/cadnext/gui/ExtrudeDialog.hpp
    include/cadnext/gui/MainWindow.hpp
    include/cadnext/gui/ProjectTree.hpp
    include/cadnext/gui/PropertyPanel.hpp
    include/cadnext/gui/SketchToolBar.hpp
    include/cadnext/gui/ToolBar.hpp
    include/cadnext/gui/UAVBodySceneBuilder.hpp
    include/cadnext/gui/UAVCatalogPreviewProvider.hpp
    include/cadnext/gui/UAVMountEditorDialog.hpp
    include/cadnext/gui/UAVMountPairValidator.hpp
    include/cadnext/gui/UAVPartPreviewPanel.hpp
    include/cadnext/gui/UAVPayloadCompatibilityChecker.hpp
    include/cadnext/gui/UAVPayloadMountFlow.hpp
    include/cadnext/gui/UAVSelectionDialog.hpp
    src/AssemblyJointDialog.cpp
    src/AssemblyPartLoader.cpp
    src/AssemblyWindow.cpp
    src/AttachmentPointDialog.cpp
    src/CADPartLibraryService.cpp
    src/FilePreviewAssets.cpp
    src/CutExtrudeDialog.cpp
    src/EdgeOperationDialog.cpp
    src/ExtrudeDialog.cpp
    src/MainWindow.cpp
    src/ProjectTree.cpp
    src/PropertyPanel.cpp
    src/SketchToolBar.cpp
    src/ToolBar.cpp
    src/UAVBodySceneBuilder.cpp
    src/UAVCatalogPreviewProvider.cpp
    src/UAVMountEditorDialog.cpp
    src/UAVMountPairValidator.cpp
    src/UAVPartPreviewPanel.cpp
    src/UAVPayloadCompatibilityChecker.cpp
    src/UAVSelectionDialog.cpp
    src/WorkbenchHost.cpp
)

target_include_directories(cadnext_gui
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_gui
    PUBLIC
        cadnext_core
        cadnext_assembly
        cadnext_bridge
        cadnext_viewer
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
)
