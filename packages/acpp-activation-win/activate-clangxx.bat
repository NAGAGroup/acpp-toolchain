@echo on

set "CXX=clang++.exe"
set "CXXFLAGS=@CXXFLAGS@ %CPPFLAGS_USED%"

REM ---- ACPP DELTA: the SYCL environment ----------------------------------
REM Carried on the C++ side only, because SYCL is a C++ flow. ACPP_TARGETS
REM respects a value the user already set; generic SSCP is the only compiled
REM flow, so the default is one binary that JITs per device. The compiler tree
REM is under %CONDA_PREFIX%\Library, the conda Windows layout.
if not defined ACPP_TARGETS set "ACPP_TARGETS=generic"
set "ACPP_COMPILER_DIR=%CONDA_PREFIX%\Library"
set "ACPP_CLANG=%CONDA_PREFIX%\Library\bin\clang++.exe"
set "ACPP_CPU_CXX=%CONDA_PREFIX%\Library\bin\clang++.exe"
