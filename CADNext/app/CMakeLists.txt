find_package(Qt6 REQUIRED COMPONENTS Core Gui Widgets)
find_package(SoQt CONFIG REQUIRED)

add_executable(cadnext_app
    main.cpp
)

target_link_libraries(cadnext_app
    PRIVATE
        cadnext_gui
        SoQt::SoQt
        Qt6::Widgets
)
