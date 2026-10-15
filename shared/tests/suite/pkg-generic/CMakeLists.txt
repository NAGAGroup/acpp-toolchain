# Packaging wrapper around AdaptiveCpp's tests/ (copied into ./tests by
# `suite.nu package`). Identical in pkg-omp/ and pkg-generic/; the pixi.toml
# selects the configuration through ACPP_SUITE_TARGETS / WITH_*_TESTS.
cmake_minimum_required(VERSION 3.24)
project(acpp_suite LANGUAGES CXX C)

# Before anything else: add_sycl_to_target reads ACPP_TARGETS when the tests'
# find_package(AdaptiveCpp) runs.
set(ACPP_TARGETS "${ACPP_SUITE_TARGETS}" CACHE STRING "" FORCE)

# tests/CMakeLists.txt would shell out to `brew list libomp` on APPLE when
# OpenMP_ROOT/OMP_ROOT are undefined; the toolchain's libomp is in the prefix.
if(APPLE AND NOT DEFINED OpenMP_ROOT)
  set(OpenMP_ROOT "${CMAKE_INSTALL_PREFIX}")
endif()

# conda-forge ships no Boost for win-arm64: fetch the Boost release CMake
# tarball (same release as `suite.nu boost`) so the tests'
# find_package(Boost COMPONENTS unit_test_framework) resolves to it.
# The tests use the HEADER-ONLY Boost.Test (boost/test/included/unit_test.hpp), so
# nothing may link Boost::unit_test_framework (that duplicates every Boost.Test
# symbol); the tests only need the header directories, set below.
if(WIN32 AND CMAKE_SYSTEM_PROCESSOR MATCHES "ARM64|aarch64|arm64")
  include(FetchContent)
  set(ACPP_SUITE_BOOST_VERSION "1.92.0")
  set(BOOST_INCLUDE_LIBRARIES test)
  set(BUILD_SHARED_LIBS ON)
  # Boost skips its install rules when it is not the top-level project; the
  # package needs the DLL and import library installed next to the tests.
  set(BOOST_SKIP_INSTALL_RULES OFF)
  FetchContent_Declare(Boost
    URL "https://github.com/boostorg/boost/releases/download/boost-${ACPP_SUITE_BOOST_VERSION}/boost-${ACPP_SUITE_BOOST_VERSION}-cmake.tar.xz"
    OVERRIDE_FIND_PACKAGE)
  FetchContent_MakeAvailable(Boost)

  # The overridden find_package() sets no Boost_INCLUDE_DIRS. The tests put
  # ${Boost_INCLUDE_DIRS} on their include path, so hand them every Boost header
  # directory of the fetched source (a normal variable, inherited by
  # add_subdirectory below). boost_SOURCE_DIR is FetchContent's source-dir
  # variable for the declaration named Boost.
  file(GLOB ACPP_SUITE_BOOST_INC_DIRS LIST_DIRECTORIES true
    "${boost_SOURCE_DIR}/libs/*/include"
    "${boost_SOURCE_DIR}/libs/numeric/*/include")
  set(Boost_INCLUDE_DIRS "")
  foreach(dir IN LISTS ACPP_SUITE_BOOST_INC_DIRS)
    if(IS_DIRECTORY "${dir}")
      list(APPEND Boost_INCLUDE_DIRS "${dir}")
    endif()
  endforeach()
endif()

add_subdirectory(tests acpp-tests EXCLUDE_FROM_ALL)

set(ACPP_SUITE_EXES sycl_tests rt_tests)
if(WITH_PSTL_TESTS)
  list(APPEND ACPP_SUITE_EXES pstl_tests)
endif()
if(WITH_PCUDA_TESTS)
  list(APPEND ACPP_SUITE_EXES pcuda_tests)
endif()

foreach(exe IN LISTS ACPP_SUITE_EXES)
  set_target_properties(${exe} PROPERTIES OUTPUT_NAME "acpp-suite-${ACPP_SUITE_TARGETS}-${exe}")
endforeach()

add_custom_target(acpp_suite ALL DEPENDS ${ACPP_SUITE_EXES})

install(TARGETS ${ACPP_SUITE_EXES} RUNTIME DESTINATION bin)
