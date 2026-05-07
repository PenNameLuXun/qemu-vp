cmake_minimum_required(VERSION 3.16)
project(qt-demo LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Network)

add_executable(qt-demo main.cpp)
target_link_libraries(qt-demo PRIVATE Qt6::Core Qt6::Network)
