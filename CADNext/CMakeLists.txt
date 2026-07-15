cmake_minimum_required(VERSION 3.20)

project(CADNext LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

option(CADNEXT_WITH_OCCT "Build CADNext with Open CASCADE Technology" OFF)
option(CADNEXT_WITH_QT "Build CADNext Qt GUI" OFF)
option(CADNEXT_WITH_COIN3D "Build CADNext Coin3D viewer" OFF)
option(CADNEXT_WITH_PYTHON "Build CADNext Python bindings" OFF)
option(CADNEXT_BUILD_TESTS "Build CADNext tests" ON)
option(CADNEXT_BUILD_APP "Build CADNext standalone application" OFF)

if(CADNEXT_BUILD_APP AND NOT (CADNEXT_WITH_QT AND CADNEXT_WITH_COIN3D))
    message(FATAL_ERROR
        "CADNEXT_BUILD_APP=ON requires both CADNEXT_WITH_QT=ON and "
        "CADNEXT_WITH_COIN3D=ON (the standalone app is a Qt window around "
        "the Coin3D viewport).")
endif()

if(CADNEXT_WITH_QT AND NOT CADNEXT_WITH_COIN3D)
    message(FATAL_ERROR
        "CADNEXT_WITH_QT=ON requires CADNEXT_WITH_COIN3D=ON: the Qt GUI "
        "embeds the Coin3D viewer.")
endif()

add_subdirectory(core)
add_subdirectory(kernel)
add_subdirectory(assembly)
add_subdirectory(bridge)

if(CADNEXT_WITH_COIN3D)
    add_subdirectory(viewer)
endif()

if(CADNEXT_WITH_QT)
    add_subdirectory(gui)
endif()

if(CADNEXT_BUILD_APP)
    add_subdirectory(app)
endif()

if(CADNEXT_WITH_PYTHON)
    add_subdirectory(python)
endif()

if(CADNEXT_BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
