# The gui library is only added to the build when CADNEXT_WITH_QT=ON
# (see the top-level CMakeLists.txt); it requires Qt6 plus the Coin3D viewer.
find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
find_package(ZLIB REQUIRED)
if(CADNEXT_WITH_OCCT)
    find_package(OpenCASCADE REQUIRED)
endif()

set(CMAKE_AUTOMOC ON)

# Headers are listed so AUTOMOC picks up Q_OBJECT classes living under
# include/ (AUTOMOC only auto-discovers headers next to their sources).
add_library(cadnext_gui
    include/cadnext/gui/AssemblyJointDialog.hpp
    include/cadnext/gui/BackgroundCadImport.hpp
    include/cadnext/gui/AssemblyPartLoader.hpp
    include/cadnext/gui/AssemblyWindow.hpp
    include/cadnext/gui/AttachmentPointDialog.hpp
    include/cadnext/gui/CADPartLibraryService.hpp
    include/cadnext/gui/FilePreviewAssets.hpp
    include/cadnext/gui/ImportProgress.hpp
    include/cadnext/gui/ImportProgressDialog.hpp
    include/cadnext/gui/ThreadDialog.hpp
    include/cadnext/gui/CutExtrudeDialog.hpp
    include/cadnext/gui/EdgeOperationDialog.hpp
    include/cadnext/gui/ExtrudeDialog.hpp
    include/cadnext/gui/MainWindow.hpp
    include/cadnext/gui/NativeCadImport.hpp
    include/cadnext/gui/NativeCompoundFile.hpp
    include/cadnext/gui/NativeDxfImport.hpp
    include/cadnext/gui/NativeDwgImport.hpp
    include/cadnext/gui/NativeDwgObjects.hpp
    include/cadnext/gui/NativeDwgR2007.hpp
    include/cadnext/gui/NativeDwgR2000.hpp
    include/cadnext/gui/NativeKompasGeometry.hpp
    include/cadnext/gui/NativeKompasWriter.hpp
    include/cadnext/gui/NativeKompasStorage.hpp
    include/cadnext/gui/NativeKompasCatalog.hpp
    include/cadnext/gui/NativeKompasTopology.hpp
    include/cadnext/gui/NativeKompasBodyApplication.hpp
    include/cadnext/gui/NativeKompasOperation.hpp
    include/cadnext/gui/NativeKompasModel.hpp
    include/cadnext/gui/NativeKompasProperties.hpp
    include/cadnext/gui/NativeKompasDocument.hpp
    include/cadnext/gui/NativeKompasService.hpp
    include/cadnext/gui/NativeKompasTextStyles.hpp
    include/cadnext/gui/NativeKompasMesh.hpp
    include/cadnext/gui/NativeKompasPreview.hpp
    include/cadnext/gui/NativeKompasAssembly.hpp
    include/cadnext/gui/NativeAcisSat.hpp
    include/cadnext/gui/AcisSatWriter.hpp
    include/cadnext/gui/DwgWriter.hpp
    include/cadnext/gui/NativeParasolidXt.hpp
    include/cadnext/gui/NativeSolidWorksGeometry.hpp
    include/cadnext/gui/NativeSolidWorksWriter.hpp
    include/cadnext/gui/NativeSolidWorksPackage.hpp
    include/cadnext/gui/NativeSolidWorksPart.hpp
    include/cadnext/gui/NativeSolidWorksAssembly.hpp
    include/cadnext/gui/NativeSolidWorksConfiguration.hpp
    include/cadnext/gui/NativeSolidWorksDocument.hpp
    include/cadnext/gui/NativeSolidWorksFeatureBodies.hpp
    include/cadnext/gui/ParasolidXtProduct.hpp
    include/cadnext/gui/ParasolidXtWriter.hpp
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
    include/cadnext/gui/AnalysisResultWindow.hpp
    include/cadnext/gui/ModalResultWindow.hpp
    include/cadnext/gui/StructuralResultWindow.hpp
    include/cadnext/gui/StructuralStudyPanel.hpp
    include/cadnext/gui/WorkbenchExportDialog.hpp
    src/AssemblyJointDialog.cpp
    src/BackgroundCadImport.cpp
    src/AssemblyPartLoader.cpp
    src/AssemblyStepExchange.cpp
    src/ParasolidXtProduct.cpp
    src/ParasolidXtWriter.cpp
    src/AssemblyWindow.cpp
    src/AttachmentPointDialog.cpp
    src/CADPartLibraryService.cpp
    src/FilePreviewAssets.cpp
    src/ImportProgressDialog.cpp
    src/ThreadDialog.cpp
    src/CutExtrudeDialog.cpp
    src/EdgeOperationDialog.cpp
    src/ExtrudeDialog.cpp
    src/MainWindow.cpp
    src/NativeCadImport.cpp
    src/NativeCompoundFile.cpp
    src/NativeDxfImport.cpp
    src/NativeDwgImport.cpp
    src/NativeDwgObjects.cpp
    src/NativeDwgR2007.cpp
    src/NativeDwgR2000.cpp
    src/NativeKompasGeometry.cpp
    src/NativeKompasC3d.cpp
    src/NativeKompasWriter.cpp
    src/NativeKompasStorage.cpp
    src/NativeKompasCatalog.cpp
    src/NativeKompasTopology.cpp
    src/NativeKompasBodyApplication.cpp
    src/NativeKompasOperation.cpp
    src/NativeKompasModel.cpp
    src/NativeKompasProperties.cpp
    src/NativeKompasDocument.cpp
    src/NativeKompasService.cpp
    src/NativeKompasTextStyles.cpp
    src/NativeKompasMesh.cpp
    src/NativeKompasPreview.cpp
    src/NativeKompasAssembly.cpp
    src/NativeKompasAssemblyWriter.cpp
    src/NativeAcisSat.cpp
    src/AcisSatWriter.cpp
    src/DwgWriter.cpp
    src/NativeParasolidXt.cpp
    src/NativeSolidWorksGeometry.cpp
    src/NativeSolidWorksWriter.cpp
    src/NativeSolidWorksPackage.cpp
    src/NativeSolidWorksPart.cpp
    src/NativeSolidWorksPartBlueprint.cpp
    src/NativeSolidWorksAssembly.cpp
    src/NativeSolidWorksAssemblyBlueprint.cpp
    src/NativeSolidWorksConfiguration.cpp
    src/NativeSolidWorksDocument.cpp
    src/NativeSolidWorksFeatureBodies.cpp
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
    src/AnalysisResultWindow.cpp
    src/ModalResultWindow.cpp
    src/StructuralResultWindow.cpp
    src/ViewerSnapshot.cpp
    src/ViewerSnapshot.hpp
    src/StructuralStudyPanel.cpp
    src/WorkbenchExportDialog.cpp
    src/WorkbenchHost.cpp
)

