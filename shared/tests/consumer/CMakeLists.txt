cmake_minimum_required(VERSION 3.24)
project(acpp_consumer LANGUAGES CXX)

# OMP only: every test runner has it. Set before find_package so
# add_sycl_to_target picks it up.
set(ACPP_TARGETS "omp" CACHE STRING "AdaptiveCpp targets")

find_package(AdaptiveCpp CONFIG REQUIRED)

add_executable(acpp-consumer-hello src/main.cpp)
add_sycl_to_target(TARGET acpp-consumer-hello SOURCES src/main.cpp)

install(TARGETS acpp-consumer-hello RUNTIME DESTINATION bin)
