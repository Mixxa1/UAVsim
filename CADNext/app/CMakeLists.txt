find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
find_package(SoQt CONFIG REQUIRED)

set(CMAKE_AUTORCC ON)

add_executable(cadnext_app
    main.cpp
    ../gui/resources/cadnext_gui.qrc
)

target_link_libraries(cadnext_app
    PRIVATE
        cadnext_gui
        SoQt::SoQt
        Qt6::Widgets
)

if(TARGET cadnext_dwg_writer)
    add_dependencies(cadnext_app cadnext_dwg_writer)
    add_custom_command(TARGET cadnext_app POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
            $<TARGET_FILE:cadnext_dwg_writer> $<TARGET_FILE_DIR:cadnext_app>)
endif()
