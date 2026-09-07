@echo on

set "CC=clang-cl.exe"
set "CXX=clang-cl.exe"
set "NM=llvm-nm.exe"
set "LD=lld-link.exe"
set "AR=llvm-ar.exe"
set "RANLIB=llvm-ranlib.exe"

set "CPPFLAGS_USED=-DNDEBUG -D_CRT_SECURE_NO_WARNINGS -fms-runtime-lib=dll -fuse-ld=lld"

REM The clang resource directory lives UNDER Library on Windows; see
REM activate-clang.bat.
set "LDFLAGS=/DEFAULTLIB:%CONDA_PREFIX:\=/%/Library/lib/clang/@MAJOR_VER@/lib/windows/clang_rt.builtins-@BUILTINS_ARCH@.lib"
REM `-Xlinker` was only exposed in v20. It is needed for compatibility with the `flang` CLI
if "@MAJOR_VER@" GEQ "20" (
    set "LDFLAGS=-Xlinker %LDFLAGS%"
)

set "CFLAGS=@CFLAGS@ %CPPFLAGS_USED%"
REM /std:c++17 stays on the clang-cl driver, unlike the gcc-style driver where
REM the flag is stripped. clang-cl follows cl.exe's option semantics, whose
REM default is C++14, and SYCL needs C++17 or later.
set "CXXFLAGS=@CXXFLAGS@ /std:c++17 %CPPFLAGS_USED%"

REM ---- ACPP DELTA: the SYCL environment ----------------------------------
REM clang-cl is one driver for both languages, so it carries the delta itself.
REM ACPP_CLANG names clang++.exe rather than the driver: acpp invokes the
REM gcc-style driver directly, whatever CXX the consumer's build system uses.
if not defined ACPP_TARGETS set "ACPP_TARGETS=generic"
set "ACPP_COMPILER_DIR=%CONDA_PREFIX%\Library"
set "ACPP_CLANG=%CONDA_PREFIX%\Library\bin\clang++.exe"
set "ACPP_CPU_CXX=%CONDA_PREFIX%\Library\bin\clang++.exe"
