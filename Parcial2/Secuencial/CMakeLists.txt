cmake_minimum_required(VERSION 2.8)
project(Secuencial)
find_package(OpenCV REQUIRED)
include_directories(${OpenCV_INCLUDE_DIRS})
add_executable(Secuencial.out Secuencial.cpp )
target_link_libraries(Secuencial.out ${OpenCV_LIBS})
