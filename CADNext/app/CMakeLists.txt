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
