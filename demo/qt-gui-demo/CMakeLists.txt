cmake_minimum_required(VERSION 3.16)
project(qt-gui-demo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Gui Widgets)

add_executable(qt-gui-demo main.cpp)
target_link_libraries(qt-gui-demo PRIVATE Qt6::Core Qt6::Gui Qt6::Widgets)