target_include_directories(cadnext_gui
    PUBLIC
        ${CMAKE_CURRENT_SOURCE_DIR}/include
)

target_link_libraries(cadnext_gui
    PUBLIC
        cadnext_core
        cadnext_kernel
        cadnext_assembly
        cadnext_bridge
        cadnext_construction
        cadnext_viewer
        cadnext_fea_job
        Qt6::Core
        Qt6::Gui
        Qt6::Widgets
        ZLIB::ZLIB
)

if(CADNEXT_WITH_OCCT)
    target_include_directories(cadnext_gui PRIVATE ${OpenCASCADE_INCLUDE_DIR})
endif()

if(APPLE)
    enable_language(OBJCXX)
    target_sources(cadnext_gui PRIVATE src/UAVUSDZScene.mm)
    set_source_files_properties(src/UAVUSDZScene.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
    target_link_libraries(cadnext_gui PRIVATE "-framework SceneKit" "-framework AppKit")
    target_compile_definitions(cadnext_gui PRIVATE CADNEXT_UAV_MODEL_DIR="${CMAKE_SOURCE_DIR}/../DroneUAVDemo/Resources/Models/UAVModels")
endif()

target_sources(cadnext_gui PRIVATE src/AerodynamicsStudyDialog.cpp src/FlowAnimation.cpp src/FlowAnimation.hpp src/FlowScene3D.cpp src/FlowScene3D.hpp src/FlowResultView.cpp src/FlowResultView.hpp)
target_link_libraries(cadnext_gui PUBLIC cadnext_cfd)
target_compile_definitions(cadnext_gui PRIVATE CADNEXT_SOURCE_DIR="${CMAKE_SOURCE_DIR}")
if(APPLE AND CADNEXT_BUILD_TESTS)
    add_executable(cadnext_test_usdz_preview ../tests/test_usdz_preview.cpp)
    target_link_libraries(cadnext_test_usdz_preview PRIVATE cadnext_gui)
    add_test(NAME cadnext_test_usdz_preview COMMAND cadnext_test_usdz_preview "${CMAKE_SOURCE_DIR}/../DroneUAVDemo/Resources/Models/UAVModels")
endif()
